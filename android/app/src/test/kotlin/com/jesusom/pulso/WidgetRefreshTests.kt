package com.jesusom.pulso

import com.jesusom.pulso.core.ClaudeQuotaError
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.QuotaDisplay
import com.jesusom.pulso.core.QuotaTimeline
import com.jesusom.pulso.core.SharedQuotaAccess
import com.jesusom.pulso.core.SnapshotCache
import com.jesusom.pulso.core.SummaryQuotaValue
import com.jesusom.pulso.core.SummaryWidgetState
import com.jesusom.pulso.core.UsageSnapshot
import com.jesusom.pulso.core.UsageWindow
import com.jesusom.pulso.core.WidgetQuotaConfiguration
import com.jesusom.pulso.core.WidgetQuotaRefresh
import com.jesusom.pulso.core.WidgetQuotaState
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.time.Instant
import java.util.concurrent.atomic.AtomicInteger

class WidgetRefreshTests {
    private val now: Instant = Instant.ofEpochSecond(2_000_000)
    private val org = "01531D14-44AB-4DBB-9D96-02CFD19C7712"

    private fun configuration(claude: String? = null) = WidgetQuotaConfiguration(
        codexEnabled = true, username = "monalisa", allowance = null, legacy = false, organizationPlan = true,
        claudeOrganizationID = claude,
    )

    private fun snapshot(provider: Provider, at: Instant, resetsAt: Instant? = at.plusSeconds(3600)) =
        UsageSnapshot(provider, listOf(UsageWindow("w", "Sesión", 10.0, 100.0, resetsAt)), at, "test")

    private fun refresher(
        configuration: WidgetQuotaConfiguration?, cache: MutableList<UsageSnapshot> = mutableListOf(),
        reserve: (Provider) -> Boolean = { true },
        fetch: suspend (Provider) -> UsageSnapshot = { snapshot(it, now) },
        commit: (UsageSnapshot) -> Boolean = { cache.add(it); true },
        failures: MutableList<Provider> = mutableListOf(),
    ) = WidgetQuotaRefresh(
        WidgetQuotaRefresh.Dependencies(
            configuration = { configuration }, snapshots = { cache.toList() },
            reserve = { provider, _, _, _ -> reserve(provider) }, fetch = { provider, _ -> fetch(provider) },
            commit = { snapshot, _ -> commit(snapshot) }, now = { now },
            recordFailure = { provider, _, _ -> failures += provider },
        )
    )

    @Test fun oauthLockSerializesIndependentRefreshConsumers() = runTest {
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        List(2) {
            async {
                SharedQuotaAccess.withOAuthLock {
                    maximum.accumulateAndGet(active.incrementAndGet(), ::maxOf)
                    delay(50)
                    active.decrementAndGet()
                }
            }
        }.awaitAll()
        assertEquals("Rotating refresh tokens must have only one owner at a time", 1, maximum.get())
    }

    @Test fun successfulRefreshMergesIndependentProvidersAndPreservesClaude() = runTest {
        val cache = mutableListOf(snapshot(Provider.CLAUDE, now.minusSeconds(600)))
        val result = refresher(configuration(), cache).refresh()
        assertEquals(setOf(Provider.CODEX, Provider.COPILOT, Provider.CLAUDE), result.map { it.provider }.toSet())
        assertEquals(now.minusSeconds(600), result.first { it.provider == Provider.CLAUDE }.updatedAt)
    }

    @Test fun failureKeepsOriginalReadingAndTimestamp() = runTest {
        val cache = mutableListOf(snapshot(Provider.CODEX, now.minusSeconds(600)))
        val failures = mutableListOf<Provider>()
        val result = refresher(
            configuration(), cache, fetch = { throw IOException("offline") },
            commit = { error("Failed networking must not overwrite cache") }, failures = failures,
        ).refresh()
        assertEquals(cache, result)
        assertEquals(listOf(Provider.CODEX, Provider.COPILOT), failures)
    }

    @Test fun freshCacheDoesNotIssueRequests() = runTest {
        val cache = mutableListOf(snapshot(Provider.CODEX, now), snapshot(Provider.COPILOT, now))
        val result = refresher(
            configuration(), cache, reserve = { error("Fresh data must not consume a request") },
            fetch = { error("no network") },
        ).refresh()
        assertEquals(cache, result)
    }

