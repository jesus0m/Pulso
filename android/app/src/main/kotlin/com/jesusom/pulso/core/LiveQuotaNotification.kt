package com.jesusom.pulso.core

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.jesusom.pulso.MainActivity
import com.jesusom.pulso.R
import java.time.Instant

/**
 * Android counterpart of the iOS Live Activity: one ongoing, silent notification for the chosen
 * provider. It only changes when Pulso receives a reading, expires after eight hours, and the system
 * or the user may dismiss it; it is then only replaced by an explicit start.
 */
class LiveQuotaNotification(
    private val context: Context,
    private val prefs: PulsoPrefs,
    private val now: () -> Instant = Instant::now,
) {
    var enabled by mutableStateOf(prefs.bool("liveActivityEnabled"))
        private set
    var provider by mutableStateOf(Provider.from(prefs.string("liveActivityProvider")) ?: Provider.CODEX)
        private set
    var startedAt by mutableStateOf(prefs.long("liveActivityStartedAt")?.let(Instant::ofEpochMilli))
        private set
    var message by mutableStateOf<String?>(null)
        private set
    val isRunning get() = startedAt != null

    private val manager get() = NotificationManagerCompat.from(context)

    private fun authorized() = ResetNotifier.hasPermission(context) && manager.areNotificationsEnabled()

    fun changeEnabled(value: Boolean) {
        enabled = value
        prefs.put("liveActivityEnabled", value)
        if (!value) stop()
    }

    fun selectProvider(value: Provider) {
        if (value == provider) return
        stop()
        provider = value
        prefs.put("liveActivityProvider", value.raw)
    }

    fun start(snapshot: UsageSnapshot?, configured: Boolean, demo: Boolean, display: QuotaDisplay,
              refreshFailed: Boolean = false, unavailable: Boolean = false) {
        reconcile(snapshot, configured, demo, display, refreshFailed, unavailable)
        if (!enabled || isRunning) return
        if (!authorized()) {
            message = context.getString(R.string.a_live_not_authorized)
            return
        }
        if (demo) {
            message = context.getString(R.string.s_desactiva_los_datos_de_ejemplo_para_iniciar)
            return
        }
        if (!configured || unavailable || snapshot == null || snapshot.provider != provider || snapshot.windows.isEmpty()) {
            message = context.getString(R.string.s_conecta_este_proveedor_y_consulta_una_cuota)
            return
        }
        val date = now()
        try {
            post(snapshot, display, refreshFailed, date)
            startedAt = date
            prefs.put("liveActivityStartedAt", date.toEpochMilli())
            message = null
        } catch (e: Exception) {
            message = context.getString(R.string.a_live_failed)
        }
    }

    fun reconcile(snapshot: UsageSnapshot?, configured: Boolean, demo: Boolean, display: QuotaDisplay,
                  refreshFailed: Boolean = false, unavailable: Boolean = false) {
        val started = startedAt
        val usable = enabled && configured && !demo && !unavailable && authorized() &&
            snapshot != null && snapshot.provider == provider && snapshot.windows.isNotEmpty()
        if (!usable) {
            val hadSession = started != null
            stop()
            if (hadSession) {
                message = when {
                    !authorized() -> context.getString(R.string.a_live_disabled_by_system)
                    demo -> context.getString(R.string.s_la_demostracion_no_se_comparte_con_actividad)
                    enabled -> context.getString(R.string.s_actividad_finalizada_no_hay_una_cuota_real_d)
                    else -> null
                }
            }
            return
        }
        if (started == null) return
        // A dismissed or expired notification may only be replaced by an explicit Start.
        if (!isActive()) {
            clear()
            message = context.getString(R.string.s_la_actividad_ha_finalizado_pulsa_iniciar_par)
            return
        }
        if (now().epochSecond - started.epochSecond >= MAX_SECONDS) {
            stop()
            message = context.getString(R.string.s_la_sesion_ha_alcanzado_su_duracion_maxima_pu)
            return
        }
        post(snapshot!!, display, refreshFailed, started)
    }

    fun stop() {
        // Failing to withdraw a notification must never take the store down with it.
        runCatching { manager.cancel(ID) }
        clear()
        message = null
    }

    private fun clear() {
        startedAt = null
        prefs.remove("liveActivityStartedAt")
    }

    private fun isActive() = context.getSystemService(NotificationManager::class.java)
        .activeNotifications.any { it.id == ID }

    @SuppressLint("MissingPermission") // callers check authorized() first
    private fun post(snapshot: UsageSnapshot, display: QuotaDisplay, refreshFailed: Boolean, started: Instant) {
        val channel = NotificationChannel(CHANNEL, context.getString(R.string.a_channel_live), NotificationManager.IMPORTANCE_LOW)
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val window = snapshot.windows.first()
        val headline = window.displayedPercent(display)
        val complement = window.complementPercent(display)
        val title = "${snapshot.provider.title} · " + (headline?.let { "$it% ${display.headlineNoun(context)}" }
            ?: context.getString(R.string.s_consumido_cuota_desconocida_2))
        val detail = buildString {
            append(window.localizedTitle(context))
            complement?.let { append(" · $it% ${display.complementNoun(context)}") }
            window.resetsAt?.takeIf { it.isAfter(now()) }?.let {
                append(" · ")
                append(context.getString(R.string.s_renueva, relativeFuture(context, now(), it)))
            }
        }
        val reading = android.text.format.DateFormat.getTimeFormat(context)
            .format(java.util.Date.from(snapshot.updatedAt))
        val open = PendingIntent.getActivity(
            context, 1, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val remainingMillis = MAX_SECONDS * 1000 - (now().toEpochMilli() - started.toEpochMilli())
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_pulso)
            .setContentTitle(title)
            .setContentText(detail)
            .setSubText(
                (if (refreshFailed) context.getString(R.string.s_sin_actualizar_ultima_lectura, reading)
                else context.getString(R.string.s_lectura_2, reading))
            )
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true).setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setTimeoutAfter(remainingMillis.coerceAtLeast(1))
            .setContentIntent(open)
        headline?.let { builder.setProgress(100, it, false) }
        manager.notify(ID, builder.build())
    }

    private companion object {
        const val ID = 4201
        const val CHANNEL = "live_quota"
        const val MAX_SECONDS = 8 * 3600
    }
}
