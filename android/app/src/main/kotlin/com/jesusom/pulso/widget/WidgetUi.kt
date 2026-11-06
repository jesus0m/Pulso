package com.jesusom.pulso.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.layout.Alignment
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.jesusom.pulso.MainActivity
import com.jesusom.pulso.PulsoApplication
import com.jesusom.pulso.R
import com.jesusom.pulso.core.Provider
import kotlinx.coroutines.CancellationException

internal val WidgetBackground = Color(0.035f, 0.045f, 0.05f)
internal val Secondary = Color(0.62f, 0.64f, 0.66f)
internal val Warning = Color(1f, 0.62f, 0.04f)

internal fun cp(color: Color) = ColorProvider(color)

internal fun style(size: Float, color: Color, bold: Boolean = false) =
    TextStyle(color = cp(color), fontSize = size.sp, fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal)

/** Opening Pulso is the only navigation a widget offers, as with pulso://dashboard on iOS. */
internal fun openApp(context: Context) = GlanceModifier.clickable(actionStartActivity(android.content.Intent(context, MainActivity::class.java)))

internal fun logoRes(provider: Provider) = when (provider) {
    Provider.CODEX -> R.drawable.ic_codex
    Provider.COPILOT -> R.drawable.logo_copilot
    Provider.CLAUDE -> R.drawable.logo_claude
}

@Composable
internal fun ProviderLogoImage(provider: Provider, accent: Color, size: Int = 14) {
    Image(
        ImageProvider(logoRes(provider)), contentDescription = null,
        modifier = GlanceModifier.size(size.dp), colorFilter = ColorFilter.tint(cp(accent)),
    )
}

/** Refresh control: requests a new reading without opening the app. */
@Composable
internal fun RefreshButton(target: String, accent: Color, title: String? = null) {
    val label = LocalRefreshLabel(target)
    Row(
        modifier = GlanceModifier.clickable(
            actionRunCallback<RefreshQuotaAction>(actionParametersOf(RefreshQuotaAction.TARGET to target))
        ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Image(
            ImageProvider(R.drawable.ic_refresh), contentDescription = label,
            modifier = GlanceModifier.size(16.dp), colorFilter = ColorFilter.tint(cp(accent)),
        )
        if (title != null) {
            Spacer(GlanceModifier.width(3.dp))
            Text(title, style = style(10f, accent))
        }
    }
}

@Composable
private fun LocalRefreshLabel(target: String): String {
    val context = androidx.glance.LocalContext.current
    val provider = Provider.from(target)
    return if (provider == null) context.getString(R.string.s_actualizar_cuotas)
    else context.getString(R.string.s_actualizar_cuota_de, provider.title)
}

class RefreshQuotaAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: androidx.glance.GlanceId, parameters: ActionParameters) {
        val services = (context.applicationContext as PulsoApplication).services
        val target = parameters[TARGET]
        val providers = Provider.from(target)?.let { setOf(it) } ?: Provider.entries.toSet()
        try {
            services.widgetRefresh.refresh(providers, userInitiated = true)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        PulsoWidgets.updateNow(context)
    }

    companion object {
        val TARGET = ActionParameters.Key<String>("target")
    }
}