    @Test fun readingPastItsRenewalIsRefetchedEvenWhenRecent() = runTest {
        val fetched = mutableListOf<Provider>()
        val cache = mutableListOf(snapshot(Provider.CODEX, now.minusSeconds(30), resetsAt = now.minusSeconds(1)))
        refresher(configuration(), cache, fetch = { fetched += it; snapshot(it, now) }).refresh(setOf(Provider.CODEX))
        assertEquals(listOf(Provider.CODEX), fetched)
    }

    @Test fun missingConfigurationNeverReservesNetworking() = runTest {
        val result = refresher(null, reserve = { error("No configuration must not reserve networking") }).refresh(setOf(Provider.CODEX))
        assertTrue(result.isEmpty())
    }

    @Test fun claudeWithoutSharedOrganizationNeverFetches() = runTest {
        val result = refresher(configuration(), reserve = { error("Claude requires a shared organization") }).refresh(setOf(Provider.CLAUDE))
        assertTrue(result.isEmpty())
    }

    @Test fun claudeTimelineFetchesOnlyClaudeAndSummaryIncludesAllConfiguredProviders() = runTest {
        val fetched = mutableListOf<Provider>()
        val cache = mutableListOf<UsageSnapshot>()
        val r = refresher(configuration(org), cache, fetch = { fetched += it; snapshot(it, now) })
        r.refresh(setOf(Provider.CLAUDE))
        assertEquals(listOf(Provider.CLAUDE), fetched)
        cache.clear(); fetched.clear()
        r.refresh()
        assertEquals(Provider.entries.toSet(), fetched.toSet())
    }

    @Test fun claudeChallengeKeepsLastReadingAndRecordsFailure() = runTest {
        val cache = mutableListOf(snapshot(Provider.CLAUDE, now.minusSeconds(600)))
        val failures = mutableListOf<Provider>()
        val result = refresher(
            configuration(org), cache, fetch = { throw ClaudeQuotaError.Cloudflare },
            commit = { error("Challenge must not overwrite cache") }, failures = failures,
        ).refresh(setOf(Provider.CLAUDE))
        assertEquals(cache, result)
        assertEquals(listOf(Provider.CLAUDE), failures)
    }

    @Test fun wrongProviderAndOldResponseCannotOverwriteCache() = runTest {
        val cache = mutableListOf<UsageSnapshot>()
        refresher(configuration(), cache, fetch = { snapshot(Provider.COPILOT, now) }).refresh(setOf(Provider.CODEX))
        assertTrue(cache.isEmpty())
        refresher(configuration(), cache, fetch = { snapshot(it, now.minusSeconds(1)) }).refresh(setOf(Provider.CODEX))
        assertTrue(cache.isEmpty())
    }

    @Test fun manualRefreshIgnoresFreshCacheButOnlyForRequestedProvider() = runTest {
        val fetched = mutableListOf<Provider>()
        val cache = mutableListOf(snapshot(Provider.CODEX, now), snapshot(Provider.COPILOT, now))
        refresher(configuration(), cache, fetch = { fetched += it; snapshot(it, now.plusSeconds(1)) })
            .refresh(setOf(Provider.CODEX), userInitiated = true)
        assertEquals(listOf(Provider.CODEX), fetched)
    }

    // region Storage: reservations, fencing, merging

    private fun state(): Triple<WidgetQuotaState, SnapshotCache, com.jesusom.pulso.core.PulsoPrefs> {
        val prefs = fakePrefs()
        val cache = SnapshotCache(prefs)
        return Triple(WidgetQuotaState(prefs, cache), cache, prefs)
    }

    @Test fun logoutRejectsLateWidgetResultAndCacheMergeNeverRollsBack() {
        val (widgetState, cache, _) = state()
        val config = configuration()
        widgetState.save(config)
        widgetState.save(config.copy(revision = "ignored")) // identical content keeps the revision
        val saved = widgetState.load()!!
        assertEquals(config.revision, saved.revision)
        // Disconnect bumps the revision and drops the provider reading.
        widgetState.invalidate(Provider.CODEX)
        assertFalse("Late response from a signed-out revision must be rejected", widgetState.commit(snapshot(Provider.CODEX, now), saved))
        assertTrue(cache.load().isEmpty())
        // A newer cached reading is never replaced by an older one.
        cache.merge(snapshot(Provider.COPILOT, now))
        cache.merge(snapshot(Provider.COPILOT, now.minusSeconds(60)))
        assertEquals(now, cache.load().single().updatedAt)
    }

