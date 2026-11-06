package com.jesusom.pulso

import com.jesusom.pulso.core.CopilotQuotaClient
import com.jesusom.pulso.core.CopilotQuotaError
import com.jesusom.pulso.core.UsageSnapshot
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class CopilotQuotaTests {
    private fun parse(json: String, allowance: Double? = null, now: Instant = NOW) =
        CopilotQuotaClient.parse(bytes(json), allowance, now)

    @Test fun businessAiCreditsPreservePublishedMonthlyValuesAcrossCacheRoundTrip() {
        val data = """{"copilot_plan":"business","token_based_billing":true,"quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"credits_used":6134,"entitlement":60000,"remaining":53774,"percent_remaining":89.6,"token_based_billing":true},"chat":{"credits_used":6134,"entitlement":999999,"remaining":1,"percent_remaining":1}}}"""
        for (manual in listOf(null, 120000.0)) {
            val restored = UsageSnapshot.fromJson(JSONObject(parse(data, manual).toJson().toString()))!!
            val window = restored.windows.single()
            assertEquals(6134.0, window.used, 0.0)
            assertEquals(60000.0, window.limit!!, 0.0)
            assertEquals(89.6, window.remainingPercent!!, 0.00001)
            assertEquals(90, window.displayedRemainingPercent)
            assertEquals(Instant.parse("2026-12-01T00:00:00Z"), window.resetsAt)
            assertEquals("Preserve GitHub's balance, not 60000 - 6134", 53774.0, window.remaining!!, 0.0)
        }
    }

    @Test fun tokenBasedBillingFallsBackOnlyForMissingOrInvalidEntitlement() {
        for (entitlement in listOf("null", "-1", "0", "\"invalid\"", "true")) {
            val data = """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":6134,"entitlement":$entitlement}}}"""
            assertEquals(entitlement, 70000.0, parse(data, 70000.0).windows.first().limit!!, 0.0)
            assertNull(entitlement, parse(data).windows.first().limit)
        }
        val missing = """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":6134}}}"""
        assertEquals(70000.0, parse(missing, 70000.0).windows.first().limit!!, 0.0)
    }

    @Test fun publishedRemainingPercentageDoesNotNeedAManualLimit() {
        val snapshot = parse("""{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":100,"remaining":0,"percent_remaining":0}}}""")
        assertEquals(0.0, snapshot.windows.first().remainingPercent!!, 0.0)
        assertEquals(0, snapshot.windows.first().displayedRemainingPercent)
        assertNull(snapshot.windows.first().limit)
    }

    @Test fun malformedPublishedCreditBalancesAreRejected() {
        listOf("\"remaining\":-1", "\"remaining\":\"53774\"", "\"remaining\":true", "\"percent_remaining\":-0.1", "\"percent_remaining\":100.1").forEach { fields ->
            val fixture = """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":6134,"entitlement":60000,$fields}}}"""
            assertThrows(fixture, CopilotQuotaError.UnsupportedSchema::class.java) { parse(fixture) }
        }
    }

    @Test fun businessPremiumQuotaPreservesCountsAndPlan() {
        val snapshot = parse(
            """{"copilot_plan":"business","quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":75,"unlimited":false},"chat":{"entitlement":-1,"percent_remaining":100,"unlimited":true}},"future_field":true}""",
            now = Instant.ofEpochSecond(123),
        )
        assertEquals("Copilot · cuota de cuenta experimental · plan business", snapshot.source)
        val window = snapshot.windows.single()
        assertEquals("copilot_premium", window.id)
        assertEquals("Premium · cuenta", window.title)
        assertEquals(75.0, window.used, 0.0)
        assertEquals(300.0, window.limit!!, 0.0)
        assertEquals(75.0, window.remainingPercent!!, 0.0)
        assertEquals(Instant.parse("2026-12-01T00:00:00Z"), window.resetsAt)
    }

    @Test fun chatQuotaAndFractionalResetDate() {
        val snapshot = parse("""{"copilot_plan":"enterprise","quota_reset_date":"2026-12-01T02:00:00.125+02:00","quota_snapshots":{"premium_interactions":null,"chat":{"entitlement":500,"percent_remaining":20,"unlimited":false}}}""")
        assertEquals(listOf("copilot_chat"), snapshot.windows.map { it.id })
        assertEquals(400.0, snapshot.windows[0].used, 0.0)
        assertEquals(Instant.parse("2026-12-01T00:00:00.125Z"), snapshot.windows[0].resetsAt)
    }

    @Test fun bothQuotasPreserveIndependentCountsAndMissingReset() {
        val snapshot = parse("""{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":0},"chat":{"entitlement":50,"percent_remaining":100}}}""")
        assertEquals(listOf(300.0, 0.0), snapshot.windows.map { it.used })
        assertEquals(listOf(300.0, 50.0), snapshot.windows.map { it.limit })
        assertTrue(snapshot.windows.all { it.resetsAt == null })
    }

    @Test fun publishedOverageIsAddedOnceAfterIncludedQuotaIsExhausted() {
        val snapshot = parse("""{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":0,"overage_count":12}}}""")
        assertEquals(312.0, snapshot.windows[0].used, 0.0)
        assertEquals(300.0, snapshot.windows[0].limit!!, 0.0)
    }

    @Test fun tokenBasedBillingUsesPremiumCreditsWithoutSummingDuplicateChatCredits() {
        val snapshot = parse(
            """{"copilot_plan":"business","token_based_billing":true,"quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"credits_used":15.5,"entitlement":-1,"percent_remaining":100,"unlimited":true},"chat":{"credits_used":15.5},"completions":{"credits_used":99}}}""",
        )
        assertEquals("Copilot · créditos comunicados · cuenta experimental · plan business", snapshot.source)
        val window = snapshot.windows.single()
        assertEquals("copilot_credits", window.id)
        assertEquals("Créditos usados · cuenta", window.title)
        assertEquals(15.5, window.used, 0.0)
        assertNull(window.limit)
        assertEquals(100.0, window.remainingPercent!!, 0.0)
    }

    @Test fun tokenBasedBillingAppliesManualAllowanceForPercentage() {
        val data = """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":3810}}}"""
        val window = parse(data, 60000.0).windows[0]
        assertEquals(60000.0, window.limit!!, 0.0)
        assertEquals(6, window.displayedUsedPercent)
        assertNull(parse(data, -5.0).windows[0].limit)
    }

    @Test fun tokenBasedBillingPreservesExplicitZeroCreditsAndDoesNotFallBackToChat() {
        val snapshot = parse("""{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":0},"chat":{"credits_used":42}}}""")
        assertEquals(0.0, snapshot.windows.single().used, 0.0)
        assertNull(snapshot.windows[0].limit)
        assertNull(snapshot.windows[0].resetsAt)
    }

    @Test fun tokenBasedBillingFallsBackToPublishedChatCreditsAndIgnoresUnknownResetDate() {
        val snapshot = parse("""{"token_based_billing":true,"quota_reset_date":"tomorrow","quota_snapshots":{"premium_interactions":{"credits_used":null},"chat":{"credits_used":3.25}}}""")
        assertEquals(3.25, snapshot.windows.single().used, 0.0)
        assertNull(snapshot.windows[0].resetsAt)
    }

    @Test fun tokenBasedBillingRequiresPublishedCreditValues() {
        listOf(
            """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":null},"chat":{"credits_used":null}}}""",
            """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{},"chat":{},"completions":{"credits_used":10}}}""",
        ).forEach { assertThrows(CopilotQuotaError.NoPublishedQuota::class.java) { parse(it) } }
    }

    @Test fun malformedTokenBasedCreditValuesAreRejected() {
        listOf(
            """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":"15.5"}}}""",
            """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":true}}}""",
            """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":-1}}}""",
        ).forEach { assertThrows(it, CopilotQuotaError.UnsupportedSchema::class.java) { parse(it) } }
    }

    @Test fun unpublishedAndPlaceholderQuotasNeverProduceFakeZero() {
        listOf(
            "{}", """{"quota_snapshots":null}""",
            """{"quota_snapshots":{"future":{"entitlement":300,"percent_remaining":100}}}""",
            """{"quota_snapshots":{"premium_interactions":null,"chat":null}}""",
            """{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":100}}}""",
            """{"quota_snapshots":{"premium_interactions":{"entitlement":-1,"percent_remaining":100}}}""",
            """{"quota_snapshots":{"premium_interactions":{"entitlement":0,"percent_remaining":100}}}""",
            """{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":100,"unlimited":true}}}""",
            """{"quota_snapshots":{"premium_interactions":{"entitlement":300}}}""",
            """{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":null}}}""",
            """{"quota_snapshots":{"premium_interactions":{"percent_remaining":25}}}""",
        ).forEach { assertThrows(it, CopilotQuotaError.NoPublishedQuota::class.java) { parse(it) } }
    }

    @Test fun malformedKnownDataIsRejected() {
        listOf(
            "not JSON", "[]",
            """{"quota_snapshots":false}""",
            """{"quota_snapshots":{"premium_interactions":false}}""",
            """{"quota_snapshots":{"chat":{"entitlement":"300","percent_remaining":25}}}""",
            """{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":true}}}""",
            """{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":-1}}}""",
            """{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":101}}}""",
            """{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":25,"overage_count":-1}}}""",
            """{"quota_reset_date":"tomorrow","quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":25}}}""",
            """{"quota_reset_date":"2026-02-30","quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":25}}}""",
        ).forEach { assertThrows(it, CopilotQuotaError.UnsupportedSchema::class.java) { parse(it) } }
    }

    @Test fun fetchUsesOnlySuppliedTokenAndTruthfulHeaders() = runTest {
        val transport = FakeTransport { response(200, """{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":25}}}""") }
        CopilotQuotaClient(transport) { NOW }.fetch("  secret-token ")
        val request = transport.requests.single()
        assertEquals("https://api.github.com/copilot_internal/user", request.url)
        assertEquals("GET", request.method)
        assertEquals("token secret-token", request.headers["Authorization"])
        assertEquals("PULSO/1.0", request.headers["User-Agent"])
        assertEquals("2026-03-10", request.headers["X-GitHub-Api-Version"])
    }

    @Test fun fetchDistinguishesAuthorizationAndEndpointAvailability() = runTest {
        for ((status, expected) in listOf(
            401 to CopilotQuotaError.AccessDenied(401), 403 to CopilotQuotaError.AccessDenied(403),
            404 to CopilotQuotaError.Unavailable, 500 to CopilotQuotaError.Http(500),
        )) {
            val error = runCatching { CopilotQuotaClient(FakeTransport { response(status) }) { NOW }.fetch("token") }.exceptionOrNull()
            assertEquals(expected, error)
        }
    }

    @Test fun fetchRejectsEmptyOrWhitespaceContainingTokensBeforeNetwork() = runTest {
        val transport = FakeTransport { error("must not reach the network") }
        for (token in listOf("", "  ", "a b", "a\nb")) {
            val error = runCatching { CopilotQuotaClient(transport) { NOW }.fetch(token) }.exceptionOrNull()
            assertEquals(com.jesusom.pulso.core.UsageError.InvalidCredentials, error)
        }
        assertTrue(transport.requests.isEmpty())
    }
}
