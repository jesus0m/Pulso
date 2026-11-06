package com.jesusom.pulso

import com.jesusom.pulso.core.CodexUsageParser
import com.jesusom.pulso.core.GitHubUsageClient
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.QuotaDisplay
import com.jesusom.pulso.core.UsageError
import com.jesusom.pulso.core.UsageSnapshot
import com.jesusom.pulso.core.UsageWindow
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class UsageTests {
    private fun window(used: Double, limit: Double?, id: String = "w") = UsageWindow(id, "Mes", used, limit, null)

    @Test fun previouslyCachedWindowsKeepDerivedPercentagesWithoutReportedBalances() {
        val restored = UsageWindow.fromJson(JSONObject("""{"id":"session","title":"Sesión","used":55,"limit":100}"""))
        assertNull(restored.remaining)
        assertNull(restored.reportedRemainingPercent)
        assertEquals(55, restored.displayedUsedPercent)
        assertEquals(45, restored.displayedRemainingPercent)
    }

    @Test fun remainingPercentageClampsExhaustedAndRejectsUnknownAllowance() {
        assertEquals(0.0, window(125.0, 100.0).remainingPercent!!, 0.0)
        assertNull(window(0.0, null).remainingPercent)
        assertNull(window(0.0, 0.0).remainingPercent)
    }

    @Test fun usedAndAvailablePercentagesMatchIdeInterpretation() {
        val session = window(55.0, 100.0)
        assertEquals(55, session.displayedUsedPercent)
        assertEquals(45, session.displayedRemainingPercent)
        val fractional = window(18.4, 100.0)
        assertEquals(100, fractional.displayedUsedPercent!! + fractional.displayedRemainingPercent!!)
        assertNull(window(1.0, null).displayedUsedPercent)
    }

    @Test fun quotaDisplaySwapsHeadlineAndComplementWithoutLosingEitherFigure() {
        val w = window(72.0, 100.0)
        assertEquals(28, w.displayedPercent(QuotaDisplay.REMAINING))
        assertEquals(72, w.complementPercent(QuotaDisplay.REMAINING))
        assertEquals(72, w.displayedPercent(QuotaDisplay.USED))
        assertEquals(28, w.complementPercent(QuotaDisplay.USED))
    }

    @Test fun reportedRemainingBalanceTakesPrecedenceOverDerivedPercentage() {
        val w = UsageWindow("c", "Créditos del mes", 6134.0, 60000.0, null, 53774.0, 89.6)
        assertEquals(90, w.displayedRemainingPercent)
        assertEquals(89.6, w.remainingPercent!!, 0.00001)
        val invalid = UsageWindow("c", "x", 10.0, 100.0, null, null, 140.0)
        assertEquals(90, invalid.displayedRemainingPercent)
    }

    @Test fun quotaDisplayLeavesUnknownQuotaUnrepresented() {
        val w = UsageWindow("c", "Créditos", 3251.0, null, null)
        QuotaDisplay.entries.forEach {
            assertNull(w.displayedPercent(it))
            assertNull(w.complementPercent(it))
        }
    }

    @Test fun snapshotsRoundTripThroughTheCacheFormat() {
        val snapshot = UsageSnapshot(
            Provider.COPILOT,
            listOf(UsageWindow("copilot_credits", "Créditos del mes", 6134.0, 60000.0, NOW.plusSeconds(60), 53774.0, 89.6)),
            NOW, "src",
        )
        val restored = UsageSnapshot.fromJson(JSONObject(snapshot.toJson().toString()))
        assertEquals(snapshot, restored)
    }

    // region Codex

    @Test fun codexParsesActualIndependentWindows() {
        val data = bytes("""{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":27,"reset_at":1793768400,"limit_window_seconds":18000},"secondary_window":{"used_percent":100,"reset_at":1794000000,"limit_window_seconds":604800}}}""")
        val snapshot = CodexUsageParser.parse(data, NOW)
        assertEquals(Provider.CODEX, snapshot.provider)
        assertEquals(NOW, snapshot.updatedAt)
        assertEquals(listOf(73.0, 0.0), snapshot.windows.map { it.remainingPercent })
        assertEquals(listOf("Sesión · 5 h", "Semana · 7 d"), snapshot.windows.map { it.title })
        assertEquals(Instant.ofEpochSecond(1_793_768_400), snapshot.windows[0].resetsAt)
    }

    @Test fun codexRejectsMissingMalformedAndOutOfRangeWindows() {
        listOf(
            "{}", """{"rate_limit":null}""", """{"rate_limit":{"primary_window":null}}""",
            """{"rate_limit":{"primary_window":{"used_percent":-1,"reset_at":1793768400,"limit_window_seconds":18000}}}""",
            """{"rate_limit":{"primary_window":{"used_percent":101,"reset_at":1793768400,"limit_window_seconds":18000}}}""",
            """{"rate_limit":{"primary_window":{"used_percent":"27","reset_at":1793768400,"limit_window_seconds":18000}}}""",
            """{"rate_limit":{"primary_window":{"used_percent":27,"reset_at":0,"limit_window_seconds":18000}}}""",
            """{"rate_limit":{"primary_window":{"used_percent":27,"reset_at":1793768400}}}""",
        ).forEach { fixture ->
            assertThrows(fixture, UsageError.UnsupportedSchema::class.java) { CodexUsageParser.parse(bytes(fixture)) }
        }
    }

    @Test fun codexPermitsOneKnownWindowWithoutInventingSecondQuota() {
        val data = bytes("""{"rate_limit":{"primary_window":{"used_percent":0,"reset_at":1793768400,"limit_window_seconds":18000},"secondary_window":null}}""")
        assertEquals(1, CodexUsageParser.parse(data).windows.size)
    }

    // endregion

    // region GitHub billing

    @Test fun gitHubUsesGrossUsageAndFiltersOtherProducts() {
        val fixture = """{"timePeriod":{"year":2026,"month":11},"user":"monalisa","usageItems":[{"product":"Copilot AI Credits","sku":"AI Credit","model":"GPT-5","unitType":"ai-credits","grossQuantity":100,"discountQuantity":100,"netQuantity":0},{"product":"Copilot AI Credits","sku":"AI Credit","model":"Other","unitType":"ai-credits","grossQuantity":25},{"product":"Spark","sku":"Spark AI Credits","unitType":"ai-credits","grossQuantity":900}]}"""
        val snapshot = GitHubUsageClient.parse(bytes(fixture), 500.0, legacy = false, now = NOW)
        assertEquals(125.0, snapshot.windows[0].used, 0.0)
        assertEquals(75.0, snapshot.windows[0].remainingPercent!!, 0.0)
        assertTrue(snapshot.source.contains("manual"))
        assertEquals(Instant.parse("2026-12-01T00:00:00Z"), snapshot.windows[0].resetsAt)
    }

    @Test fun gitHubLegacyDoesNotInferEntitlement() {
        val data = bytes("""{"usageItems":[{"product":"Copilot","sku":"Copilot Premium Request","unitType":"requests","grossQuantity":300,"netQuantity":0}]}""")
        val snapshot = GitHubUsageClient.parse(data, null, legacy = true, now = NOW)
        assertEquals(300.0, snapshot.windows[0].used, 0.0)
        assertNull(snapshot.windows[0].limit)
        assertNull(snapshot.windows[0].remainingPercent)
    }

    @Test fun gitHubRejectsMalformedRowsUnitsAndAllowance() {
        listOf(
            "{}",
            """{"usageItems":[{"product":"Copilot AI Credits","sku":"AI Credit","unitType":"dollars","grossQuantity":2}]}""",
            """{"usageItems":[{"product":"Copilot AI Credits","sku":"AI Credit","unitType":"ai-credits","grossQuantity":-1}]}""",
        ).forEach { assertThrows(UsageError.UnsupportedSchema::class.java) { GitHubUsageClient.parse(bytes(it), null, false, NOW) } }
        assertThrows(UsageError.InvalidAllowance::class.java) { GitHubUsageClient.parse(bytes("""{"usageItems":[]}"""), 0.0, false, NOW) }
    }

    @Test fun gitHubEmptyReportDoesNotClaimZeroConsumption() {
        assertThrows(UsageError.NoUsageData::class.java) { GitHubUsageClient.parse(bytes("""{"usageItems":[]}"""), null, false, NOW) }
    }

    @Test fun gitHubExplicitZeroConsumptionIsStillValid() {
        val data = bytes("""{"usageItems":[{"product":"Copilot","unitType":"credits","grossQuantity":0}]}""")
        assertEquals(0.0, GitHubUsageClient.parse(data, 100.0, false).windows.first().used, 0.0)
    }

    @Test fun gitHubFetchRejectsInvalidUsernameAndTokenBeforeNetwork() = kotlinx.coroutines.test.runTest {
        val transport = FakeTransport { error("must not reach the network") }
        val client = GitHubUsageClient(transport) { NOW }
        for ((user, token) in listOf("" to "t", "-bad" to "t", "bad-" to "t", "a".repeat(40) to "t", "ok" to "", "ok" to "a b", "ok" to "a\nb")) {
            assertThrows(UsageError.InvalidCredentials::class.java) { kotlinx.coroutines.runBlocking { client.fetch(user, token, null, false) } }
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun gitHubFetchUsesBillingEndpointForTheCurrentUtcMonth() = kotlinx.coroutines.test.runTest {
        val transport = FakeTransport { response(200, """{"usageItems":[{"product":"Copilot","unitType":"requests","grossQuantity":3}]}""") }
        GitHubUsageClient(transport) { NOW }.fetch(" monalisa ", " token ", null, legacy = true)
        val request = transport.requests.single()
        assertEquals("https://api.github.com/users/monalisa/settings/billing/premium_request/usage?year=2026&month=11", request.url)
        assertEquals("Bearer token", request.headers["Authorization"])
        assertEquals("2026-03-10", request.headers["X-GitHub-Api-Version"])
        assertNotNull(request.headers["Accept"])
    }

    @Test fun gitHubFetchMapsHttpStatus() = kotlinx.coroutines.test.runTest {
        val transport = FakeTransport { response(404) }
        val error = runCatching { GitHubUsageClient(transport) { NOW }.fetch("u", "t", null, false) }.exceptionOrNull()
        assertEquals(UsageError.Http(404), error)
    }

    // endregion
}
