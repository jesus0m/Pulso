package com.jesusom.pulso.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
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
import com.jesusom.pulso.core.SummaryProviderReading
import com.jesusom.pulso.core.SummaryQuotaValue
import com.jesusom.pulso.core.SummaryWidgetState
import com.jesusom.pulso.core.UsageWindow
import com.jesusom.pulso.core.countdownText
import com.jesusom.pulso.core.creditAmount
import com.jesusom.pulso.core.shortTime
import java.time.Instant

/** Codex, Copilot and Claude in one widget: rows when small, columns when wide, detail when tall. */
class SummaryWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(
        setOf(DpSize(110.dp, 110.dp), DpSize(250.dp, 110.dp), DpSize(250.dp, 200.dp), DpSize(250.dp, 320.dp))
    )

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val services = (context.applicationContext as PulsoApplication).services
        val state = SummaryWidgetState(services.cache.load(), services.cache.quotaDisplay, services.cache.summaryProviders)
        provideContent { Content(state, Instant.now()) }
    }

    @Composable
    private fun Content(state: SummaryWidgetState, now: Instant) {
        val context = LocalContext.current
        val size = LocalSize.current
        val codex = ProviderStyle.widgetAccent(Provider.CODEX)
        Box(modifier = openApp(context).fillMaxSize().background(cp(Color.Black)).cornerRadius(22.dp).padding(12.dp)) {
            Column(modifier = GlanceModifier.fillMaxSize()) {
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("PULSO", style = style(10f, codex, bold = true), modifier = GlanceModifier.defaultWeight())
                    RefreshButton("summary", codex, if (size.width >= 200.dp) context.getString(R.string.s_actualizar) else null)
                }
                Spacer(GlanceModifier.height(6.dp))
                when {
                    state.readings.isEmpty() -> EmptyPanels()
                    size.height < 150.dp -> if (size.width >= 200.dp) Columns(state, now) else CompactRows(state, now)
                    size.height < 280.dp -> Columns(state, now)
                    else -> DetailedRows(state, now)
                }
            }
        }
    }

    /** Every panel is hidden in the app; the accounts and readings are untouched. */
    @Composable
    private fun EmptyPanels() {
        val context = LocalContext.current
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Text(context.getString(R.string.s_sin_paneles_visibles), style = style(12f, Color.White, bold = true))
            Text(context.getString(R.string.s_tus_cuentas_siguen_conectadas_elige_que_pane), style = style(10f, Secondary))
        }
    }

    private fun shortTitle(provider: Provider) = if (provider == Provider.COPILOT) "Copilot" else provider.title

    private fun valueString(context: Context, value: SummaryQuotaValue) = when (value) {
        is SummaryQuotaValue.Percent -> "${value.value}%"
        is SummaryQuotaValue.Amount -> creditAmount(value.value)
        SummaryQuotaValue.Unavailable -> context.getString(R.string.s_sin_datos)
    }

    @Composable
    private fun ReadingDate(reading: SummaryProviderReading, now: Instant, compact: Boolean) {
        val context = LocalContext.current
        val updatedAt = reading.updatedAt
        if (updatedAt == null) {
            Text(context.getString(R.string.s_sin_lectura), style = style(10f, Secondary), maxLines = 1)
            return
        }
        val stale = reading.isStale(now)
        val prefix = when {
            compact -> ""
            stale -> context.getString(R.string.s_sin_actualizar) + " "
            else -> context.getString(R.string.s_lectura) + " "
        }
        Text(prefix + shortTime(context, updatedAt), style = style(10f, if (stale) Warning else Secondary), maxLines = 1)
    }

    @Composable
    private fun CompactRows(state: SummaryWidgetState, now: Instant) {
        val context = LocalContext.current
        Column(modifier = GlanceModifier.fillMaxSize()) {
            for (reading in state.readings) {
                val accent = ProviderStyle.widgetAccent(reading.provider)
                Row(
                    modifier = GlanceModifier.fillMaxWidth().defaultWeight(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ProviderLogoImage(reading.provider, accent, 17)
                    Spacer(GlanceModifier.width(7.dp))
                    Column(modifier = GlanceModifier.defaultWeight()) {
                        Text(shortTitle(reading.provider), style = style(11f, Color.White, bold = true), maxLines = 1)
                        ReadingDate(reading, now, compact = true)
                    }
                    Text(
                        valueString(context, reading.value(reading.windows.firstOrNull(), state.display)),
                        style = style(15f, accent, bold = true), maxLines = 1,
                    )
                }
            }
        }
    }

    @Composable
    private fun ResetLabel(window: UsageWindow, accent: Color, now: Instant, detailed: Boolean) {
        val context = LocalContext.current
        val reset = window.resetsAt
        when {
            reset == null -> Text(context.getString(R.string.s_sin_fecha_de_renovacion), style = style(10f, Secondary), maxLines = 1)
            reset <= now -> Text(context.getString(R.string.s_renovacion_pendiente), style = style(10f, Warning), maxLines = 1)
            else -> {
                Text("↻ " + countdownText(now, reset), style = style(10f, accent), maxLines = 1)
                if (detailed) Text(com.jesusom.pulso.core.dateAndTime(context, reset), style = style(10f, Secondary), maxLines = 1)
            }
        }
    }

    @Composable
    private fun Columns(state: SummaryWidgetState, now: Instant) {
        val context = LocalContext.current
        Row(modifier = GlanceModifier.fillMaxSize()) {
            for (reading in state.readings) {
                val accent = ProviderStyle.widgetAccent(reading.provider)
                val window = reading.windows.firstOrNull()
                Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight().padding(end = 6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ProviderLogoImage(reading.provider, accent)
                        Spacer(GlanceModifier.width(4.dp))
                        Text(shortTitle(reading.provider), style = style(11f, accent, bold = true), maxLines = 1)
                    }
                    Text(valueString(context, reading.value(window, state.display)), style = style(20f, Color.White, bold = true), maxLines = 1)
                    Text(window?.localizedTitle(context) ?: context.getString(R.string.s_sin_lectura), style = style(10f, Secondary), maxLines = 1)
                    if (window != null) ResetLabel(window, accent, now, detailed = false)
                    Spacer(GlanceModifier.defaultWeight())
                    ReadingDate(reading, now, compact = false)
                }
            }
        }
    }

    @Composable
    private fun DetailedRows(state: SummaryWidgetState, now: Instant) {
        val context = LocalContext.current
        Column(modifier = GlanceModifier.fillMaxSize()) {
            for (reading in state.readings) {
                val accent = ProviderStyle.widgetAccent(reading.provider)
                Column(modifier = GlanceModifier.defaultWeight().fillMaxWidth()) {
                    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        ProviderLogoImage(reading.provider, accent, 16)
                        Spacer(GlanceModifier.width(6.dp))
                        Text(reading.provider.title, style = style(13f, accent, bold = true), maxLines = 1, modifier = GlanceModifier.defaultWeight())
                        ReadingDate(reading, now, compact = false)
                    }
                    if (reading.windows.isEmpty()) {
                        Text(context.getString(R.string.s_sin_lectura_abre_pulso_para_consultar), style = style(11f, Secondary))
                    } else {
                        Row(modifier = GlanceModifier.fillMaxWidth()) {
                            for (window in reading.windows.take(2)) {
                                Column(modifier = GlanceModifier.defaultWeight()) {
                                    Text(window.localizedTitle(context), style = style(10f, Secondary), maxLines = 1)
                                    Text(
                                        valueString(context, reading.value(window, state.display)),
                                        style = style(16f, accent, bold = true), maxLines = 1,
                                    )
                                    window.complementPercent(state.display)?.let {
                                        Text("$it% ${state.display.complementNoun(context)}", style = style(10f, Secondary), maxLines = 1)
                                    }
                                    ResetLabel(window, accent, now, detailed = false)
                                }
                            }
                        }
                        reading.windows.firstOrNull { it.id == "copilot_credits" }?.let { credits ->
                            Text(
                                context.getString(
                                    R.string.s_usados_de_limite, amount(credits.used), amount(credits.limit),
                                ), style = style(10f, Secondary), maxLines = 1,
                            )
                            Text(
                                context.getString(R.string.s_restantes, amount(credits.remaining)) +
                                    (credits.reportedRemainingPercent?.takeIf { it in 0.0..100.0 }
                                        ?.let { " · " + context.getString(R.string.s_disponible_3, creditAmount(it)) } ?: ""),
                                style = style(10f, Secondary), maxLines = 1,
                            )
                        }
                    }
                }
                Spacer(GlanceModifier.height(6.dp))
            }
        }
    }

    private fun amount(value: Double?) = value?.takeIf { it.isFinite() && it >= 0 }?.let { creditAmount(it) } ?: "—"
}

