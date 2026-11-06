package com.jesusom.pulso.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.Text
import com.jesusom.pulso.PulsoApplication
import com.jesusom.pulso.R
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.ProviderStyle
import com.jesusom.pulso.core.UsageSnapshot
import com.jesusom.pulso.core.UsageWindow
import com.jesusom.pulso.core.countdownText
import com.jesusom.pulso.core.creditAmount
import com.jesusom.pulso.core.dateAndTime
import com.jesusom.pulso.core.plainAmount
import com.jesusom.pulso.core.shortTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.Instant

/** One widget per provider; all three share this layout. */
open class ProviderWidget(private val provider: Provider) : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(
        setOf(DpSize(110.dp, 110.dp), DpSize(250.dp, 110.dp), DpSize(250.dp, 250.dp))
    )

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val services = (context.applicationContext as PulsoApplication).services
        val snapshot = services.cache.load().firstOrNull { it.provider == provider }
        val display = services.cache.quotaDisplay
        provideContent { Content(snapshot, display, Instant.now()) }
    }

    @Composable
    private fun Content(snapshot: UsageSnapshot?, display: com.jesusom.pulso.core.QuotaDisplay, now: Instant) {
        val context = LocalContext.current
        val size = LocalSize.current
        val accent = ProviderStyle.widgetAccent(provider)
        val window = snapshot?.windows?.firstOrNull()
        val renewalPending = snapshot?.windows?.any { it.resetsAt?.let { r -> r <= now } ?: false } ?: false
        val stale = snapshot == null || renewalPending || now.epochSecond - snapshot.updatedAt.epochSecond > 300

        val amount = when {
            window == null || renewalPending -> "—"
            else -> window.displayedPercent(display)?.let { "$it%" }
                ?: window.used.takeIf { it.isFinite() && it >= 0 }?.let { plainAmount(it, 2) } ?: "—"
        }
        val detail = when {
            window == null -> context.getString(R.string.s_abre_pulso_para_consultar)
            renewalPending -> context.getString(R.string.s_renovacion_pendiente)
            else -> window.complementPercent(display)?.let {
                context.getString(R.string.s_s, display.headlineNoun(context), it, display.complementNoun(context))
            } ?: context.getString(R.string.s_consumidos_2, window.localizedTitle(context))
        }
        val wide = size.width >= 200.dp
        val tall = size.height >= 200.dp

        Box(
            modifier = openApp(context).fillMaxSize().background(cp(WidgetBackground)).cornerRadius(22.dp).padding(12.dp)
        ) {
            if (!wide) Primary(snapshot, window, amount, detail, accent, stale, renewalPending, now)
            else if (!tall) Row(modifier = GlanceModifier.fillMaxSize()) {
                Box(GlanceModifier.defaultWeight()) { Primary(snapshot, window, amount, detail, accent, stale, renewalPending, now) }
                Spacer(GlanceModifier.width(12.dp))
                Box(GlanceModifier.defaultWeight()) { Details(snapshot, window, display, accent, now, limit = 1) }
            } else Column(modifier = GlanceModifier.fillMaxSize()) {
                Box(GlanceModifier.fillMaxWidth().height(150.dp)) { Primary(snapshot, window, amount, detail, accent, stale, renewalPending, now) }
                Spacer(GlanceModifier.height(10.dp))
                Details(snapshot, window, display, accent, now, limit = 5)
            }
        }
    }

    @Composable
    private fun Primary(
        snapshot: UsageSnapshot?, window: UsageWindow?, amount: String, detail: String, accent: Color,
        stale: Boolean, renewalPending: Boolean, now: Instant,
    ) {
        val context = LocalContext.current
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                ProviderLogoImage(provider, accent)
                Spacer(GlanceModifier.width(4.dp))
                Text(provider.title.uppercase(), style = style(11f, accent, bold = true), maxLines = 1,
                    modifier = GlanceModifier.defaultWeight())
                RefreshButton(provider.raw, accent)
            }
            Spacer(GlanceModifier.defaultWeight())
            Text(amount, style = style(36f, Color.White, bold = true), maxLines = 1)
            Text(detail, style = style(11f, Secondary), maxLines = 2)
            val reset = window?.resetsAt
            if (reset != null) {
                if (reset > now && !renewalPending) {
                    Text(
                        context.getString(R.string.s_renueva_en) + " " + countdownText(now, reset),
                        style = style(10f, accent), maxLines = 1,
                    )
                }
                Text(
                    (if (renewalPending) context.getString(R.string.s_renovacion_prevista) else context.getString(R.string.s_renovacion_2)) +
                        ": " + dateAndTime(context, reset),
                    style = style(9f, Secondary), maxLines = 1,
                )
            }
            Spacer(GlanceModifier.defaultWeight())
            if (snapshot != null) {
                Text(
                    (if (stale) context.getString(R.string.s_sin_actualizar) else context.getString(R.string.s_actualizado)) +
                        " " + shortTime(context, snapshot.updatedAt),
                    style = style(10f, if (stale) Warning else Secondary), maxLines = 1,
                )
            } else {
                Text(context.getString(R.string.s_sin_datos), style = style(11f, Secondary))
            }
        }
    }

    @Composable
    private fun Details(
        snapshot: UsageSnapshot?, window: UsageWindow?, display: com.jesusom.pulso.core.QuotaDisplay,
        accent: Color, now: Instant, limit: Int,
    ) {
        val context = LocalContext.current
        Column(modifier = GlanceModifier.fillMaxSize()) {
            if (window != null && window.id == "copilot_credits") {
                Text(context.getString(R.string.s_creditos_del_mes_2), style = style(10f, accent, bold = true))
                Text(context.getString(R.string.s_consumidos_3, creditAmount(window.used)), style = style(11f, Color.White))
                window.limit?.let { Text(context.getString(R.string.s_de_limite, creditAmount(it)), style = style(11f, Color.White)) }
                window.remaining?.let { Text(context.getString(R.string.s_restantes, creditAmount(it)), style = style(11f, Color.White)) }
                window.reportedRemainingPercent?.let {
                    Text(context.getString(R.string.s_disponible_3, plainAmount(it, 1)), style = style(10f, accent))
                }
                Spacer(GlanceModifier.height(6.dp))
            }
            for (extra in snapshot?.windows.orEmpty().drop(1).take(limit)) {
                Column(modifier = GlanceModifier.padding(bottom = 6.dp)) {
                    Text(extra.localizedTitle(context), style = style(11f, Color.White, bold = true), maxLines = 1)
                    if (extra.resetsAt?.let { it <= now } == true) {
                        Text(context.getString(R.string.s_renovacion_pendiente), style = style(10f, Warning))
                    } else {
                        Text(
                            extra.displayedPercent(display)?.let { "$it% ${display.headlineNoun(context)}" }
                                ?: context.getString(R.string.s_cuota_desconocida),
                            style = style(14f, accent, bold = true), maxLines = 1,
                        )
                        extra.complementPercent(display)?.let {
                            Text("$it% ${display.complementNoun(context)}", style = style(10f, Secondary))
                        }
                        extra.resetsAt?.let { Text(countdownText(now, it), style = style(10f, Secondary)) }
                    }
                }
            }
            if (snapshot == null) {
                Text(context.getString(R.string.s_conecta_tu_cuenta_y_consulta_la_cuota_en_pul), style = style(11f, Secondary))
            } else if (snapshot.windows.size == 1 && window?.id != "copilot_credits") {
                Text(window?.localizedTitle(context) ?: context.getString(R.string.s_ultima_lectura), style = style(11f, Secondary))
            }
        }
    }

    companion object {
        fun of(provider: Provider): ProviderWidget = when (provider) {
            Provider.CODEX -> CodexWidget()
            Provider.COPILOT -> CopilotWidget()
            Provider.CLAUDE -> ClaudeWidget()
        }
    }
}

class CodexWidget : ProviderWidget(Provider.CODEX)
class CopilotWidget : ProviderWidget(Provider.COPILOT)
class ClaudeWidget : ProviderWidget(Provider.CLAUDE)

/** Refreshes from the providers when the system asks for an update, then redraws. */
abstract class PulsoWidgetReceiver : GlanceAppWidgetReceiver() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        // goAsync() is null when Glance already handles this broadcast asynchronously.
        val pending = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                (context.applicationContext as PulsoApplication).services.widgetRefresh.refresh()
                PulsoWidgets.updateNow(context)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                // A failed refresh keeps the stored reading; the widget is redrawn from the cache.
            } finally {
                pending?.finish()
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) = super.onReceive(context, intent)
}

class CodexWidgetReceiver : PulsoWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = CodexWidget() }
class CopilotWidgetReceiver : PulsoWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = CopilotWidget() }
class ClaudeWidgetReceiver : PulsoWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = ClaudeWidget() }
class SummaryWidgetReceiver : PulsoWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = SummaryWidget() }

