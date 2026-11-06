package com.jesusom.pulso.core

import android.Manifest
import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.jesusom.pulso.PulsoApplication
import com.jesusom.pulso.R
import java.time.Instant

/**
 * Each reading already carries the exact reset instant, so the alert is scheduled for that moment
 * rather than waiting for a later refresh to notice it passed.
 */
object ResetNotifier {
    private const val PREFIX = "reset."
    private const val SCHEDULED_KEY = "resetAlertIds"
    const val CHANNEL = "reset_alerts"
    const val ACTION = "com.jesusom.pulso.RESET_ALERT"

    data class Pending(val id: String, val title: String, val body: String, val fireAt: Instant)

    /** Only future resets, newest reading wins, and one alert per window. */
    fun pending(context: Context, snapshots: List<UsageSnapshot>, now: Instant): List<Pending> =
        snapshots.flatMap { snapshot ->
            snapshot.windows.mapNotNull { window ->
                val reset = window.resetsAt?.takeIf { it.isAfter(now) } ?: return@mapNotNull null
                Pending(
                    "$PREFIX${snapshot.provider.raw}.${window.id}",
                    context.getString(R.string.s_renovada, snapshot.provider.title),
                    context.getString(R.string.s_vuelve_a_estar_al_100, window.localizedTitle(context)),
                    reset,
                )
            }
        }

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.a_channel_reset), NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    fun hasPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun reschedule(context: Context, prefs: PulsoPrefs, snapshots: List<UsageSnapshot>, enabled: Boolean, now: Instant = Instant.now()) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        for (id in prefs.stringList(SCHEDULED_KEY)) alarms.cancel(intent(context, id, "", ""))
        prefs.putList(SCHEDULED_KEY, emptyList())
        if (!enabled) return
        val items = pending(context, snapshots, now)
        for (item in items) {
            val operation = intent(context, item.id, item.title, item.body)
            val at = item.fireAt.toEpochMilli()
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, operation)
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, operation)
            }
        }
        prefs.putList(SCHEDULED_KEY, items.map { it.id })
    }

    private fun intent(context: Context, id: String, title: String, body: String): PendingIntent =
        PendingIntent.getBroadcast(
            context, id.hashCode(),
            Intent(context, ResetAlertReceiver::class.java).setAction(ACTION)
                .putExtra("id", id).putExtra("title", title).putExtra("body", body),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    @SuppressLint("MissingPermission") // guarded by hasPermission() on the first line
    fun show(context: Context, id: String, title: String, body: String) {
        if (!hasPermission(context)) return
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, com.jesusom.pulso.MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_pulso).setContentTitle(title).setContentText(body)
            .setContentIntent(open).setAutoCancel(true).setPriority(NotificationCompat.PRIORITY_DEFAULT).build()
        runCatching { NotificationManagerCompat.from(context).notify(id.hashCode(), notification) }
    }
}

class ResetAlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ResetNotifier.ACTION -> ResetNotifier.show(
                context, intent.getStringExtra("id").orEmpty(),
                intent.getStringExtra("title").orEmpty(), intent.getStringExtra("body").orEmpty(),
            )
            // Alarms do not survive a reboot or an update: rebuild them from the stored readings.
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> {
                val services = (context.applicationContext as PulsoApplication).services
                ResetNotifier.reschedule(
                    context, services.prefs, services.cache.load(), services.prefs.bool("resetAlerts"),
                )
            }
        }
    }
}
