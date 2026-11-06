package com.jesusom.pulso.ui

import android.view.WindowManager
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Monitor
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.jesusom.pulso.BuildConfig
import com.jesusom.pulso.R
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.ProviderStyle
import com.jesusom.pulso.core.UsageStore
import com.jesusom.pulso.core.UsageWindow
import com.jesusom.pulso.core.creditAmount
import com.jesusom.pulso.core.plainAmount
import com.jesusom.pulso.core.relativeFuture
import com.jesusom.pulso.core.shortTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

@Composable
fun DashboardScreen(store: UsageStore, onOpenConnections: () -> Unit) {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    val landscape = configuration.screenWidthDp > configuration.screenHeightDp && configuration.fontScale < 1.3f
    val tone = if (store.nightMode) ProviderStyle.nightTone else Color.White
    var now by remember { mutableStateOf(Instant.now()) }

    // Refresh once a minute while the app is visible; the system schedules everything else.
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            launch {
                while (true) {
                    now = Instant.now()
                    delay(30_000)
                }
            }
            while (true) {
                store.refresh()
                delay(60_000)
            }
        }
    }

    DeskModeEffect(store.deskMode)

    Column(
        Modifier.fillMaxSize().background(Color.Black).statusBarsPadding(),
    ) {
        Header(store, onOpenConnections) { scope.launch { store.refresh() } }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = if (landscape) 36.dp else 28.dp, vertical = if (landscape) 16.dp else 28.dp),
            verticalArrangement = Arrangement.spacedBy(if (landscape) 16.dp else 32.dp),
        ) {
            if (BuildConfig.DEBUG && store.demo) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Visibility, null, Modifier.size(14.dp), tint = Color.Yellow)
                    Spacer(Modifier.width(6.dp))
                    Text(
                        stringResource(R.string.s_demostracion_datos_de_ejemplo), color = Color.Yellow,
                        fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("demoBanner"),
                    )
                }
            }
            val visible = store.visibleProviders
            if (visible.isEmpty()) {
                EmptyPanels(onOpenConnections)
            } else if (landscape) {
                Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    visible.forEach { provider ->
                        Box(Modifier.weight(1f)) { ProviderPanel(store, provider, now, compact = true, tone, onOpenConnections) }
                    }
                }
            } else {
                visible.forEach { provider ->
                    Column(Modifier.padding(bottom = 24.dp)) {
                        ProviderPanel(store, provider, now, compact = false, tone, onOpenConnections)
                        Spacer(Modifier.height(24.dp))
                        Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.12f)))
                    }
                }
            }
            if (!store.deskMode) Footer(store)
        }
    }
}

/** Desk mode keeps the screen on and hides system bars while Pulso is open. */
@Composable
private fun DeskModeEffect(enabled: Boolean) {
    val activity = LocalActivity.current ?: return
    DisposableEffect(enabled) {
        val window = activity.window
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
        onDispose {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }
}

@Composable
private fun Header(store: UsageStore, onOpenConnections: () -> Unit, onRefresh: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 28.dp, end = 16.dp, top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.MonitorHeart, null, Modifier.size(22.dp), tint = Color.White)
        Spacer(Modifier.width(8.dp))
        Text("PULSO", fontWeight = FontWeight.Bold, fontFamily = FontFamily.SansSerif, letterSpacing = 3.sp, fontSize = 17.sp, color = Color.White)
        Spacer(Modifier.weight(1f))
        val refreshLabel = stringResource(R.string.s_actualizar_cuotas)
        IconButton(
            onClick = onRefresh, enabled = !store.refreshing && !store.demo,
            modifier = Modifier.size(48.dp).semantics { contentDescription = refreshLabel },
        ) {
            if (store.refreshing) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White)
            else Icon(Icons.Default.Refresh, null, tint = Color.White)
        }
        val deskLabel = stringResource(if (store.deskMode) R.string.s_desactivar_modo_escritorio else R.string.s_activar_modo_escritorio)
        IconButton(
            onClick = { store.deskMode = !store.deskMode },
            modifier = Modifier.size(48.dp).testTag("deskModeButton").semantics { contentDescription = deskLabel },
        ) {
            Icon(
                if (store.deskMode) Icons.Default.Monitor else Icons.Default.Download, null,
                tint = if (store.deskMode) Color(0xFF7FFFD4) else SecondaryText,
            )
        }
        val settingsLabel = stringResource(R.string.s_conexiones_y_ajustes)
        IconButton(
            onClick = onOpenConnections,
            modifier = Modifier.size(48.dp).testTag("settingsButton").semantics { contentDescription = settingsLabel },
        ) { Icon(Icons.Default.Tune, null, tint = Color.White) }
    }
}

