package com.jesusom.pulso

import com.jesusom.pulso.core.ClaudeCredentialVault
import com.jesusom.pulso.core.ClaudeQuotaClient
import com.jesusom.pulso.core.ClaudeQuotaError
import com.jesusom.pulso.core.ClaudeUsageParser
import com.jesusom.pulso.core.ClaudeWebCredentials
import com.jesusom.pulso.core.InMemorySecretStore
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.UsageError
import com.jesusom.pulso.core.WebCookie
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class ClaudeTests {
    private val organizationID = "01531D14-44AB-4DBB-9D96-02CFD19C7712"
    private val body = """{"five_hour":{"utilization":27,"resets_at":null},"seven_day":{"utilization":42,"resets_at":"2026-11-12T12:00:00Z"}}"""
    private val url get() = "https://claude.ai/api/organizations/$organizationID/usage"
    private fun credentials() = ClaudeWebCredentials("sk-ant-fixture", organizationID, null)

    // region Parser

    @Test fun knownWindowsKeepIndependentResetDatesAndPercentages() {
        val now = Instant.ofEpochSecond(100)
        val snapshot = ClaudeUsageParser.parse(
            bytes("""{"five_hour":{"utilization":27.5,"resets_at":"2026-11-04T12:00:00Z"},"seven_day":{"utilization":100,"resets_at":"2026-11-10T00:00:00.123Z"},"seven_day_opus":{"utilization":0,"resets_at":"2026-11-11T00:00:00Z"},"seven_day_sonnet":{"utilization":12,"resets_at":"2026-11-12T00:00:00Z"},"extra_usage":{"utilization":999,"monthly_limit":1000}}"""),
            now,
        )
        assertEquals(Provider.CLAUDE, snapshot.provider)
        assertEquals(now, snapshot.updatedAt)
        assertEquals("Claude · sesión web experimental", snapshot.source)
        assertEquals(listOf("five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"), snapshot.windows.map { it.id })
        assertEquals(listOf("Sesión · 5 h", "Semana", "Semana · Opus", "Semana · Sonnet"), snapshot.windows.map { it.title })
        assertEquals(listOf(72.5, 0.0, 100.0, 88.0), snapshot.windows.map { it.remainingPercent })
        assertEquals(Instant.parse("2026-11-04T12:00:00Z"), snapshot.windows[0].resetsAt)
        assertEquals(Instant.parse("2026-11-10T00:00:00.123Z"), snapshot.windows[1].resetsAt)
    }

    @Test fun nullResetIsUnknownWhileMissingResetFieldIsSchemaDrift() {
        assertNull(ClaudeUsageParser.parse(bytes(body)).windows[0].resetsAt)
        assertThrows(UsageError.UnsupportedSchema::class.java) {
            ClaudeUsageParser.parse(bytes("""{"five_hour":{"utilization":27}}"""))
        }
    }

    @Test fun malformedOrOutOfRangeWindowsAreRejected() {
        listOf(
            "{}", "[]", "not json",
            """{"five_hour":{"utilization":101,"resets_at":null}}""",
            """{"five_hour":{"utilization":-1,"resets_at":null}}""",
            """{"five_hour":{"utilization":"5","resets_at":null}}""",
            """{"five_hour":{"utilization":5,"resets_at":"tomorrow"}}""",
        ).forEach { assertThrows(it, UsageError.UnsupportedSchema::class.java) { ClaudeUsageParser.parse(bytes(it)) } }
    }

    // endregion

    // region Credentials and cookies

    private fun cookie(
        name: String = "sessionKey", value: String = "sk-ant-fixture", domain: String = ".claude.ai",
        path: String = "/", secure: Boolean = true, expires: Instant? = null,
    ) = WebCookie(name, value, domain, path, secure, expires)

    @Test fun captureSharesOnlySecureUnambiguousFirstPartySessionCookie() {
        val valid = cookie()
        val captured = ClaudeWebCredentials.capture(listOf(cookie("tracking", "not-shared"), valid), organizationID)
        assertEquals("sk-ant-fixture", captured.sessionKey)
        listOf(
            listOf(cookie(domain = "evilclaude.ai")),
            listOf(cookie(domain = "claude.ai.example.test")),
            listOf(cookie(domain = "other.claude.ai")),
            listOf(cookie(secure = false)),
            listOf(cookie(path = "/other")),
            listOf(cookie(expires = Instant.ofEpochSecond(1))),
            listOf(cookie(value = "sk-ant-fixture; injected=1")),
            listOf(valid, cookie(value = "sk-ant-other")),
        ).forEach { cookies ->
            assertThrows(ClaudeQuotaError.SignIn::class.java) { ClaudeWebCredentials.capture(cookies, organizationID) }
        }
        assertThrows(ClaudeQuotaError.SignIn::class.java) { ClaudeWebCredentials.capture(listOf(valid), "../other") }
    }

    @Test fun vaultReplaceIsCompareAndSwap() {
        val vault = ClaudeCredentialVault(InMemorySecretStore())
        val first = credentials()
        vault.save(first)
        val second = first.copy(sessionKey = "sk-ant-second")
        vault.replace(second, first)
        assertEquals(second, vault.load())
        // A response that lost a race with sign-out must not resurrect the old session.
        vault.delete()
        assertThrows(kotlinx.coroutines.CancellationException::class.java) { vault.replace(first.copy(sessionKey = "sk-ant-late"), first) }
        assertNull(vault.load())
    }

    // endregion

    // region Native client

    @Test fun nativeQuotaUsesOnlySuppliedSessionAndPreservesIndependentWindows() = runTest {
        val transport = FakeTransport { response(200, body, url = url) }
        val result = ClaudeQuotaClient(transport) { NOW }.fetch(credentials())
        val request = transport.requests.single()
        assertEquals(url, request.url)
        assertEquals("GET", request.method)
        assertEquals("sessionKey=sk-ant-fixture", request.headers["Cookie"])
        assertNull(request.headers["Authorization"])
        assertEquals("Pulso/1.0", request.headers["User-Agent"])
        assertEquals(credentials(), result.credentials)
        assertEquals(NOW, result.snapshot.updatedAt)
        assertEquals(listOf(27.0, 42.0), result.snapshot.windows.map { it.used })
        assertNull(result.snapshot.windows[0].resetsAt)
    }

    @Test fun successfulResponseRenewsOnlyValidatedSessionCookie() = runTest {
        val transport = FakeTransport {
            response(200, body, url = url, multi = mapOf("Set-Cookie" to listOf("sessionKey=sk-ant-renewed; Path=/; Secure; HttpOnly; SameSite=Lax")))
        }
        val result = ClaudeQuotaClient(transport) { NOW }.fetch(credentials())
        assertEquals("sk-ant-renewed", result.credentials.sessionKey)
        assertEquals(organizationID, result.credentials.organizationID)
    }

    @Test fun challengeAuthenticationRateLimitAndHtmlNeverBecomeQuotaReadings() = runTest {
        for ((status, type, text, expected) in listOf(
            listOf(401, "application/json", "{}", ClaudeQuotaError.SignIn),
            listOf(403, "application/json", "{}", ClaudeQuotaError.SignIn),
            listOf(403, "text/html", "<html>Challenge</html>", ClaudeQuotaError.Cloudflare),
            listOf(429, "application/json", "{}", ClaudeQuotaError.Http(429)),
            listOf(302, "text/html", "", ClaudeQuotaError.Http(302)),
            listOf(200, "text/html", "<html>Login</html>", ClaudeQuotaError.InvalidResponse),
        )) {
            val transport = FakeTransport { response(status as Int, text as String, mapOf("Content-Type" to type as String), url) }
            val error = runCatching { ClaudeQuotaClient(transport) { NOW }.fetch(credentials()) }.exceptionOrNull()
            assertEquals("HTTP $status must not produce a quota", expected, error)
        }
    }

    @Test fun redirectedResponseIsNotTrusted() = runTest {
        val transport = FakeTransport { response(200, body, url = "https://example.test/usage") }
        val error = runCatching { ClaudeQuotaClient(transport) { NOW }.fetch(credentials()) }.exceptionOrNull()
        assertEquals(ClaudeQuotaError.InvalidResponse, error)
    }

    @Test fun expiredSessionDoesNotSendNetworkRequest() = runTest {
        val transport = FakeTransport { error("Expired credentials must stay local") }
        val expired = ClaudeWebCredentials("sk-ant-fixture", organizationID, Instant.EPOCH)
        val error = runCatching { ClaudeQuotaClient(transport) { NOW }.fetch(expired) }.exceptionOrNull()
        assertEquals(ClaudeQuotaError.SignIn, error)
        assertTrue(transport.requests.isEmpty())
    }

    // endregion
}
