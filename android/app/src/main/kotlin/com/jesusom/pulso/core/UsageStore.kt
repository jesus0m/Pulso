package com.jesusom.pulso.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jesusom.pulso.BuildConfig
import com.jesusom.pulso.R
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

/** Single source of truth for the dashboard, widgets, notifications and background refresh. Main-thread only. */
class UsageStore(
    private val describeError: (Throwable) -> String,
    private val scope: CoroutineScope,
    private val dependencies: Dependencies,
    private val prefs: PulsoPrefs,
    val codex: CodexSession,
    val claude: ClaudeWebSession,
    val liveActivity: LiveQuotaNotification,
    demo: Boolean = false,
) {
    class RefreshResult(
        val attempted: List<Provider> = emptyList(),
        val refreshed: List<Provider> = emptyList(),
        val failed: List<Provider> = emptyList(),
        val cancelled: Boolean = false,
    ) {
        val succeeded get() = !cancelled && refreshed.isNotEmpty()
    }

    private class RefreshOperation {
        val id = UUID.randomUUID().toString()
        var job: Job? = null
        val waiters = LinkedHashMap<String, CompletableDeferred<RefreshResult>>()
    }

    data class GitHubDraft(
        val username: String = "",
        val allowanceText: String = "",
        val legacy: Boolean = false,
        val organizationPlan: Boolean = true,
    )

    class Dependencies(
        val loadSnapshots: () -> List<UsageSnapshot>,
        val saveSnapshots: (List<UsageSnapshot>) -> Unit,
        val mergeSnapshot: (UsageSnapshot) -> Unit,
        val removeSnapshot: (Provider) -> Unit,
        val tokenAvailability: () -> TokenAvailability,
        val saveToken: (String) -> Unit,
        val deleteToken: () -> Unit,
        val fetchGitHub: suspend (String, String, Double?, Boolean) -> UsageSnapshot,
        val fetchCopilotQuota: suspend (String, Double?) -> UsageSnapshot,
        val fetchCodex: (suspend () -> UsageSnapshot)? = null,
        val fetchClaude: (suspend () -> UsageSnapshot)? = null,
        val clearCodex: (suspend () -> Unit)? = null,
        val clearClaude: (suspend () -> Unit)? = null,
        val deleteClaudeCredentials: () -> Unit = {},
        val reloadWidgets: () -> Unit = {},
        val scheduleResetAlerts: (List<UsageSnapshot>, Boolean) -> Unit = { _, _ -> },
        val requestNotifications: suspend () -> Boolean = { false },
        val publishWidgetConfiguration: (WidgetQuotaConfiguration) -> Unit = {},
        val invalidateWidgetConfiguration: (Provider) -> Unit = {},
        val now: () -> Instant = Instant::now,
    )

    var snapshots by mutableStateOf(dependencies.loadSnapshots())
        private set
    var errors by mutableStateOf<Map<Provider, String>>(emptyMap())
        private set
    var refreshing by mutableStateOf(false)
        private set
    var hiddenProviders by mutableStateOf(prefs.stringList("hiddenProviders").mapNotNull(Provider::from).toSet())
        private set
    /** Sample data is a Debug-only development aid; Release builds can never turn it on. */
    var demo by mutableStateOf(BuildConfig.DEBUG && demo)
        private set
    var deskMode by mutableStateOf(false)
    var nightMode by mutableStateOf(false)
    var username by mutableStateOf(prefs.string("githubUsername") ?: "")
        private set
    var allowanceText by mutableStateOf(prefs.string("githubAllowance") ?: "")
        private set
    var legacy by mutableStateOf(prefs.bool("githubLegacy"))
        private set
    var organizationPlan by mutableStateOf(if (prefs.has("githubOrganizationPlan")) prefs.bool("githubOrganizationPlan") else true)
        private set
    var resetAlerts by mutableStateOf(prefs.bool("resetAlerts"))
        private set
    var notificationsDenied by mutableStateOf(false)
        private set
    var quotaDisplay by mutableStateOf(SnapshotCacheDisplay.read(prefs))
        private set

    private var revision = 0
    private var unavailableActivityProviders = setOf<Provider>()
    private var activeRefresh: RefreshOperation? = null

    init {
        // Remove the old personal billing report when this account is organization-paid.
        if (organizationPlan && snapshots.any { it.provider == Provider.COPILOT && it.source.startsWith("GitHub API") }) {
            snapshots = snapshots.filter { it.provider != Provider.COPILOT }
            dependencies.removeSnapshot(Provider.COPILOT)
            dependencies.reloadWidgets()
        }
        reconcileLiveActivity()
        publishWidgetConfiguration()
    }

    // region Derived state

    val githubConfigured: Boolean
        get() = username.isNotEmpty() && dependencies.tokenAvailability() !is TokenAvailability.Missing
    val codexConfigured get() = prefs.bool("codexEnabled")
    val claudeConfigured get() = prefs.bool("claudeEnabled")
    val allowance: Double? get() = parseAllowance(allowanceText)
    val githubDraft get() = GitHubDraft(username, allowanceText, legacy, organizationPlan)
    val visibleProviders get() = Provider.entries.filter { isProviderVisible(it) }

    fun isConfigured(provider: Provider) = when (provider) {
        Provider.CODEX -> codexConfigured
        Provider.COPILOT -> githubConfigured
        Provider.CLAUDE -> claudeConfigured
    }

    fun isProviderVisible(provider: Provider) = provider !in hiddenProviders

    fun setProviderVisible(provider: Provider, visible: Boolean) {
        hiddenProviders = if (visible) hiddenProviders - provider else hiddenProviders + provider
        prefs.putList("hiddenProviders", Provider.entries.filter { it in hiddenProviders }.map { it.raw })
    }

    fun snapshot(provider: Provider): UsageSnapshot? {
        if (BuildConfig.DEBUG && demo) return demoSnapshots(dependencies.now()).firstOrNull { it.provider == provider }
        return snapshots.firstOrNull { it.provider == provider }
    }

    /** Debug-only: UI tests share one emulator, so a failed run must not leave hidden panels or a flipped preference behind. */
    fun resetDevelopmentPreferences() {
        if (!BuildConfig.DEBUG) return
        hiddenProviders = emptySet()
        prefs.remove("hiddenProviders")
        quotaDisplay = QuotaDisplay.REMAINING
        SnapshotCacheDisplay.write(prefs, QuotaDisplay.REMAINING)
        liveActivity.changeEnabled(false)
        liveActivity.selectProvider(Provider.CODEX)
    }

    fun changeDemo(value: Boolean) {
        if (!BuildConfig.DEBUG || demo == value) return
        demo = value
        reconcileLiveActivity()
    }

    fun changeQuotaDisplay(value: QuotaDisplay) {
        if (quotaDisplay == value) return
        quotaDisplay = value
        SnapshotCacheDisplay.write(prefs, value)
        dependencies.reloadWidgets()
        reconcileLiveActivity()
    }

    // endregion

    private fun publishWidgetConfiguration() {
        if (demo) return
        dependencies.publishWidgetConfiguration(
            WidgetQuotaConfiguration(
                codexEnabled = codexConfigured, username = username, allowance = allowance, legacy = legacy,
                organizationPlan = organizationPlan,
                claudeOrganizationID = if (claudeConfigured) claude.selectedOrganizationID else null,
            )
        )
    }

    fun reconcileLiveActivity() {
        val provider = liveActivity.provider
        liveActivity.reconcile(
            snapshots.firstOrNull { it.provider == provider }, isConfigured(provider), demo, quotaDisplay,
            errors[provider] != null, provider in unavailableActivityProviders,
        )
    }

    fun startLiveActivity() {
        val provider = liveActivity.provider
        liveActivity.start(
            snapshots.firstOrNull { it.provider == provider }, isConfigured(provider), demo, quotaDisplay,
            errors[provider] != null, provider in unavailableActivityProviders,
        )
    }

    fun selectLiveActivityProvider(provider: Provider) {
        liveActivity.selectProvider(provider)
        reconcileLiveActivity()
    }

    /** A denied permission leaves the switch off: it must not promise an alert Android will never show. */
    suspend fun setResetAlerts(enabled: Boolean) {
        if (!enabled) {
            resetAlerts = false
            prefs.put("resetAlerts", false)
            dependencies.scheduleResetAlerts(snapshots, false)
            return
        }
        if (!dependencies.requestNotifications()) {
            resetAlerts = false
            prefs.put("resetAlerts", false)
            notificationsDenied = true
            return
        }
        notificationsDenied = false
        resetAlerts = true
        prefs.put("resetAlerts", true)
        dependencies.scheduleResetAlerts(snapshots, true)
    }

    private fun setError(provider: Provider, message: String?) {
        errors = if (message == null) errors - provider else errors + (provider to message)
    }

    suspend fun saveGitHub(username: String, allowanceText: String, legacy: Boolean, token: String, organizationPlan: Boolean? = null) {
        try {
            val plan = organizationPlan ?: this.organizationPlan
            val name = username.trim()
            val allowance = allowanceText.trim()
            val secret = token.trim()
            if (name.isEmpty()) throw ConfigurationError.MissingUsername
            if (!plan && allowance.isNotEmpty() && parseAllowance(allowance) == null) throw ConfigurationError.InvalidAllowance
            dependencies.invalidateWidgetConfiguration(Provider.COPILOT)
            if (secret.isNotEmpty()) dependencies.saveToken(secret)
            if (dependencies.tokenAvailability() is TokenAvailability.Missing) throw ConfigurationError.MissingToken
            invalidateRefresh()
            removeSnapshot(Provider.COPILOT)
            this.username = name
            this.allowanceText = allowance
            this.legacy = legacy
            this.organizationPlan = plan
            prefs.put("githubOrganizationPlan", plan)
            prefs.put("githubUsername", name)
            prefs.put("githubAllowance", allowance)
            prefs.put("githubLegacy", legacy)
            setError(Provider.COPILOT, null)
            demo = false
            publishWidgetConfiguration()
            refresh()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            setError(Provider.COPILOT, describeError(e))
        } finally {
            publishWidgetConfiguration()
        }
    }

    suspend fun signInCodex(openBrowser: (String) -> Boolean) {
        dependencies.invalidateWidgetConfiguration(Provider.CODEX)
        try {
            codex.signIn(openBrowser)
            invalidateRefresh()
            removeSnapshot(Provider.CODEX)
            enableCodex()
        } catch (e: CancellationException) {
            return
        } catch (e: Exception) {
            setError(Provider.CODEX, describeError(e))
        } finally {
            publishWidgetConfiguration()
        }
    }

    suspend fun enableCodex() {
        invalidateRefresh()
        prefs.put("codexEnabled", true)
        demo = false
        publishWidgetConfiguration()
        refresh()
    }

    fun beginClaudeLogin(email: String? = null) {
        dependencies.invalidateWidgetConfiguration(Provider.CLAUDE)
        try {
            invalidateRefresh()
            removeSnapshot(Provider.CLAUDE)
            prefs.put("claudeEnabled", false)
            try { dependencies.deleteClaudeCredentials() } catch (e: Exception) {
                setError(Provider.CLAUDE, describeError(e))
                return
            }
            claude.openLogin(email)
        } finally {
            publishWidgetConfiguration()
        }
    }

    suspend fun enableClaude() {
        try {
            invalidateRefresh()
            removeSnapshot(Provider.CLAUDE)
            prefs.put("claudeEnabled", true)
            demo = false
            refresh()
        } finally {
            publishWidgetConfiguration()
        }
    }

    suspend fun selectClaudeOrganization(id: String) {
        if (claude.selectedOrganizationID == id) return
        try {
            claude.selectOrganization(id)
            dependencies.invalidateWidgetConfiguration(Provider.CLAUDE)
            invalidateRefresh()
            removeSnapshot(Provider.CLAUDE)
            dependencies.deleteClaudeCredentials()
            setError(Provider.CLAUDE, null)
            if (claudeConfigured) refresh()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            setError(Provider.CLAUDE, describeError(e))
        } finally {
            publishWidgetConfiguration()
        }
    }

    // region Refresh

    /** Concurrent callers share one provider operation; the last waiter to leave cancels it. */
    suspend fun refresh(waiterID: String = UUID.randomUUID().toString()): RefreshResult {
        if (demo) return RefreshResult()
        val waiter = CompletableDeferred<RefreshResult>()
        val active = activeRefresh
        if (active != null) {
            active.waiters[waiterID] = waiter
        } else {
            val operation = RefreshOperation()
            operation.waiters[waiterID] = waiter
            activeRefresh = operation
            refreshing = true
            val currentRevision = revision
            operation.job = scope.launch {
                val result = performRefresh(currentRevision)
                finishRefresh(operation.id, result)
            }
        }
        try {
            return waiter.await()
        } catch (e: CancellationException) {
            cancelRefresh(waiterID)
            throw e
        }
    }

    fun cancelRefresh(waiterID: String) {
        val operation = activeRefresh ?: return
        val waiter = operation.waiters.remove(waiterID) ?: return
        // A foreground or background consumer may still need the same provider operation.
        if (operation.waiters.isEmpty()) invalidateRefresh()
        waiter.complete(RefreshResult(cancelled = true))
    }

    private fun finishRefresh(id: String, result: RefreshResult) {
        val operation = activeRefresh?.takeIf { it.id == id } ?: return
        activeRefresh = null
        refreshing = false
        operation.waiters.values.forEach { it.complete(result) }
        operation.waiters.clear()
    }

    private suspend fun performRefresh(currentRevision: Int): RefreshResult {
        val attempted = mutableListOf<Provider>()
        val refreshed = mutableListOf<Provider>()
        val failed = mutableListOf<Provider>()
        val startedAt = dependencies.now()
        fun cancelled() = RefreshResult(cancelled = true)
        fun result() = RefreshResult(attempted, refreshed, failed)
        try {
            // Capture this generation's configuration before the first suspension.
            val name = username
            val allowance = allowance
            val legacy = legacy
            val organizationPlan = organizationPlan
            val tokenAvailability = dependencies.tokenAvailability()
            if (name.isNotEmpty() && tokenAvailability is TokenAvailability.TemporarilyUnavailable) {
                attempted += Provider.COPILOT
                failed += Provider.COPILOT
                recordRefreshFailure(ConfigurationError.TemporarilyUnavailableToken, Provider.COPILOT)
            }
            if (name.isNotEmpty() && tokenAvailability is TokenAvailability.Available) {
                attempted += Provider.COPILOT
                try {
                    val value = if (organizationPlan) dependencies.fetchCopilotQuota(tokenAvailability.token, allowance)
                    else dependencies.fetchGitHub(name, tokenAvailability.token, allowance, legacy)
                    if (revision != currentRevision) return cancelled()
                    accept(value)
                    if (value.updatedAt >= startedAt) refreshed += Provider.COPILOT else failed += Provider.COPILOT
                } catch (e: CancellationException) {
                    return cancelled()
                } catch (e: Exception) {
                    if (revision != currentRevision) return cancelled()
                    recordRefreshFailure(e, Provider.COPILOT)
                    failed += Provider.COPILOT
                }
            }
            if (revision != currentRevision) return cancelled()
            if (codexConfigured) {
                attempted += Provider.CODEX
                try {
                    val value = dependencies.fetchCodex?.invoke() ?: codex.fetchUsage()
                    if (revision != currentRevision) return cancelled()
                    accept(value)
                    if (value.updatedAt >= startedAt) refreshed += Provider.CODEX else failed += Provider.CODEX
                } catch (e: CancellationException) {
                    return cancelled()
                } catch (e: Exception) {
                    if (revision != currentRevision) return cancelled()
                    recordRefreshFailure(e, Provider.CODEX)
                    failed += Provider.CODEX
                }
            }
            if (revision != currentRevision) return cancelled()
            if (claudeConfigured) {
                attempted += Provider.CLAUDE
                try {
                    val value = dependencies.fetchClaude?.invoke() ?: claude.fetchUsage()
                    if (revision != currentRevision) return cancelled()
                    publishWidgetConfiguration()
                    accept(value)
                    if (value.updatedAt >= startedAt) refreshed += Provider.CLAUDE else failed += Provider.CLAUDE
                } catch (e: CancellationException) {
                    return cancelled()
                } catch (e: Exception) {
                    if (revision != currentRevision) return cancelled()
                    recordRefreshFailure(e, Provider.CLAUDE)
                    failed += Provider.CLAUDE
                }
            }
            return result()
        } finally {
            reconcileLiveActivity()
        }
    }

    private fun invalidateRefresh() {
        revision += 1
        val operation = activeRefresh
        operation?.job?.cancel()
        activeRefresh = null
        refreshing = false
        if (operation != null) {
            claude.cancelQuotaFetch()
            operation.waiters.values.forEach { it.complete(RefreshResult(cancelled = true)) }
            operation.waiters.clear()
        }
    }

    private fun accept(snapshot: UsageSnapshot) {
        snapshots = snapshots.filter { it.provider != snapshot.provider } + snapshot
        setError(snapshot.provider, null)
        unavailableActivityProviders = unavailableActivityProviders - snapshot.provider
        dependencies.mergeSnapshot(snapshot)
        dependencies.reloadWidgets()
        dependencies.scheduleResetAlerts(snapshots, resetAlerts)
        reconcileLiveActivity()
    }

    private fun removeSnapshot(provider: Provider) {
        snapshots = snapshots.filter { it.provider != provider }
        dependencies.removeSnapshot(provider)
        dependencies.reloadWidgets()
        reconcileLiveActivity()
    }

    private fun recordRefreshFailure(error: Throwable, provider: Provider) {
        setError(provider, describeError(error))
        val permanent = when (error) {
            is UsageError -> when (error) {
                UsageError.NoUsageData, UsageError.UnsupportedSchema, UsageError.InvalidCredentials -> true
                is UsageError.Http -> error.code == 401 || error.code == 404
                else -> false
            }
            is CopilotQuotaError -> error is CopilotQuotaError.NoPublishedQuota || error is CopilotQuotaError.UnsupportedSchema ||
                error is CopilotQuotaError.Unavailable || error is CopilotQuotaError.AccessDenied
            is CodexAuthError -> when (error) {
                CodexAuthError.SignIn, CodexAuthError.Forbidden -> true
                is CodexAuthError.Http -> error.code in listOf(401, 403, 404)
                else -> false
            }
            else -> provider == Provider.CLAUDE && ClaudeWebSession.isAuthoritativeUsageFailure(error)
        }
        if (permanent) unavailableActivityProviders = unavailableActivityProviders + provider
        reconcileLiveActivity()
    }

    // endregion

    suspend fun disconnect(provider: Provider) {
        dependencies.invalidateWidgetConfiguration(provider)
        try {
            invalidateRefresh()
            setError(provider, null)
            removeSnapshot(provider)
            when (provider) {
                Provider.COPILOT -> {
                    username = ""
                    allowanceText = ""
                    legacy = false
                    organizationPlan = true
                    prefs.remove("githubUsername", "githubAllowance", "githubLegacy", "githubOrganizationPlan")
                    try { dependencies.deleteToken() } catch (e: Exception) { setError(provider, describeError(e)) }
                }
                Provider.CLAUDE -> {
                    prefs.put("claudeEnabled", false)
                    try { dependencies.deleteClaudeCredentials() } catch (e: Exception) { setError(provider, describeError(e)) }
                    dependencies.clearClaude?.invoke() ?: claude.clearSession()
                }
                Provider.CODEX -> {
                    prefs.put("codexEnabled", false)
                    val clear = dependencies.clearCodex
                    if (clear != null) clear()
                    else try { codex.clearSession() } catch (e: Exception) { setError(provider, describeError(e)) }
                }
            }
        } finally {
            publishWidgetConfiguration()
        }
    }

    companion object {
        fun parseAllowance(text: String): Double? =
            text.replace(",", ".").toDoubleOrNull()?.takeIf { it.isFinite() && it > 0 }

        fun demoSnapshots(now: Instant): List<UsageSnapshot> = listOf(
            UsageSnapshot(
                Provider.CODEX, listOf(
                    UsageWindow("session", "Sesión · 5 h", 28.0, 100.0, now.plusSeconds(7200)),
                    UsageWindow("week", "Semana", 46.0, 100.0, now.plusSeconds(172800)),
                ), now, "Datos de ejemplo",
            ),
            UsageSnapshot(
                Provider.COPILOT, listOf(
                    UsageWindow("copilot_credits", "Créditos del mes", 6134.0, 60000.0, now.plusSeconds(864000), 53774.0, 89.6),
                ), now, "Datos de ejemplo",
            ),
            UsageSnapshot(
                Provider.CLAUDE, listOf(
                    UsageWindow("five_hour", "Sesión · 5 h", 37.0, 100.0, now.plusSeconds(10800)),
                    UsageWindow("seven_day", "Semana", 22.0, 100.0, now.plusSeconds(259200)),
                ), now, "Datos de ejemplo",
            ),
        )
    }
}

internal object SnapshotCacheDisplay {
    fun read(prefs: PulsoPrefs) = QuotaDisplay.from(prefs.string("quotaDisplay"))
    fun write(prefs: PulsoPrefs, value: QuotaDisplay) = prefs.put("quotaDisplay", value.raw)
}

sealed class ConfigurationError : Exception(), LocalizedError {
    object MissingUsername : ConfigurationError()
    object MissingToken : ConfigurationError()
    object InvalidAllowance : ConfigurationError()
    object TemporarilyUnavailableToken : ConfigurationError()

    override fun describe(c: Context): String = when (this) {
        MissingUsername -> c.getString(R.string.s_introduce_tu_usuario_de_github)
        MissingToken -> c.getString(R.string.s_anade_un_token_de_github_con_permiso_plan_de)
        InvalidAllowance -> c.getString(R.string.s_la_cuota_debe_ser_un_numero_mayor_que_cero_o)
        TemporarilyUnavailableToken -> c.getString(R.string.a_keystore_unavailable)
    }
}