    @Test fun reservationAllowsRetryButPreventsRepeatedAndOverlappingRequests() {
        val (widgetState, _, _) = state()
        val config = configuration()
        widgetState.save(config)
        val current = widgetState.load()!!
        assertTrue(widgetState.reserve(Provider.CODEX, current, now))
        assertFalse("Overlapping automatic request", widgetState.reserve(Provider.CODEX, current, now.plusSeconds(60)))
        assertFalse("Too soon for a manual retry", widgetState.reserve(Provider.CODEX, current, now.plusSeconds(5), userInitiated = true))
        assertFalse("A request still marked in progress blocks retries", widgetState.reserve(Provider.CODEX, current, now.plusSeconds(11), userInitiated = true))
        widgetState.recordFailure(Provider.CODEX, current, java.io.IOException())
        assertTrue("Once finished, a manual retry is allowed after ten seconds", widgetState.reserve(Provider.CODEX, current, now.plusSeconds(11), userInitiated = true))
        assertTrue("Other providers are independent", widgetState.reserve(Provider.COPILOT, current, now))
        assertFalse("A stale configuration cannot reserve", widgetState.reserve(Provider.CLAUDE, current.copy(revision = "old"), now))
    }

    // endregion

    // region Summary

    @Test fun mixedReadingsKeepEveryProviderInStableOrderAndMissingQuotaUnknown() {
        val state = SummaryWidgetState(listOf(snapshot(Provider.CLAUDE, now)), QuotaDisplay.REMAINING)
        assertEquals(listOf(Provider.CODEX, Provider.COPILOT, Provider.CLAUDE), state.readings.map { it.provider })
        assertNull(state.readings[0].updatedAt)
        assertEquals(SummaryQuotaValue.Unavailable, state.readings[0].value(state.readings[0].windows.firstOrNull(), QuotaDisplay.REMAINING))
        assertEquals(SummaryQuotaValue.Percent(90), state.readings[2].value(state.readings[2].windows.first(), QuotaDisplay.REMAINING))
    }

    @Test fun preferenceAppliesToAllWindowsWithoutInventingUnknownRemainingBalances() {
        val credits = UsageWindow("copilot_credits", "Créditos del mes", 3251.0, null, null)
        val reading = SummaryWidgetState(
            listOf(UsageSnapshot(Provider.COPILOT, listOf(credits), now, "")), QuotaDisplay.REMAINING,
        ).readings[1]
        assertEquals(SummaryQuotaValue.Unavailable, reading.value(credits, QuotaDisplay.REMAINING))
        assertEquals(SummaryQuotaValue.Amount(3251.0), reading.value(credits, QuotaDisplay.USED))
    }

    @Test fun ageAndExpiredResetsMarkOriginalReadingStaleWithoutRefillingQuota() {
        val reading = SummaryWidgetState(listOf(snapshot(Provider.CODEX, now)), QuotaDisplay.USED).readings[0]
        assertFalse(reading.isStale(now.plusSeconds(299)))
        assertTrue(reading.isStale(now.plusSeconds(301)))
        assertTrue("A countdown reaching zero is not a fresh reading", reading.isStale(now.plusSeconds(3600)))
        assertTrue("A reading from the future is stale", reading.isStale(now.minusSeconds(10)))
    }

    @Test fun mergedTimelineIncludesEveryProviderAndWindowWithoutDuplicatesOrPastDates() {
        val a = snapshot(Provider.CODEX, now, resetsAt = now.plusSeconds(3600))
        val b = snapshot(Provider.CLAUDE, now, resetsAt = now.plusSeconds(3600))
        val dates = SummaryWidgetState(listOf(a, b), QuotaDisplay.USED).transitionDates(now.plusSeconds(1))
        assertEquals(listOf(now.plusSeconds(301), now.plusSeconds(3600)), dates)
        assertEquals(emptyList<Instant>(), QuotaTimeline.transitionDates(null, now))
        assertEquals(listOf(now.plusSeconds(3600)), QuotaTimeline.transitionDates(a, now.plusSeconds(400)))
    }

    // endregion
}
