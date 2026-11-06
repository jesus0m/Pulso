package com.jesusom.pulso

import com.jesusom.pulso.core.CodexAuthError
import com.jesusom.pulso.core.CodexCredentials
import com.jesusom.pulso.core.CodexOAuth
import com.jesusom.pulso.core.CodexOAuthClient
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URLDecoder
import java.time.Instant
import java.util.Base64

class CodexOAuthTests {
    private val redirect = "http://localhost:1455/auth/callback"

    @Test fun pkceChallengeMatchesRfc7636Vector() {
        // RFC 7636 appendix B.
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", CodexOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    }

    @Test fun attemptsAreUnguessableUrlSafeValues() {
        val a = CodexOAuth.makeAttempt()
        val b = CodexOAuth.makeAttempt()
        assertTrue(a.state != b.state && a.verifier != b.verifier)
        assertTrue(a.verifier.length >= 43)
        assertTrue(Regex("^[A-Za-z0-9_-]+$").matches(a.state + a.verifier))
    }

    @Test fun authorizationUrlCarriesPkceStateAndTheCodexRegistration() {
        val attempt = CodexOAuth.Attempt("state-1", "verifier-1")
        val url = CodexOAuth.authorizationUrl(redirect, attempt)
        val query = url.substringAfter("?").split("&").associate {
            val (k, v) = it.split("=", limit = 2); k to URLDecoder.decode(v, "UTF-8")
        }
        assertTrue(url.startsWith("https://auth.openai.com/oauth/authorize?"))
        assertEquals(CodexOAuth.CLIENT_ID, query["client_id"])
        assertEquals(redirect, query["redirect_uri"])
        assertEquals("code", query["response_type"])
        assertEquals("S256", query["code_challenge_method"])
        assertEquals(CodexOAuth.challenge("verifier-1"), query["code_challenge"])
        assertEquals("state-1", query["state"])
        assertEquals("openid profile email offline_access", query["scope"])
    }

    @Test fun callbackMustMatchRedirectStateAndCarryExactlyOneCode() {
        assertEquals("abc", CodexOAuth.authorizationCode("$redirect?code=abc&state=s", redirect, "s"))
        listOf(
            "$redirect?code=abc&state=other", "$redirect?code=abc", "$redirect?state=s",
            "$redirect?code=a&code=b&state=s", "$redirect?code=&state=s", "$redirect?code=a&state=s&state=s",
            "http://localhost:1455/other?code=abc&state=s", "http://localhost:1457/auth/callback?code=abc&state=s",
            "https://localhost:1455/auth/callback?code=abc&state=s", "http://evil.test:1455/auth/callback?code=abc&state=s",
        ).forEach { assertThrows(it, CodexAuthError.Callback::class.java) { CodexOAuth.authorizationCode(it, redirect, "s") } }
        assertThrows(CodexAuthError.Denied::class.java) { CodexOAuth.authorizationCode("$redirect?error=access_denied&state=s", redirect, "s") }
    }

    private fun jwt(payload: String) = "h." + Base64.getUrlEncoder().withoutPadding().encodeToString(payload.toByteArray()) + ".s"

    @Test fun exchangeSendsFormBodyAndReadsIdentityHintsFromClaims() = runTest {
        val id = jwt("""{"email":"dev@example.test","https://api.openai.com/auth":{"chatgpt_account_id":"acct_1"}}""")
        val transport = FakeTransport { response(200, """{"access_token":"${jwt("{}")}","refresh_token":"r1","id_token":"$id","expires_in":3600}""") }
        val credentials = CodexOAuthClient(transport) { Instant.ofEpochSecond(1000) }.exchange("code 1", redirect, "ver")
        val request = transport.requests.single()
        assertEquals("POST", request.method)
        assertEquals("application/x-www-form-urlencoded", request.headers["Content-Type"])
        val body = String(request.body!!)
        assertTrue(body, body.contains("grant_type=authorization_code") && body.contains("code=code%201") &&
            body.contains("code_verifier=ver") && body.contains("client_id=${CodexOAuth.CLIENT_ID}"))
        assertEquals("r1", credentials.refreshToken)
        assertEquals("acct_1", credentials.accountID)
        assertEquals("dev@example.test", credentials.email)
        assertEquals(Instant.ofEpochSecond(4600), credentials.expiresAt)
    }

    @Test fun refreshKeepsPreviousIdentityWhenTheReplyOmitsIt() = runTest {
        val previous = CodexCredentials("old", "r1", "id", "acct_1", "dev@example.test", Instant.ofEpochSecond(0))
        val transport = FakeTransport { response(200, """{"access_token":"new-access"}""") }
        val renewed = CodexOAuthClient(transport) { Instant.ofEpochSecond(10) }.refresh(previous)
        assertEquals("new-access", renewed.accessToken)
        assertEquals("r1", renewed.refreshToken)
        assertEquals("acct_1", renewed.accountID)
        assertEquals("dev@example.test", renewed.email)
        assertNull(renewed.expiresAt)
    }

    @Test fun refreshWithoutRefreshTokenRequiresSignIn() = runTest {
        val error = runCatching { CodexOAuthClient(FakeTransport { error("no network") }).refresh(CodexCredentials("a", null, null, null, null, null)) }.exceptionOrNull()
        assertEquals(CodexAuthError.SignIn, error)
    }

    @Test fun usageRequestIsAuthenticatedAndFailuresAreMapped() = runTest {
        val usage = """{"rate_limit":{"primary_window":{"used_percent":27,"reset_at":1793768400,"limit_window_seconds":18000}}}"""
        val transport = FakeTransport { response(200, usage) }
        val snapshot = CodexOAuthClient(transport) { Instant.ofEpochSecond(5) }
            .fetchUsage(CodexCredentials("tok", null, null, "acct_9", null, null))
        val request = transport.requests.single()
        assertEquals("Bearer tok", request.headers["Authorization"])
        assertEquals("acct_9", request.headers["ChatGPT-Account-Id"])
        assertEquals("Codex · OAuth experimental · API no pública", snapshot.source)
        for ((status, expected) in listOf(401 to CodexAuthError.SignIn, 403 to CodexAuthError.Forbidden, 500 to CodexAuthError.Http(500))) {
            val error = runCatching {
                CodexOAuthClient(FakeTransport { response(status) }).fetchUsage(CodexCredentials("t", null, null, null, null, null))
            }.exceptionOrNull()
            assertEquals(expected, error)
        }
    }

    @Test fun malformedTokenReplyIsAnInvalidResponse() = runTest {
        for (body in listOf("{}", """{"access_token":""}""", """{"access_token":5}""", "nope")) {
            val error = runCatching { CodexOAuthClient(FakeTransport { response(200, body) }).exchange("c", redirect, "v") }.exceptionOrNull()
            assertEquals(body, CodexAuthError.InvalidResponse, error)
        }
    }
}
