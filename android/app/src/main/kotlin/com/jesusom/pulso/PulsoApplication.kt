package com.jesusom.pulso

import android.app.Application
import android.content.Context
import com.jesusom.pulso.core.BackgroundRefresh
import com.jesusom.pulso.core.ClaudeCredentialVault
import com.jesusom.pulso.core.ClaudeWebSession
import com.jesusom.pulso.core.CodexCredentialVault
import com.jesusom.pulso.core.CodexSession
import com.jesusom.pulso.core.CopilotQuotaClient
import com.jesusom.pulso.core.GitHubUsageClient
import com.jesusom.pulso.core.KeystoreSecretStore
import com.jesusom.pulso.core.LiveQuotaNotification
import com.jesusom.pulso.core.ProviderFetcher
import com.jesusom.pulso.core.PulsoPrefs
import com.jesusom.pulso.core.ResetNotifier
import com.jesusom.pulso.core.SnapshotCache
import com.jesusom.pulso.core.TokenVault
import com.jesusom.pulso.core.UrlConnectionTransport
import com.jesusom.pulso.core.UsageStore
import com.jesusom.pulso.core.describe
import com.jesusom.pulso.core.WidgetQuotaDiagnostics
import com.jesusom.pulso.core.WidgetQuotaRefresh
import com.jesusom.pulso.core.WidgetQuotaState
import com.jesusom.pulso.widget.PulsoWidgets
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Process-wide wiring. The app, widgets and background work share these instances. */
class Services(val app: Application) {
    val prefs = PulsoPrefs(app.getSharedPreferences("pulso", Context.MODE_PRIVATE))
    val secrets = KeystoreSecretStore(app)
    val cache = SnapshotCache(prefs)
    val tokens = TokenVault(secrets)
    val codexVault = CodexCredentialVault(secrets)
    val claudeVault = ClaudeCredentialVault(secrets)
    val widgetState = WidgetQuotaState(prefs, cache)
    val diagnostics = WidgetQuotaDiagnostics(prefs)
    val fetcher = ProviderFetcher(UrlConnectionTransport, tokens, codexVault, claudeVault)

    /** Set by the foreground activity so the store can ask for the notification permission. */
    var notificationPermission: (suspend () -> Boolean)? = null

    val widgetRefresh = WidgetQuotaRefresh(
        WidgetQuotaRefresh.Dependencies(
            configuration = widgetState::load,
            snapshots = cache::load,
            reserve = widgetState::reserve,
            fetch = fetcher::fetch,
            commit = widgetState::commit,
            reloadWidgets = { PulsoWidgets.requestUpdate(app) },
            recordFailure = widgetState::recordFailure,
            decision = diagnostics::decision,
        )
    )

    val store: UsageStore by lazy {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val codex = CodexSession(app, vault = codexVault)
        val claude = ClaudeWebSession(app, prefs, claudeVault)
        UsageStore(
            describeError = { it.describe(app) }, scope = scope, prefs = prefs, codex = codex, claude = claude,
            liveActivity = LiveQuotaNotification(app, prefs),
            dependencies = UsageStore.Dependencies(
                loadSnapshots = cache::load, saveSnapshots = cache::save, mergeSnapshot = cache::merge,
                removeSnapshot = cache::remove,
                tokenAvailability = tokens::availability, saveToken = tokens::save, deleteToken = tokens::delete,
                fetchGitHub = { name, token, allowance, legacy ->
                    GitHubUsageClient().fetch(name, token, allowance, legacy)
                },
                fetchCopilotQuota = { token, allowance -> CopilotQuotaClient().fetch(token, allowance) },
                deleteClaudeCredentials = claudeVault::delete,
                reloadWidgets = { PulsoWidgets.requestUpdate(app) },
                scheduleResetAlerts = { snapshots, enabled -> ResetNotifier.reschedule(app, prefs, snapshots, enabled) },
                requestNotifications = { notificationPermission?.invoke() ?: ResetNotifier.hasPermission(app) },
                publishWidgetConfiguration = widgetState::save,
                invalidateWidgetConfiguration = widgetState::invalidate,
            ),
        )
    }
}

class PulsoApplication : Application() {
    lateinit var services: Services
        private set

    override fun onCreate() {
        super.onCreate()
        services = Services(this)
        ResetNotifier.ensureChannel(this)
        BackgroundRefresh.schedule(this, services.prefs)
        // Redraw any placed widgets from the stored readings whenever the process starts.
        PulsoWidgets.requestUpdate(this)
    }
}

