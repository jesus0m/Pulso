package com.jesusom.pulso

import android.content.ContextWrapper
import com.jesusom.pulso.core.ClaudeCredentialVault
import com.jesusom.pulso.core.ClaudeWebSession
import com.jesusom.pulso.core.CodexCredentialVault
import com.jesusom.pulso.core.CodexSession
import com.jesusom.pulso.core.InMemorySecretStore
import com.jesusom.pulso.core.LiveQuotaNotification
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.PulsoPrefs
import com.jesusom.pulso.core.QuotaDisplay
import com.jesusom.pulso.core.SnapshotCache
import com.jesusom.pulso.core.TokenAvailability
import com.jesusom.pulso.core.UsageStore
import com.jesusom.pulso.core.UsageSnapshot
import com.jesusom.pulso.core.UsageWindow
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.time.Instant

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class UsageStoreTests {
    /** Everything the store touches, backed by memory so behaviour can be asserted without Android. */
    private class Harness(scope: CoroutineScope, val prefs: PulsoPrefs = fakePrefs(), initial: List<UsageSnapshot> = emptyList()) {
        val cache = SnapshotCache(prefs).also { c -> initial.forEach(c::merge) }
        var token: String? = null
        val events = mutableListOf<String>()
        val widgetConfigs = mutableListOf<com.jesusom.pulso.core.WidgetQuotaConfiguration>()
        var codexFetch: suspend () -> UsageSnapshot = { error("codex not expected") }
        var claudeFetch: suspend () -> UsageSnapshot = { error("claude not expected") }
        var copilotFetch: suspend (String, Double?) -> UsageSnapshot = { _, _ -> error("copilot not expected") }
        var gitHubFetch: suspend (String, String, Double?, Boolean) -> UsageSnapshot = { _, _, _, _ -> error("github not expected") }
        val secrets = InMemorySecretStore()
        private val context = ContextWrapper(null)

        val store = UsageStore(
            describeError = { it.message ?: it.javaClass.simpleName }, scope = scope, prefs = prefs,
            codex = CodexSession(context, vault = CodexCredentialVault(secrets)),
            claude = ClaudeWebSession(context, prefs, ClaudeCredentialVault(secrets)),
            liveActivity = LiveQuotaNotification(context, prefs),
            dependencies = UsageStore.Dependencies(
                loadSnapshots = cache::load, saveSnapshots = cache::save, mergeSnapshot = cache::merge,
                removeSnapshot = { events += "remove.${it.raw}"; cache.remove(it) },
                tokenAvailability = { token?.let { TokenAvailability.Available(it) } ?: TokenAvailability.Missing },
                saveToken = { token = it }, deleteToken = { events += "deleteToken"; token = null },
                fetchGitHub = { a, b, c, d -> gitHubFetch(a, b, c, d) },
                fetchCopilotQuota = { t, a -> copilotFetch(t, a) },
                fetchCodex = { codexFetch() }, fetchClaude = { claudeFetch() },
                clearCodex = { events += "clearCodex" }, clearClaude = { events += "clearClaude" },
                deleteClaudeCredentials = { events += "deleteClaudeCredentials" },
                reloadWidgets = { events += "reload" },
                publishWidgetConfiguration = { widgetConfigs += it },
                invalidateWidgetConfiguration = { events += "invalidate.${it.raw}" },
                now = { Instant.now() },
            ),
        )
    }

    private fun snapshot(provider: Provider, used: Double = 10.0, at: Instant = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.MILLIS).plusSeconds(1), source: String = "test") =
        UsageSnapshot(provider, listOf(UsageWindow("w", "Sesión", used, 100.0, at.plusSeconds(3600))), at, source)

    private fun TestScope.harness(prefs: PulsoPrefs = fakePrefs(), initial: List<UsageSnapshot> = emptyList()) = Harness(this, prefs, initial)

    // region Visibility and display preferences

    @Test fun providerVisibilityRestoresAndIgnoresUnknownProviders() = runTest {
        val prefs = fakePrefs()
        prefs.putList("hiddenProviders", listOf("claude", "future-provider"))
        val h = harness(prefs)
        assertEquals(listOf(Provider.CODEX, Provider.COPILOT), h.store.visibleProviders)
        h.store.setProviderVisible(Provider.COPILOT, false)
        assertEquals(listOf("copilot", "claude"), prefs.stringList("hiddenProviders"))
    }

    @Test fun allProvidersCanBeHiddenAndRestoredInStableOrder() = runTest {
        val h = harness()
        Provider.entries.reversed().forEach { h.store.setProviderVisible(it, false) }
        assertTrue(h.store.visibleProviders.isEmpty())
        Provider.entries.reversed().forEach { h.store.setProviderVisible(it, true) }
        assertEquals(Provider.entries, h.store.visibleProviders)
    }

    @Test fun hidingProvidersPreservesConnectionsCredentialsAndSnapshots() = runTest {
        val prefs = fakePrefs()
        prefs.put("codexEnabled", true)
        val h = harness(prefs, listOf(snapshot(Provider.CODEX)))
        h.store.setProviderVisible(Provider.CODEX, false)
        assertTrue(h.store.codexConfigured)
        assertEquals(1, h.store.snapshots.size)
        assertNotNull(h.store.snapshot(Provider.CODEX))
    }

    @Test fun hiddenProviderContinuesRefreshing() = runTest {
        val prefs = fakePrefs().also { it.put("codexEnabled", true) }
        val h = harness(prefs)
        h.codexFetch = { snapshot(Provider.CODEX) }
        h.store.setProviderVisible(Provider.CODEX, false)
        val result = async { h.store.refresh() }
        advanceUntilIdle()
        assertEquals(listOf(Provider.CODEX), result.await().refreshed)
    }

    @Test fun displayPreferenceIsStoredAndReloadsWidgets() = runTest {
        val h = harness()
        h.store.changeQuotaDisplay(QuotaDisplay.USED)
        assertEquals(QuotaDisplay.USED, h.store.quotaDisplay)
        assertEquals("used", h.prefs.string("quotaDisplay"))
        assertTrue(h.events.contains("reload"))
    }

    // endregion

    // region Refresh coordination

    @Test fun concurrentRefreshesShareOneProviderOperation() = runTest {
        val prefs = fakePrefs().also { it.put("codexEnabled", true) }
        val h = harness(prefs)
        var calls = 0
        val gate = CompletableDeferred<Unit>()
        h.codexFetch = { calls++; gate.await(); snapshot(Provider.CODEX) }
        val first = async { h.store.refresh("a") }
        val second = async { h.store.refresh("b") }
        runCurrent()
        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, calls)
        assertTrue(first.await().succeeded && second.await().succeeded)
    }

    @Test fun cancellingTheOnlyWaiterReleasesRefreshAndDiscardsLateResponse() = runTest {
        val prefs = fakePrefs().also { it.put("codexEnabled", true) }
        val h = harness(prefs)
        val gate = CompletableDeferred<Unit>()
        h.codexFetch = { gate.await(); snapshot(Provider.CODEX) }
        val waiting = async { h.store.refresh("only") }
        runCurrent()
        assertTrue(h.store.refreshing)
        h.store.cancelRefresh("only")
        assertTrue(waiting.await().cancelled)
        assertFalse(h.store.refreshing)
        gate.complete(Unit)
        advanceUntilIdle()
        assertTrue("A late response must not be accepted", h.store.snapshots.isEmpty())
    }

    @Test fun cancelledWaiterDoesNotCancelSharedForegroundRefresh() = runTest {
        val prefs = fakePrefs().also { it.put("codexEnabled", true) }
        val h = harness(prefs)
        val gate = CompletableDeferred<Unit>()
        h.codexFetch = { gate.await(); snapshot(Provider.CODEX) }
        val foreground = async { h.store.refresh("foreground") }
        val background = async { h.store.refresh("background") }
        runCurrent()
        h.store.cancelRefresh("background")
        assertTrue(background.await().cancelled)
        gate.complete(Unit)
        advanceUntilIdle()
        assertTrue(foreground.await().succeeded)
        assertEquals(1, h.store.snapshots.size)
    }

    @Test fun providerFailureKeepsLastReadingAndTimestamp() = runTest {
        val old = snapshot(Provider.CODEX, at = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.MILLIS).minusSeconds(600))
        val prefs = fakePrefs().also { it.put("codexEnabled", true) }
        val h = harness(prefs, listOf(old))
        h.codexFetch = { throw IOException("offline") }
        val result = async { h.store.refresh() }
        advanceUntilIdle()
        assertEquals(listOf(Provider.CODEX), result.await().failed)
        assertEquals(old, h.store.snapshots.single())
        assertEquals("offline", h.store.errors[Provider.CODEX])
    }

    @Test fun readingOlderThanTheRunIsNotReportedAsRefreshed() = runTest {
        val prefs = fakePrefs().also { it.put("codexEnabled", true) }
        val h = harness(prefs)
        h.codexFetch = { snapshot(Provider.CODEX, at = Instant.now().minusSeconds(3600)) }
        val result = async { h.store.refresh() }
        advanceUntilIdle()
        assertEquals(listOf(Provider.CODEX), result.await().failed)
        assertFalse(result.await().succeeded)
    }

    // endregion

    // region GitHub

    @Test fun savedAccountPublishesNewWidgetConfigurationBeforeFetching() = runTest {
        val h = harness()
        h.copilotFetch = { _, _ ->
            assertEquals("monalisa", h.widgetConfigs.last().username)
            snapshot(Provider.COPILOT)
        }
        val save = async { h.store.saveGitHub("monalisa", "", false, "token-1") }
        advanceUntilIdle()
        save.await()
        assertTrue(h.store.githubConfigured)
        assertEquals("monalisa", h.prefs.string("githubUsername"))
        assertEquals("invalidate.copilot", h.events.first())
        assertEquals(1, h.store.snapshots.size)
    }

    @Test fun blankReplacementTokenRetainsSavedCredential() = runTest {
        val h = harness()
        h.token = "kept"
        h.copilotFetch = { token, _ -> assertEquals("kept", token); snapshot(Provider.COPILOT) }
        val save = async { h.store.saveGitHub("monalisa", "", false, "  ") }
        advanceUntilIdle(); save.await()
        assertEquals("kept", h.token)
    }

    @Test fun missingTokenAndInvalidAllowanceAreReportedWithoutNetworking() = runTest {
        val h = harness()
        val missing = async { h.store.saveGitHub("monalisa", "", false, "") }
        advanceUntilIdle(); missing.await()
        assertNotNull(h.store.errors[Provider.COPILOT])
        assertFalse(h.store.githubConfigured)
        val invalid = async { h.store.saveGitHub("monalisa", "-3", false, "t", organizationPlan = false) }
        advanceUntilIdle(); invalid.await()
        assertNotNull(h.store.errors[Provider.COPILOT])
        assertEquals("", h.prefs.string("githubUsername") ?: "")
    }

    @Test fun personalPlanUsesBillingReportAndOrganizationPlanUsesQuota() = runTest {
        val h = harness()
        h.gitHubFetch = { _, _, allowance, legacy -> assertEquals(500.0, allowance); assertTrue(legacy); snapshot(Provider.COPILOT, source = "GitHub API · uso bruto") }
        val personal = async { h.store.saveGitHub("m", "500", true, "t", organizationPlan = false) }
        advanceUntilIdle(); personal.await()
        assertEquals("GitHub API · uso bruto", h.store.snapshots.single().source)

        h.copilotFetch = { _, _ -> snapshot(Provider.COPILOT, source = "Copilot · cuota") }
        val organization = async { h.store.saveGitHub("m", "", false, "", organizationPlan = true) }
        advanceUntilIdle(); organization.await()
        assertEquals("Copilot · cuota", h.store.snapshots.single().source)
    }

    @Test fun newOrganizationModeDropsMisleadingPersonalBillingCacheOnly() = runTest {
        val prefs = fakePrefs().also { it.put("githubUsername", "m") }
        val h = harness(prefs, listOf(snapshot(Provider.COPILOT, source = "GitHub API · uso bruto"), snapshot(Provider.CODEX)))
        assertEquals(listOf(Provider.CODEX), h.store.snapshots.map { it.provider })
        assertEquals(listOf(Provider.CODEX), h.cache.load().map { it.provider })
    }

    @Test fun quotaPermissionFailureDoesNotOverwriteLastValidReading() = runTest {
        val old = snapshot(Provider.COPILOT, at = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.MILLIS).minusSeconds(120), source = "Copilot · cuota")
        val h = harness(fakePrefs().also { it.put("githubUsername", "m") }, listOf(old))
        h.token = "t"
        h.copilotFetch = { _, _ -> throw com.jesusom.pulso.core.CopilotQuotaError.AccessDenied(403) }
        val result = async { h.store.refresh() }
        advanceUntilIdle()
        assertEquals(listOf(Provider.COPILOT), result.await().failed)
        assertEquals(old, h.store.snapshots.single())
    }

    // endregion

    // region Disconnecting

    @Test fun logoutInvalidatesWidgetBeforeDeletingCredentialAndPublishesDisconnectedState() = runTest {
        val h = harness(fakePrefs().also { it.put("githubUsername", "m") }, listOf(snapshot(Provider.COPILOT, source = "Copilot")))
        h.token = "t"
        h.store.disconnect(Provider.COPILOT)
        assertTrue(h.events.indexOf("invalidate.copilot") < h.events.indexOf("deleteToken"))
        assertNull(h.token)
        assertTrue(h.store.snapshots.isEmpty())
        assertEquals("", h.widgetConfigs.last().username)
        assertFalse(h.store.githubConfigured)
    }

    @Test fun logoutDoesNotRestoreInflightSnapshot() = runTest {
        val prefs = fakePrefs().also { it.put("codexEnabled", true) }
        val h = harness(prefs)
        val gate = CompletableDeferred<Unit>()
        h.codexFetch = { gate.await(); snapshot(Provider.CODEX) }
        val refresh = async { h.store.refresh() }
        runCurrent()
        h.store.disconnect(Provider.CODEX)
        gate.complete(Unit)
        advanceUntilIdle()
        assertTrue(refresh.await().cancelled)
        assertTrue(h.store.snapshots.isEmpty())
        assertFalse(h.store.codexConfigured)
    }

    @Test fun claudeRefreshAndLogoutPreserveOtherProviderSnapshots() = runTest {
        val prefs = fakePrefs().also { it.put("claudeEnabled", true) }
        val h = harness(prefs, listOf(snapshot(Provider.CODEX)))
        h.claudeFetch = { snapshot(Provider.CLAUDE) }
        val refresh = async { h.store.refresh() }
        advanceUntilIdle(); refresh.await()
        assertEquals(setOf(Provider.CODEX, Provider.CLAUDE), h.store.snapshots.map { it.provider }.toSet())
        h.store.disconnect(Provider.CLAUDE)
        assertEquals(listOf(Provider.CODEX), h.store.snapshots.map { it.provider })
        assertTrue(h.events.containsAll(listOf("deleteClaudeCredentials", "clearClaude")))
        assertFalse(h.store.claudeConfigured)
    }

    @Test fun codexCanClearSessionWithoutConfiguredConnection() = runTest {
        val h = harness()
        h.store.disconnect(Provider.CODEX)
        assertTrue(h.events.contains("clearCodex"))
        assertFalse(h.store.codexConfigured)
    }

    // endregion

    @Test fun demoNeverFetchesOrPersistsExampleSnapshots() = runTest {
        val h = harness()
        val published = h.widgetConfigs.size
        h.store.changeDemo(true)
        assertTrue(h.store.demo)
        assertEquals(Provider.entries.size, Provider.entries.count { h.store.snapshot(it) != null })
        val result = h.store.refresh()
        assertTrue(result.attempted.isEmpty())
        assertTrue(h.cache.load().isEmpty())
        assertEquals("Demo must not publish widget configuration", published, h.widgetConfigs.size)
        h.store.changeDemo(false)
        assertNull(h.store.snapshot(Provider.CODEX))
    }

    @Test fun developmentResetRestoresDefaults() = runTest {
        val prefs = fakePrefs()
        prefs.putList("hiddenProviders", listOf("claude"))
        val h = harness(prefs)
        h.store.changeQuotaDisplay(QuotaDisplay.USED)
        h.store.resetDevelopmentPreferences()
        assertEquals(Provider.entries, h.store.visibleProviders)
        assertEquals(QuotaDisplay.REMAINING, h.store.quotaDisplay)
    }

    @Test fun resetAlertsStayOffWhenPermissionIsDenied() = runTest {
        val h = harness()
        h.store.setResetAlerts(true)
        assertFalse(h.store.resetAlerts)
        assertTrue(h.store.notificationsDenied)
        assertFalse(h.prefs.bool("resetAlerts"))
    }
}
