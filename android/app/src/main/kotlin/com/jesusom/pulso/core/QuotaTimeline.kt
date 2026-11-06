package com.jesusom.pulso.core

import java.time.Instant

object QuotaTimeline {
    /** Moments at which a stored reading changes presentation without a new provider response. */
    fun transitionDates(snapshot: UsageSnapshot?, after: Instant): List<Instant> {
        snapshot ?: return emptyList()
        val dates = listOf(snapshot.updatedAt.plusSeconds(301)) + snapshot.windows.mapNotNull { it.resetsAt }
        return dates.filter { it.isAfter(after) }.toSortedSet().toList()
    }
}
