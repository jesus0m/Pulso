package com.jesusom.pulso.core

import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

class ClaudeQuotaClient(
    private val transport: HttpTransport = UrlConnectionTransport,
    private val now: () -> Instant = Instant::now,
) {
    class Reading(val snapshot: UsageSnapshot, val credentials: ClaudeWebCredentials)

    suspend fun fetch(credentials: ClaudeWebCredentials): Reading {
        credentials.validate(now())
        // Same private web endpoint used by Claude's usage page.
        val url = "https://claude.ai/api/organizations/${credentials.organizationID}/usage"
        val response = transport.execute(
            HttpRequest(
                url, headers = mapOf(
                    "Cookie" to "sessionKey=${credentials.sessionKey}",
                    "Accept" to "application/json",
                    "User-Agent" to "Pulso/1.0",
                ), timeoutMs = 8_000,
            )
        )
        if (response.url != url) throw ClaudeQuotaError.InvalidResponse
        val contentType = response.header("content-type")?.lowercase().orEmpty()
        if (response.header("cf-mitigated")?.lowercase() == "challenge" ||
            (response.status == 403 && "text/html" in contentType)
        ) throw ClaudeQuotaError.Cloudflare
        if (response.status == 401 || response.status == 403) throw ClaudeQuotaError.SignIn
        if (response.status != 200) throw ClaudeQuotaError.Http(response.status)
        if ("text/html" in contentType || response.body.size > 256_000) throw ClaudeQuotaError.InvalidResponse
        val snapshot = ClaudeUsageParser.parse(response.body, now())
        var updated = credentials
        val renewed = response.headers["set-cookie"].orEmpty().mapNotNull { parseSetCookie(it) }
            .filter { it.name == "sessionKey" }
        if (renewed.isNotEmpty()) {
            updated = ClaudeWebCredentials.capture(renewed, credentials.organizationID, now())
        }
        return Reading(snapshot, updated)
    }

    companion object {
        /** Minimal Set-Cookie reader for a response from https://claude.ai. */
        fun parseSetCookie(header: String): WebCookie? {
            val parts = header.split(";").map { it.trim() }
            val (name, value) = parts.firstOrNull()?.split("=", limit = 2)?.takeIf { it.size == 2 } ?: return null
            var domain = "claude.ai"
            var path = "/"
            var secure = false
            var expires: Instant? = null
            for (attribute in parts.drop(1)) {
                val pair = attribute.split("=", limit = 2)
                when (pair[0].lowercase()) {
                    "domain" -> pair.getOrNull(1)?.let { domain = it }
                    "path" -> pair.getOrNull(1)?.let { path = it }
                    "secure" -> secure = true
                    "max-age" -> pair.getOrNull(1)?.toLongOrNull()?.let { expires = Instant.now().plusSeconds(it) }
                    "expires" -> pair.getOrNull(1)?.let {
                        expires = try {
                            ZonedDateTime.parse(it, DateTimeFormatter.RFC_1123_DATE_TIME.withLocale(Locale.US)).toInstant()
                        } catch (e: Exception) { expires }
                    }
                }
            }
            return WebCookie(name, value, domain, path, secure, expires)
        }
    }
}
