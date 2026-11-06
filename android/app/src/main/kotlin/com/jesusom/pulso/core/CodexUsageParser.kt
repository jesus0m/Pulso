package com.jesusom.pulso.core

import java.time.Instant

/** Experimental ChatGPT same-origin schema; this is not a public OpenAI API. */
object CodexUsageParser {
    fun parse(data: ByteArray, now: Instant = Instant.now()): UsageSnapshot {
        val windows = mutableListOf<UsageWindow>()
        try {
            val rate = parseObject(data).strictObject("rate_limit") ?: throw UsageError.UnsupportedSchema
            for ((id, name) in listOf("primary" to "primary_window", "secondary" to "secondary_window")) {
                val raw = rate.strictObject(name) ?: continue
                val used = raw.requiredDouble("used_percent")
                val reset = raw.requiredDouble("reset_at")
                val seconds = raw.requiredInt("limit_window_seconds")
                if (!used.isFinite() || used !in 0.0..100.0 || !reset.isFinite() || reset <= 0 || seconds <= 0) {
                    throw UsageError.UnsupportedSchema
                }
                val duration = when {
                    seconds % 86_400 == 0 -> "${seconds / 86_400} d"
                    seconds % 3_600 == 0 -> "${seconds / 3_600} h"
                    else -> "$seconds s"
                }
                // Matches Claude's "Sesión"/"Semana" labelling so both providers read the same way.
                val title = if (id == "primary") "Sesión · $duration" else "Semana · $duration"
                windows += UsageWindow(id, title, used, 100.0, epochToInstant(reset))
            }
        } catch (e: SchemaException) {
            throw UsageError.UnsupportedSchema
        }
        if (windows.isEmpty()) throw UsageError.UnsupportedSchema
        return UsageSnapshot(Provider.CODEX, windows, now, "ChatGPT · sesión web experimental")
    }
}
