package com.jesusom.pulso.core

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

/** Non-secret state shared by the app, widgets and background work (one process, one file). */
class PulsoPrefs(val prefs: SharedPreferences) {
    fun string(key: String): String? = prefs.getString(key, null)
    fun bool(key: String, default: Boolean = false) = prefs.getBoolean(key, default)
    fun has(key: String) = prefs.contains(key)
    fun long(key: String): Long? = if (prefs.contains(key)) prefs.getLong(key, 0) else null
    fun int(key: String, default: Int = 0) = prefs.getInt(key, default)
    fun stringList(key: String): List<String> =
        prefs.getString(key, null)?.let { runCatching { JSONArray(it).let { a -> (0 until a.length()).map(a::getString) } }.getOrNull() }
            ?: emptyList()

    fun put(key: String, value: String) = prefs.edit().putString(key, value).apply()
    fun put(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()
    fun put(key: String, value: Long) = prefs.edit().putLong(key, value).apply()
    fun put(key: String, value: Int) = prefs.edit().putInt(key, value).apply()
    fun putList(key: String, value: List<String>) = prefs.edit().putString(key, JSONArray(value).toString()).apply()
    fun remove(vararg keys: String) = prefs.edit().apply { keys.forEach(::remove) }.apply()
}

class SnapshotCache(private val prefs: PulsoPrefs) {
    var quotaDisplay: QuotaDisplay
        get() = QuotaDisplay.from(prefs.string(DISPLAY_KEY))
        set(value) = prefs.put(DISPLAY_KEY, value.raw)

    fun load(): List<UsageSnapshot> = SharedQuotaAccess.transaction { read() }

    fun save(snapshots: List<UsageSnapshot>) = SharedQuotaAccess.transaction { write(snapshots) }

    fun merge(snapshot: UsageSnapshot) = SharedQuotaAccess.transaction {
        val snapshots = read()
        val current = snapshots.firstOrNull { it.provider == snapshot.provider }
        if (current != null && current.updatedAt.isAfter(snapshot.updatedAt)) return@transaction
        write(snapshots.filter { it.provider != snapshot.provider } + snapshot)
    }

    fun remove(provider: Provider) = SharedQuotaAccess.transaction { write(read().filter { it.provider != provider }) }

    private fun read(): List<UsageSnapshot> {
        val text = prefs.string(KEY) ?: return emptyList()
        return try {
            val array = JSONArray(text)
            (0 until array.length()).mapNotNull { UsageSnapshot.fromJson(array.getJSONObject(it)) }
        } catch (e: Exception) { emptyList() }
    }

    private fun write(snapshots: List<UsageSnapshot>) =
        prefs.put(KEY, JSONArray(snapshots.map { it.toJson() }).toString())

    private companion object {
        const val KEY = "usageSnapshots"
        const val DISPLAY_KEY = "quotaDisplay"
    }
}

sealed class TokenAvailability {
    data class Available(val token: String) : TokenAvailability()
    object Missing : TokenAvailability()
    object TemporarilyUnavailable : TokenAvailability()
}

/** GitHub token storage. An unreadable store is reported as temporarily unavailable, never as "no token". */
class TokenVault(private val store: SecretStore) {
    fun availability(): TokenAvailability = try {
        store.load(NAME)?.let { TokenAvailability.Available(String(it)) } ?: TokenAvailability.Missing
    } catch (e: SecretStoreUnavailable) { TokenAvailability.TemporarilyUnavailable }

    fun read(): String? = (availability() as? TokenAvailability.Available)?.token

    fun save(token: String) {
        val trimmed = token.trim()
        if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() }) throw UsageError.InvalidCredentials
        store.save(NAME, trimmed.toByteArray())
    }

    fun delete() = store.delete(NAME)

    private companion object { const val NAME = "github.token" }
}

/** What background work needs to refresh each provider without the app UI. */
data class WidgetQuotaConfiguration(
    val revision: String = UUID.randomUUID().toString(),
    val codexEnabled: Boolean,
    val username: String,
    val allowance: Double?,
    val legacy: Boolean,
    val organizationPlan: Boolean,
    val claudeOrganizationID: String? = null,
) {
    fun toJson() = JSONObject().apply {
        put("revision", revision); put("codexEnabled", codexEnabled); put("username", username)
        allowance?.let { put("allowance", it) }
        put("legacy", legacy); put("organizationPlan", organizationPlan)
        claudeOrganizationID?.let { put("claudeOrganizationID", it) }
    }

    companion object {
        fun fromJson(o: JSONObject) = WidgetQuotaConfiguration(
            o.getString("revision"), o.getBoolean("codexEnabled"), o.getString("username"),
            o.optDoubleOrNull("allowance"), o.getBoolean("legacy"), o.getBoolean("organizationPlan"),
            o.optString("claudeOrganizationID").ifEmpty { null },
        )
    }
}

