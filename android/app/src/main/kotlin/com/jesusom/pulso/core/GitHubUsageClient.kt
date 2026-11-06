package com.jesusom.pulso.core

import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime

/**
 * User reports cover personally billed plans only, not organization-managed seats.
 * https://docs.github.com/en/rest/billing/usage
 */
class GitHubUsageClient(
    private val transport: HttpTransport = UrlConnectionTransport,
    private val clock: () -> Instant = Instant::now,
) {
    suspend fun fetch(username: String, token: String, allowance: Double?, legacy: Boolean): UsageSnapshot {
        val name = username.trim()
        val secret = token.trim()
        if (name.isEmpty() || name.length > 39 || !USERNAME.matches(name) ||
            secret.isEmpty() || secret.any { it.isWhitespace() }
        ) throw UsageError.InvalidCredentials
        validateAllowance(allowance)
        val now = clock()
        val utc = ZonedDateTime.ofInstant(now, ZoneOffset.UTC)
        val endpoint = if (legacy) "premium_request" else "ai_credit"
        val url = "https://api.github.com/users/$name/settings/billing/$endpoint/usage?year=${utc.year}&month=${utc.monthValue}"
        val response = transport.execute(
            HttpRequest(
                url, headers = mapOf(
                    "Accept" to "application/vnd.github+json",
                    "Authorization" to "Bearer $secret",
                    "X-GitHub-Api-Version" to "2026-03-10",
                ), timeoutMs = 30_000,
            )
        )
        if (response.status != 200) throw UsageError.Http(response.status)
        return parse(response.body, allowance, legacy, now)
    }

    companion object {
        private val USERNAME = Regex("^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")

        fun parse(data: ByteArray, allowance: Double?, legacy: Boolean, now: Instant = Instant.now()): UsageSnapshot {
            validateAllowance(allowance)
            var used = 0.0
            var matchingRows = 0
            try {
                val rows = parseObject(data).requiredArray("usageItems").objects()
                for (row in rows) {
                    val product = row.requiredString("product").lowercase()
                    val unit = row.requiredString("unitType").lowercase()
                    val gross = row.requiredDouble("grossQuantity")
                    if (product != "copilot" && product != "copilot ai credits") continue
                    val validUnit = if (legacy) unit == "requests" else unit == "ai-credits" || unit == "credits"
                    if (!validUnit || !gross.isFinite() || gross < 0) throw UsageError.UnsupportedSchema
                    matchingRows += 1
                    used += gross
                }
            } catch (e: SchemaException) {
                throw UsageError.UnsupportedSchema
            }
            if (matchingRows == 0) throw UsageError.NoUsageData
            if (!used.isFinite()) throw UsageError.UnsupportedSchema
            val utc = ZonedDateTime.ofInstant(now, ZoneOffset.UTC)
            val reset = utc.withDayOfMonth(1).toLocalDate().atStartOfDay(ZoneOffset.UTC).plusMonths(1).toInstant()
            val unitName = if (legacy) "solicitudes premium" else "créditos IA"
            return UsageSnapshot(
                Provider.COPILOT,
                listOf(
                    UsageWindow(
                        if (legacy) "premium_requests" else "ai_credits", "Mes · $unitName", used, allowance, reset,
                    )
                ),
                now,
                "GitHub API · uso bruto · " + if (allowance == null) "límite desconocido" else "límite manual",
            )
        }

        private fun validateAllowance(allowance: Double?) {
            if (allowance != null && (!allowance.isFinite() || allowance <= 0)) throw UsageError.InvalidAllowance
        }
    }
}
