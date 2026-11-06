package com.jesusom.pulso.core

import android.content.Context
import com.jesusom.pulso.R
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset

/**
 * Experimental per-account endpoint, separate from GitHub's public billing reports.
 * Its private schema may change or omit quotas for organization-managed seats.
 */
class CopilotQuotaClient(
    private val transport: HttpTransport = UrlConnectionTransport,
    private val clock: () -> Instant = Instant::now,
) {
    suspend fun fetch(token: String, allowance: Double? = null): UsageSnapshot {
        val secret = token.trim()
        if (secret.isEmpty() || secret.any { it.isWhitespace() }) throw UsageError.InvalidCredentials
        val response = transport.execute(
            HttpRequest(
                "https://api.github.com/copilot_internal/user", headers = mapOf(
                    "Authorization" to "token $secret",
                    "Accept" to "application/json",
                    "User-Agent" to "PULSO/1.0",
                    "X-GitHub-Api-Version" to "2026-03-10",
                ), timeoutMs = 20_000,
            )
        )
        return when (response.status) {
            200 -> parse(response.body, allowance, clock())
            401, 403 -> throw CopilotQuotaError.AccessDenied(response.status)
            404 -> throw CopilotQuotaError.Unavailable
            else -> throw CopilotQuotaError.Http(response.status)
        }
    }

    private class Quota(
        val entitlement: Double?, val invalidEntitlement: Boolean, val percentRemaining: Double?,
        val remaining: Double?, val unlimited: Boolean?, val overageCount: Double?, val creditsUsed: Double?,
    )

    companion object {
        private fun quota(o: JSONObject?): Quota? {
            o ?: return null
            // Invalid entitlements may fall back to a manual limit only in the AI Credits branch.
            val rawEntitlement = if (o.has("entitlement") && !o.isNull("entitlement")) o.get("entitlement") else null
            val entitlement = (rawEntitlement as? Number)?.toDouble()
            val invalid = entitlement == null && rawEntitlement != null
            return Quota(
                entitlement, invalid, o.strictDouble("percent_remaining"), o.strictDouble("remaining"),
                o.strictBoolean("unlimited"), o.strictDouble("overage_count"), o.strictDouble("credits_used"),
            )
        }

        fun parse(data: ByteArray, allowance: Double? = null, now: Instant = Instant.now()): UsageSnapshot {
            try {
                return parseInternal(data, allowance, now)
            } catch (e: SchemaException) {
                throw CopilotQuotaError.UnsupportedSchema
            }
        }

        private fun parseInternal(data: ByteArray, allowance: Double?, now: Instant): UsageSnapshot {
            val payload = parseObject(data)
            val plan = payload.strictString("copilot_plan")?.trim()
            val tokenBased = payload.strictBoolean("token_based_billing")
            val resetText = payload.strictString("quota_reset_date")
            val snapshots = payload.strictObject("quota_snapshots")
            val premium = quota(snapshots?.strictObject("premium_interactions"))
            val chat = quota(snapshots?.strictObject("chat"))
            val planSuffix = if (plan.isNullOrEmpty()) "" else " · plan $plan"

            if (tokenBased == true) {
                // Keep the balance and allowance from the same quota; never add duplicate chat credits.
                val quota = if (premium?.creditsUsed != null) premium else chat
                val credits = quota?.creditsUsed ?: throw CopilotQuotaError.NoPublishedQuota
                if (!credits.isFinite() || credits < 0) throw CopilotQuotaError.UnsupportedSchema
                quota.remaining?.let { if (!it.isFinite() || it < 0) throw CopilotQuotaError.UnsupportedSchema }
                quota.percentRemaining?.let { if (!it.isFinite() || it !in 0.0..100.0) throw CopilotQuotaError.UnsupportedSchema }
                val limit = listOf(quota.entitlement, allowance).firstOrNull { it != null && it.isFinite() && it > 0 }
                val reset = resetText?.let(::parseResetDate)
                return UsageSnapshot(
                    Provider.COPILOT,
                    listOf(
                        UsageWindow(
                            "copilot_credits", "Créditos usados · cuenta", credits, limit, reset,
                            quota.remaining, quota.percentRemaining,
                        )
                    ),
                    now, "Copilot · créditos comunicados · cuenta experimental$planSuffix",
                )
            }
            val reset: Instant? = resetText?.let { parseResetDate(it) ?: throw CopilotQuotaError.UnsupportedSchema }
            val windows = mutableListOf<UsageWindow>()
            for ((id, title, quota) in listOf(
                Triple("copilot_premium", "Premium · cuenta", premium),
                Triple("copilot_chat", "Chat · cuenta", chat),
            )) {
                quota ?: continue
                if (quota.invalidEntitlement) throw CopilotQuotaError.UnsupportedSchema
                if (quota.unlimited == true) continue
                val entitlement = quota.entitlement
                val remaining = quota.percentRemaining
                if (entitlement == null || !entitlement.isFinite() || entitlement <= 0 || remaining == null) continue
                if (!remaining.isFinite() || remaining !in 0.0..100.0) throw CopilotQuotaError.UnsupportedSchema
                var used = entitlement * (1 - remaining / 100)
                quota.overageCount?.let { overage ->
                    if (!overage.isFinite() || overage < 0) throw CopilotQuotaError.UnsupportedSchema
                    // Overage is additional to the included quota. Only combine when the
                    // published percentage agrees the included quota is exhausted.
                    if (remaining == 0.0) used += overage
                }
                if (!used.isFinite()) throw CopilotQuotaError.UnsupportedSchema
                windows += UsageWindow(id, title, used, entitlement, reset)
            }
            if (windows.isEmpty()) throw CopilotQuotaError.NoPublishedQuota
            return UsageSnapshot(Provider.COPILOT, windows, now, "Copilot · cuota de cuenta experimental$planSuffix")
        }

        private val DATE_ONLY = Regex("""^\d{4}-\d{2}-\d{2}$""")

        private fun parseResetDate(raw: String): Instant? {
            val text = raw.trim()
            try { return OffsetDateTime.parse(text).toInstant() } catch (_: Exception) {}
            if (!DATE_ONLY.matches(text)) return null
            return try { LocalDate.parse(text).atStartOfDay(ZoneOffset.UTC).toInstant() } catch (_: Exception) { null }
        }
    }
}

sealed class CopilotQuotaError : Exception(), LocalizedError {
    object NoPublishedQuota : CopilotQuotaError()
    object UnsupportedSchema : CopilotQuotaError()
    data class AccessDenied(val status: Int) : CopilotQuotaError()
    object Unavailable : CopilotQuotaError()
    data class Http(val status: Int) : CopilotQuotaError()

    override fun describe(c: Context): String = when (this) {
        NoPublishedQuota -> c.getString(R.string.s_copilot_no_publica_una_cuota_medible_para_es)
        UnsupportedSchema -> c.getString(R.string.s_copilot_devolvio_un_formato_de_cuota_no_comp)
        is AccessDenied -> c.getString(R.string.s_copilot_no_permite_consultar_la_cuota_http_e, status)
        Unavailable -> c.getString(R.string.s_la_cuota_de_cuenta_de_copilot_no_esta_dispon)
        is Http -> c.getString(R.string.s_no_se_pudo_consultar_la_cuota_de_copilot_htt, status)
    }
}