/** Revision-guarded storage of [WidgetQuotaConfiguration] and per-provider attempt bookkeeping. */
class WidgetQuotaState(private val prefs: PulsoPrefs, private val cache: SnapshotCache) {
    fun load(): WidgetQuotaConfiguration? = prefs.string(CONFIG)?.let {
        runCatching { WidgetQuotaConfiguration.fromJson(JSONObject(it)) }.getOrNull()
    }

    fun save(configuration: WidgetQuotaConfiguration) = SharedQuotaAccess.transaction {
        load()?.let { current ->
            if (configuration.copy(revision = current.revision) == current) return@transaction
        }
        persist(configuration)
    }

    fun invalidate(provider: Provider) = SharedQuotaAccess.transaction {
        var configuration = load() ?: return@transaction
        configuration = configuration.copy(revision = UUID.randomUUID().toString())
        configuration = when (provider) {
            Provider.CODEX -> configuration.copy(codexEnabled = false)
            Provider.COPILOT -> configuration.copy(username = "")
            Provider.CLAUDE -> configuration.copy(claudeOrganizationID = null)
        }
        persist(configuration)
        cache.remove(provider)
    }

    private fun persist(configuration: WidgetQuotaConfiguration) = prefs.put(CONFIG, configuration.toJson().toString())

    fun attempt(provider: Provider): Attempt? = prefs.string("widgetQuotaAttempt.${provider.raw}")?.let {
        runCatching {
            JSONObject(it).let { o -> Attempt(o.getString("revision"), Instant.ofEpochMilli(o.getLong("date")), o.getString("result")) }
        }.getOrNull()
    }

    private fun putAttempt(provider: Provider, attempt: Attempt) = prefs.put(
        "widgetQuotaAttempt.${provider.raw}",
        JSONObject().put("revision", attempt.revision).put("date", attempt.date.toEpochMilli()).put("result", attempt.result).toString(),
    )

    data class Attempt(val revision: String, val date: Instant, val result: String)

    fun reserve(provider: Provider, configuration: WidgetQuotaConfiguration, now: Instant, userInitiated: Boolean = false): Boolean =
        SharedQuotaAccess.transaction {
            if (load() != configuration) return@transaction false
            val previous = attempt(provider)
            if (previous != null && previous.revision == configuration.revision) {
                val elapsed = now.epochSecond - previous.date.epochSecond
                if (elapsed < (if (userInitiated) 10 else 120) || (elapsed < 120 && previous.result == "En curso")) {
                    return@transaction false
                }
            }
            putAttempt(provider, Attempt(configuration.revision, now, "En curso"))
            true
        }

    fun commit(snapshot: UsageSnapshot, configuration: WidgetQuotaConfiguration): Boolean = SharedQuotaAccess.transaction {
        if (load() != configuration) return@transaction false
        cache.merge(snapshot)
        val saved = cache.load().any { it.provider == snapshot.provider && it.updatedAt >= snapshot.updatedAt }
        if (saved) recordResult(snapshot.provider, configuration, "Actualizado")
        saved
    }

    fun recordFailure(provider: Provider, configuration: WidgetQuotaConfiguration, error: Throwable) =
        recordResult(provider, configuration, "Error ${error.javaClass.simpleName}")

    private fun recordResult(provider: Provider, configuration: WidgetQuotaConfiguration, result: String) =
        SharedQuotaAccess.transaction {
            if (load() != configuration) return@transaction
            val attempt = attempt(provider)?.takeIf { it.revision == configuration.revision } ?: return@transaction
            putAttempt(provider, attempt.copy(result = result))
        }

    private companion object { const val CONFIG = "widgetQuotaConfiguration" }
}

/** Latest refresh decisions per provider, kept so "never ran" and "ran but failed" stay distinguishable. */
class WidgetQuotaDiagnostics(private val prefs: PulsoPrefs) {
    fun decision(provider: Provider, reason: String) = prefs.put("widgetQuotaDecision.${provider.raw}", reason)
    fun timeline(scope: String, requestedAfter: Instant, entryCount: Int) =
        prefs.put("widgetTimeline.$scope", "${requestedAfter.toEpochMilli()}|$entryCount")
}