@Composable
private fun EmptyPanels(onOpenConnections: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Default.Block, null, Modifier.size(40.dp), tint = SecondaryText)
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.s_sin_paneles_visibles), fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Spacer(Modifier.height(6.dp))
        Text(stringResource(R.string.s_tus_cuentas_siguen_conectadas_elige_que_pane), color = SecondaryText, fontSize = 14.sp)
        TextButton(onClick = onOpenConnections) { Text(stringResource(R.string.s_elegir_paneles)) }
    }
}

@Composable
private fun InformationRow(stacked: Boolean, leading: @Composable () -> Unit, trailing: @Composable () -> Unit) {
    if (stacked || LocalConfiguration.current.fontScale >= 1.3f) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { leading(); trailing() }
    } else {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            leading(); trailing()
        }
    }
}

@Composable
private fun ProviderPanel(
    store: UsageStore, provider: Provider, now: Instant, compact: Boolean, tone: Color, onOpenConnections: () -> Unit,
) {
    val context = LocalContext.current
    val snapshot = store.snapshot(provider)
    val window = snapshot?.windows?.firstOrNull()
    val display = store.quotaDisplay
    val isCredit = provider == Provider.COPILOT && window?.id == "copilot_credits"
    val consumed = window?.let { creditAmount(it.used) } ?: "—"
    val approximation = if (store.organizationPlan && !isCredit && window?.limit != null) "≈ " else ""
    val consumedAmount = approximation + consumed
    val copilotDetail = if (!isCredit) {
        window?.displayedUsedPercent?.let { stringResource(R.string.s_consumidos_de_la_cuota, consumedAmount, it) }
            ?: stringResource(R.string.s_consumidos_3, consumedAmount)
    } else stringResource(R.string.s_consumidos_3, consumedAmount)
    val stale = snapshot?.let {
        now.epochSecond - it.updatedAt.epochSecond > 300 ||
            it.windows.any { w -> (w.resetsAt ?: Instant.MAX) <= now } || store.errors[provider] != null
    } ?: false
    val accent = if (store.nightMode) ProviderStyle.nightTone else ProviderStyle.accent(provider)

    Column(
        Modifier.fillMaxWidth().testTag("panel_${provider.raw}"),
        verticalArrangement = Arrangement.spacedBy(if (compact) 12.dp else 20.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ProviderLogo(provider, accent, 20.dp)
            Spacer(Modifier.width(10.dp))
            Text(provider.title, color = tone, fontSize = if (compact) 17.sp else 20.sp, fontWeight = if (compact) FontWeight.SemiBold else FontWeight.Medium)
        }
        if (window != null && snapshot != null) {
            val percent = window.displayedPercent(display)
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    percent?.toString() ?: if (provider == Provider.COPILOT) plainAmount(window.used, 1) else "—",
                    fontSize = if (compact) 62.sp else 88.sp, fontWeight = FontWeight.Light, fontFamily = FontFamily.SansSerif,
                    letterSpacing = (-3).sp, maxLines = 1, color = tone, modifier = Modifier.testTag("quota_${provider.raw}"),
                )
                if (percent != null) Text("%", fontSize = 28.sp, fontWeight = FontWeight.Light, color = accent, modifier = Modifier.padding(bottom = 14.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                InformationRow(compact, {
                    Text(
                        if (percent == null) stringResource(R.string.s_consumido_cuota_desconocida) else display.headline(context),
                        fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp, color = tone,
                    )
                }, { Text(window.localizedTitle(context), fontSize = 12.sp, color = SecondaryText) })
                if (percent != null) ProgressBar(percent, accent)
                InformationRow(compact, {
                    Text(
                        if (provider == Provider.COPILOT) copilotDetail
                        else window.complementPercent(display)?.let { stringResource(R.string.s_s_3, it, display.complementNoun(context)) }
                            ?: stringResource(R.string.s_consumo_desconocido),
                        fontSize = 12.sp, color = SecondaryText, modifier = Modifier.testTag("used_${provider.raw}"),
                    )
                }, {
                    window.resetsAt?.let { reset ->
                        Text(
                            if (reset > now) stringResource(R.string.s_renueva, relativeFuture(now, reset).toString())
                            else stringResource(R.string.s_renovacion_pendiente),
                            fontSize = 12.sp, color = SecondaryText,
                        )
                    }
                })
                if (isCredit) {
                    window.limit?.let { Text(stringResource(R.string.s_de_limite_mensual, creditAmount(it)), fontSize = 12.sp, color = SecondaryText) }
                    InformationRow(compact, {
                        window.remaining?.let { Text(stringResource(R.string.s_restantes, creditAmount(it)), fontSize = 12.sp, color = SecondaryText) }
                    }, {
                        window.reportedRemainingPercent?.let {
                            Text(stringResource(R.string.s_disponible_3, plainAmount(it, 1)), fontSize = 12.sp, color = SecondaryText)
                        }
                    })
                }
            }
            snapshot.windows.drop(1).forEach { extra -> ExtraWindow(extra, store, compact, now, accent, tone) }
            Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                val reading = shortTime(context, snapshot.updatedAt)
                Text(
                    if (stale) stringResource(R.string.s_sin_actualizar_ultima_lectura, reading) else stringResource(R.string.s_lectura_2, reading),
                    fontSize = 11.sp, color = if (stale) WarningColor else SecondaryText,
                )
                if (provider == Provider.COPILOT && !store.organizationPlan) {
                    Text(stringResource(R.string.s_informe_de_facturacion_puede_llevar_retraso), fontSize = 11.sp, color = SecondaryText)
                }
            }
        } else {
            Text("—", fontSize = if (compact) 62.sp else 88.sp, fontWeight = FontWeight.ExtraLight, color = accent.copy(alpha = 0.6f))
            Text(
                if (provider == Provider.COPILOT && store.githubConfigured) stringResource(R.string.s_cuenta_guardada_sin_lectura_de_cuota)
                else stringResource(R.string.s_tu_cuota_a_un_vistazo),
                fontSize = 15.sp, color = SecondaryText,
            )
            TextButton(onClick = onOpenConnections) {
                Icon(Icons.Default.Add, null, Modifier.size(16.dp), tint = accent)
                Spacer(Modifier.width(6.dp))
                Text(
                    if (provider == Provider.COPILOT && store.githubConfigured) stringResource(R.string.s_revisar_copilot)
                    else stringResource(R.string.s_conectar, provider.title),
                    color = accent, fontWeight = FontWeight.Medium,
                )
            }
        }
        val error = store.errors[provider]
        if (!store.demo && error != null) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Default.ErrorOutline, null, Modifier.size(14.dp).padding(top = 1.dp), tint = WarningColor)
                Spacer(Modifier.width(6.dp))
                Text(error, fontSize = 12.sp, color = WarningColor)
            }
        }
    }
}

