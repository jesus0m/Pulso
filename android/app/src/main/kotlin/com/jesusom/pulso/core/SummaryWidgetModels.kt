package com.jesusom.pulso.core

import java.time.Instant

sealed class SummaryQuotaValue {
    data class Percent(val value: Int) : SummaryQuotaValue()
    data class Amount(val value: Double) : SummaryQuotaValue()
    object Unavailable : SummaryQuotaValue()
}

class SummaryProviderReading(val provider: Provider, val windows: List<UsageWindow>, val updatedAt: Instant?) {
    fun isStale(at: Instant): Boolean {
        if (updatedAt == null || windows.isEmpty()) return true
        return updatedAt.isAfter(at) || at.epochSecond - updatedAt.epochSecond > 300 ||
            windows.any { it.resetsAt?.let { reset -> reset <= at } ?: false }
    }

    fun value(window: UsageWindow?, display: QuotaDisplay): SummaryQuotaValue {
        window ?: return SummaryQuotaValue.Unavailable
        window.displayedPercent(display)?.let { return SummaryQuotaValue.Percent(it) }
        val amount = if (display == QuotaDisplay.USED) window.used else window.remaining
        if (amount == null || !amount.isFinite() || amount < 0) return SummaryQuotaValue.Unavailable
        return SummaryQuotaValue.Amount(amount)
    }
}

class SummaryWidgetState(
    snapshots: List<UsageSnapshot>, val display: QuotaDisplay, providers: List<Provider> = Provider.entries,
) {
    val readings: List<SummaryProviderReading> = providers.map { provider ->
        val snapshot = snapshots.filter { it.provider == provider }.maxByOrNull { it.updatedAt }
        SummaryProviderReading(provider, snapshot?.windows.orEmpty(), snapshot?.updatedAt)
    }

    fun transitionDates(after: Instant): List<Instant> = readings.flatMap { reading ->
        val updatedAt = reading.updatedAt ?: return@flatMap emptyList()
        QuotaTimeline.transitionDates(UsageSnapshot(reading.provider, reading.windows, updatedAt, ""), after)
    }.toSortedSet().toList()
}
