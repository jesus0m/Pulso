package com.jesusom.pulso.core

import android.content.Context
import android.text.format.DateFormat
import android.text.format.DateUtils
import androidx.compose.ui.graphics.Color
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.time.Duration
import java.time.Instant
import java.util.Date
import java.util.Locale

object ProviderStyle {
    fun accent(provider: Provider) = when (provider) {
        Provider.CODEX -> Color(0.55f, 0.94f, 0.77f)
        Provider.COPILOT -> Color(0.77f, 0.70f, 1f)
        Provider.CLAUDE -> Color(0.95f, 0.65f, 0.48f)
    }

    /** Widgets use a marginally lighter Codex tone, as on iOS. */
    fun widgetAccent(provider: Provider) = when (provider) {
        Provider.CODEX -> Color(0.57f, 0.95f, 0.78f)
        Provider.COPILOT -> Color(0.78f, 0.69f, 1f)
        Provider.CLAUDE -> Color(0.95f, 0.65f, 0.48f)
    }

    val nightTone = Color(0.85f, 0.25f, 0.2f)
}

/** Credit counts always group thousands (Spanish omits grouping for four digits by default). */
fun creditAmount(amount: Double, locale: Locale = Locale.getDefault()): String =
    DecimalFormat("#,##0.#", DecimalFormatSymbols(locale)).format(amount)

/** At most one fraction digit, no grouping: used for percentages and plain amounts. */
fun plainAmount(amount: Double, maxFraction: Int, locale: Locale = Locale.getDefault()): String =
    DecimalFormat("0" + if (maxFraction > 0) "." + "#".repeat(maxFraction) else "", DecimalFormatSymbols(locale)).format(amount)

/** Language-neutral countdown: "3 d 4 h", "2 h 14 min", "9 min". */
fun countdownText(now: Instant, reset: Instant): String {
    val total = Duration.between(now, reset).coerceAtLeast(Duration.ZERO)
    val days = total.toDays()
    val hours = total.toHours() % 24
    val minutes = total.toMinutes() % 60
    return when {
        days > 0 -> "$days d $hours h"
        total.toHours() > 0 -> "${total.toHours()} h $minutes min"
        else -> "${maxOf(minutes, if (total.isZero) 0 else 1)} min"
    }
}

/** "in 2 hours" / "dentro de 2 horas", lower-cased so it reads inside "Resets …". */
fun relativeFuture(now: Instant, reset: Instant): CharSequence =
    DateUtils.getRelativeTimeSpanString(reset.toEpochMilli(), now.toEpochMilli(), DateUtils.MINUTE_IN_MILLIS)
        .toString().replaceFirstChar { it.lowercase() }

fun shortTime(context: Context, instant: Instant): String =
    DateFormat.getTimeFormat(context).format(Date.from(instant))

fun dateAndTime(context: Context, instant: Instant): String = DateUtils.formatDateTime(
    context, instant.toEpochMilli(),
    DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_SHOW_TIME,
)

/** Readings older than five minutes, or past a renewal, are shown as not updated. */
fun isStale(snapshot: UsageSnapshot, now: Instant, failed: Boolean = false): Boolean =
    failed || now.epochSecond - snapshot.updatedAt.epochSecond > 300 ||
        snapshot.windows.any { (it.resetsAt ?: Instant.MAX) <= now }
