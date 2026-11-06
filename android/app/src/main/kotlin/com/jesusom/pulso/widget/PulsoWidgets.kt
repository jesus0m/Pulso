package com.jesusom.pulso.widget

import android.content.Context
import androidx.glance.appwidget.updateAll
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.jesusom.pulso.PulsoApplication
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.QuotaTimeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.concurrent.TimeUnit

object PulsoWidgets {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Redraws every Pulso widget from the stored readings and schedules the next presentation change. */
    fun requestUpdate(context: Context) {
        val app = context.applicationContext
        scope.launch { updateNow(app) }
    }

    suspend fun updateNow(context: Context) {
        SummaryWidget().updateAll(context)
        for (provider in Provider.entries) ProviderWidget.of(provider).updateAll(context)
        scheduleNextTransition(context)
    }

    /**
     * A countdown reaching zero or a reading going stale changes what a widget should say without any
     * provider response, so a redraw is scheduled for that moment (the system may defer it slightly).
     */
    fun scheduleNextTransition(context: Context) {
        val services = (context.applicationContext as PulsoApplication).services
        val now = Instant.now()
        val next = services.cache.load().flatMap { QuotaTimeline.transitionDates(it, now) }.minOrNull()
        val work = WorkManager.getInstance(context)
        if (next == null) {
            work.cancelUniqueWork(TRANSITION_WORK)
            return
        }
        val delay = (next.toEpochMilli() - now.toEpochMilli()).coerceAtLeast(1_000)
        work.enqueueUniqueWork(
            TRANSITION_WORK, ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<TransitionWorker>().setInitialDelay(delay, TimeUnit.MILLISECONDS).build(),
        )
    }

    private const val TRANSITION_WORK = "pulso.widget.transition"
}

class TransitionWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        PulsoWidgets.updateNow(applicationContext)
        return Result.success()
    }
}
