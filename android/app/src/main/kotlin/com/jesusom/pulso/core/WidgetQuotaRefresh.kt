package com.jesusom.pulso.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import java.time.Instant

/**
 * Refreshes providers without any UI, for widgets and background work. Reservations stop several
 * surfaces from querying the same provider at once; a missing or unreadable reading never overwrites a good one.
 */
class WidgetQuotaRefresh(private val dependencies: Dependencies) {
    class Dependencies(
        val configuration: () -> WidgetQuotaConfiguration?,
        val snapshots: () -> List<UsageSnapshot>,
        val reserve: (Provider, WidgetQuotaConfiguration, Instant, Boolean) -> Boolean,
        val fetch: suspend (Provider, WidgetQuotaConfiguration) -> UsageSnapshot,
        val commit: (UsageSnapshot, WidgetQuotaConfiguration) -> Boolean,
        val now: () -> Instant = Instant::now,
        val reloadWidgets: () -> Unit = {},
        val recordFailure: (Provider, WidgetQuotaConfiguration, Throwable) -> Unit = { _, _, _ -> },
        val decision: (Provider, String) -> Unit = { _, _ -> },
    )

    suspend fun refresh(
        requestedProviders: Set<Provider> = Provider.entries.toSet(),
        userInitiated: Boolean = false,
    ): List<UsageSnapshot> {
        val configuration = dependencies.configuration()
        if (configuration == null) {
            requestedProviders.forEach { dependencies.decision(it, "Sin configuración") }
            return dependencies.snapshots()
        }
        val now = dependencies.now()
        val cached = dependencies.snapshots()
        val providers = Provider.entries.filter { provider ->
            if (provider !in requestedProviders) return@filter false
            val configured = when (provider) {
                Provider.CODEX -> configuration.codexEnabled
                Provider.COPILOT -> configuration.username.isNotEmpty()
                Provider.CLAUDE -> configuration.claudeOrganizationID != null
            }
            if (!configured) {
                dependencies.decision(provider, "Proveedor desconectado")
                return@filter false
            }
            val snapshot = cached.firstOrNull { it.provider == provider }
            if (!userInitiated && snapshot != null &&
                now.epochSecond - snapshot.updatedAt.epochSecond < 120 &&
                snapshot.windows.none { (it.resetsAt ?: Instant.MAX) <= now }
            ) {
                dependencies.decision(provider, "Lectura reciente")
                return@filter false
            }
            val reserved = dependencies.reserve(provider, configuration, now, userInitiated)
            dependencies.decision(provider, if (reserved) "Consultando proveedor" else "Reserva no disponible")
            reserved
        }
        var changed = false
        coroutineScope {
            val readings = providers.map { provider ->
                async {
                    try {
                        val snapshot = dependencies.fetch(provider, configuration)
                        if (!currentCoroutineContext().isActive || snapshot.provider != provider || snapshot.updatedAt < now) {
                            dependencies.decision(provider, "Respuesta descartada")
                            null
                        } else snapshot
                    } catch (e: CancellationException) {
                        dependencies.decision(provider, "Consulta cancelada")
                        throw e
                    } catch (e: Exception) {
                        dependencies.recordFailure(provider, configuration, e)
                        dependencies.decision(provider, "Error de consulta")
                        null
                    }
                }
            }
            for (reading in readings) {
                val snapshot = reading.await() ?: continue
                if (dependencies.commit(snapshot, configuration)) {
                    changed = true
                    dependencies.decision(snapshot.provider, "Lectura guardada")
                } else {
                    dependencies.decision(snapshot.provider, "Lectura descartada al guardar")
                }
            }
        }
        if (changed) dependencies.reloadWidgets()
        return dependencies.snapshots()
    }
}

/** Shared provider fetching used by background work; the foreground store uses the same clients. */
class ProviderFetcher(
    private val transport: HttpTransport,
    private val tokens: TokenVault,
    private val codexVault: CodexCredentialVault,
    private val claudeVault: ClaudeCredentialVault,
    private val now: () -> Instant = Instant::now,
) {
    suspend fun fetch(provider: Provider, configuration: WidgetQuotaConfiguration): UsageSnapshot = when (provider) {
        Provider.CLAUDE -> {
            val credentials = claudeVault.load()?.takeIf { it.organizationID == configuration.claudeOrganizationID }
                ?: throw ClaudeQuotaError.SignIn
            val reading = ClaudeQuotaClient(transport, now).fetch(credentials)
            claudeVault.replace(reading.credentials, credentials)
            reading.snapshot
        }
        Provider.COPILOT -> {
            val token = tokens.read() ?: throw UsageError.InvalidCredentials
            if (configuration.organizationPlan) CopilotQuotaClient(transport, now).fetch(token, configuration.allowance)
            else GitHubUsageClient(transport, now).fetch(configuration.username, token, configuration.allowance, configuration.legacy)
        }
        Provider.CODEX -> fetchCodex()
    }

    private suspend fun fetchCodex(): UsageSnapshot {
        val client = CodexOAuthClient(transport, now)
        var credentials = codexVault.load() ?: throw CodexAuthError.SignIn
        var renewed = false
        if (credentials.needsRefresh(now()) && credentials.refreshToken != null) {
            credentials = renew(credentials, client)
            renewed = true
        }
        return try {
            client.fetchUsage(credentials)
        } catch (e: CodexAuthError.SignIn) {
            if (renewed || credentials.refreshToken == null) throw e
            client.fetchUsage(renew(credentials, client))
        }
    }

    private suspend fun renew(credentials: CodexCredentials, client: CodexOAuthClient): CodexCredentials =
        SharedQuotaAccess.withOAuthLock(wait = 4) {
            val current = codexVault.load() ?: throw CancellationException("Signed out")
            if (current != credentials) return@withOAuthLock current
            val updated = client.refresh(current)
            codexVault.replace(updated, current)
            updated
        }
}
