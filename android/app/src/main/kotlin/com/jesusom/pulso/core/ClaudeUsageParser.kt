package com.jesusom.pulso.core

import java.time.Instant
import java.time.OffsetDateTime

/** Experimental Claude same-origin schema; this is not Anthropic's public API. */
object ClaudeUsageParser {
    fun parse(data: ByteArray, now: Instant = Instant.now()): UsageSnapshot {
        val windows = mutableListOf<UsageWindow>()
        try {
            val payload = parseObject(data)
            for ((id, title) in listOf(
                "five_hour" to "Sesión · 5 h", "seven_day" to "Semana",
                "seven_day_opus" to "Semana · Opus", "seven_day_sonnet" to "Semana · Sonnet",
            )) {
                val raw = payload.strictObject(id) ?: continue
                val utilization = raw.requiredDouble("utilization")
                // A present null means the renewal is unknown; a missing field is schema drift.
                if (!raw.has("resets_at")) throw SchemaException()
                val resetText = raw.strictString("resets_at")
                if (!utilization.isFinite() || utilization !in 0.0..100.0) throw UsageError.UnsupportedSchema
                val reset = resetText?.let {
                    try { OffsetDateTime.parse(it).toInstant() } catch (e: Exception) { throw UsageError.UnsupportedSchema }
                }
                windows += UsageWindow(id, title, utilization, 100.0, reset)
            }
        } catch (e: SchemaException) {
            throw UsageError.UnsupportedSchema
        }
        if (windows.isEmpty()) throw UsageError.UnsupportedSchema
        return UsageSnapshot(Provider.CLAUDE, windows, now, "Claude · sesión web experimental")
    }
}