@Composable
private fun ExtraWindow(extra: UsageWindow, store: UsageStore, compact: Boolean, now: Instant, accent: Color, tone: Color) {
    val context = LocalContext.current
    val display = store.quotaDisplay
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        InformationRow(compact, { Text(extra.localizedTitle(context), fontSize = 14.sp, color = tone) }, {
            Text(
                extra.displayedPercent(display)?.let {
                    stringResource(R.string.s_s_5, it, display.headlineNoun(context), extra.complementPercent(display) ?: 0, display.complementNoun(context))
                } ?: stringResource(R.string.s_sin_cuota),
                fontSize = 14.sp, color = accent,
            )
        })
        extra.resetsAt?.let { reset ->
            Text(
                if (reset > now) stringResource(R.string.s_renueva, relativeFuture(now, reset).toString())
                else stringResource(R.string.s_renovacion_pendiente_ultima_lectura),
                fontSize = 12.sp, color = if (reset > now) SecondaryText else WarningColor,
            )
        }
    }
}

@Composable
private fun ProgressBar(filled: Int, accent: Color) {
    Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(accent.copy(alpha = 0.12f))) {
        Box(Modifier.fillMaxWidth(filled.coerceIn(0, 100) / 100f).height(4.dp).clip(CircleShape).background(accent))
    }
}

@Composable
fun ProviderLogo(provider: Provider, tint: Color, size: androidx.compose.ui.unit.Dp = 16.dp) {
    val res = when (provider) {
        Provider.CODEX -> R.drawable.ic_codex
        Provider.COPILOT -> R.drawable.logo_copilot
        Provider.CLAUDE -> R.drawable.logo_claude
    }
    Icon(painterResource(res), null, Modifier.size(size), tint = tint)
}

@Composable
private fun Footer(store: UsageStore) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Refresh, null, Modifier.size(12.dp), tint = SecondaryText)
            Spacer(Modifier.width(7.dp))
            Text(stringResource(R.string.s_consulta_cada_minuto_con_la_app_abierta), fontSize = 11.sp, color = SecondaryText)
        }
        if (BuildConfig.DEBUG) {
            if (store.demo) {
                TextButton(onClick = { store.changeDemo(false) }, modifier = Modifier.testTag("exitDemoButton")) {
                    Text(stringResource(R.string.s_salir_de_la_demostracion))
                }
            } else if (store.snapshots.isEmpty()) {
                TextButton(onClick = { store.changeDemo(true) }, modifier = Modifier.testTag("demoButton")) {
                    Text(stringResource(R.string.s_ver_una_demostracion))
                }
            }
        }
    }
}

