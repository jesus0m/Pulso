package com.jesusom.pulso.core

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.jesusom.pulso.PulsoApplication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.util.concurrent.TimeUnit

/**
 * Android decides whether and when this runs (Doze, battery saver, standby buckets). Every attempt is
 * recorded so "never woken" stays distinguishable from "woken but the provider failed".
 */
object BackgroundRefresh {
    const val WORK_NAME = "pulso.refresh"
    /** WorkManager's platform minimum for periodic work. */
    const val INTERVAL_MINUTES = 15L

    class Report(
        val lastRun: Instant?, val outcome: String?, val count: Int,
        val lastRequest: Instant?, val requestedAfter: Instant?, val schedulingError: String?,
    )

    fun report(prefs: PulsoPrefs) = Report(
        prefs.long("backgroundLastRun")?.let(Instant::ofEpochMilli), prefs.string("backgroundLastOutcome"),
        prefs.int("backgroundRunCount"), prefs.long("backgroundLastRequest")?.let(Instant::ofEpochMilli),
        prefs.long("backgroundRequestedAfter")?.let(Instant::ofEpochMilli), prefs.string("backgroundSchedulingError"),
    )

    /** A provider counts as refreshed only if its reading is newer than this run. */
    fun summary(result: UsageStore.RefreshResult): String {
        val providers = Provider.entries.filter { it in result.attempted }
        if (providers.isEmpty()) return "Sin proveedores conectados"
        return providers.joinToString(" · ") { "${it.title} ${if (it in result.refreshed) "✓" else "✗"}" }
    }

    fun schedule(context: Context, prefs: PulsoPrefs, now: Instant = Instant.now()) {
        prefs.put("backgroundLastRequest", now.toEpochMilli())
        prefs.put("backgroundRequestedAfter", now.plusSeconds(INTERVAL_MINUTES * 60).toEpochMilli())
        try {
            val request = PeriodicWorkRequestBuilder<RefreshWorker>(INTERVAL_MINUTES, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
            prefs.remove("backgroundSchedulingError")
        } catch (e: Exception) {
            prefs.put("backgroundSchedulingError", e.javaClass.simpleName)
        }
    }
}

class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val services = (applicationContext as PulsoApplication).services
        val prefs = services.prefs
        prefs.put("backgroundLastRun", System.currentTimeMillis())
        prefs.put("backgroundLastOutcome", "En curso")
        prefs.put("backgroundRunCount", prefs.int("backgroundRunCount") + 1)
        val result = withContext(Dispatchers.Main.immediate) { services.store.refresh() }
        prefs.put("backgroundLastOutcome", BackgroundRefresh.summary(result))
        return if (result.cancelled) Result.retry() else Result.success()
    }
}
