package com.jesusom.pulso.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jesusom.pulso.BuildConfig
import com.jesusom.pulso.R
import com.jesusom.pulso.Services
import com.jesusom.pulso.core.BackgroundRefresh
import com.jesusom.pulso.core.Provider
import com.jesusom.pulso.core.QuotaDisplay
import com.jesusom.pulso.core.UsageStore
import com.jesusom.pulso.core.dateAndTime
import com.jesusom.pulso.core.localizedQuotaStatus
import kotlinx.coroutines.launch
import java.time.Instant

@Composable
fun PulsoRoot(store: UsageStore, services: Services, showConnections: Boolean, onShowConnections: (Boolean) -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        DashboardScreen(store) { onShowConnections(true) }
        if (showConnections) {
            BackHandler { onShowConnections(false) }
            ConnectionsScreen(store, services) { onShowConnections(false) }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text.uppercase(), fontSize = 12.sp, color = SecondaryText, letterSpacing = 1.sp,
        modifier = Modifier.padding(top = 28.dp, bottom = 8.dp),
    )
}

@Composable
private fun Caption(text: String, color: Color = SecondaryText, modifier: Modifier = Modifier) =
    Text(text, fontSize = 12.sp, color = color, modifier = modifier.padding(vertical = 4.dp))

@Composable
private fun LabeledValue(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = Color.White)
        Text(value, color = SecondaryText)
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, tag: String? = null, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Text(label, color = Color.White, modifier = Modifier.weight(1f).padding(end = 12.dp))
        Switch(checked, onChange, modifier = if (tag != null) Modifier.testTag(tag) else Modifier)
    }
}

@Composable
private fun ActionButton(text: String, destructive: Boolean = false, enabled: Boolean = true, tag: String? = null, onClick: () -> Unit) {
    TextButton(
        onClick, enabled = enabled, modifier = if (tag != null) Modifier.testTag(tag) else Modifier,
        colors = ButtonDefaults.textButtonColors(contentColor = if (destructive) Color(0xFFFF453A) else MaterialTheme.colorScheme.primary),
    ) { Text(text) }
}

@Composable
private fun LinkButton(text: String, url: String) {
    val context = LocalContext.current
    ActionButton(text) { openUrl(context, url) }
}

private fun openUrl(context: Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionsScreen(store: UsageStore, services: Services, onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var token by remember { mutableStateOf("") }
    var draft by remember { mutableStateOf(store.githubDraft) }
    var saving by remember { mutableStateOf(false) }
    var disconnecting by remember { mutableStateOf(false) }
    var confirmDisconnect by remember { mutableStateOf<Provider?>(null) }
    var showingClaude by remember { mutableStateOf(false) }

    if (showingClaude) {
        ClaudeLoginScreen(store) { showingClaude = false }
        return
    }
    val locked = saving || disconnecting || store.codex.isSigningIn
    BackHandler(enabled = locked) {}

    Column(Modifier.fillMaxSize().background(Color.Black).statusBarsPadding().navigationBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            Text(stringResource(R.string.s_conexiones), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            TextButton(onClick = onDone, enabled = !locked) { Text(stringResource(R.string.s_listo)) }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp)) {
            Text(stringResource(R.string.a_title_accounts), fontSize = 22.sp, fontWeight = FontWeight.Medium, color = Color.White)
            Caption(stringResource(R.string.s_las_credenciales_permanecen_en_el_dispositiv))

            SectionHeader(stringResource(R.string.s_paneles_visibles))
            Provider.entries.forEach { provider ->
                ToggleRow(provider.title, store.isProviderVisible(provider), "visible_${provider.raw}") {
                    store.setProviderVisible(provider, it)
                }
            }
            Caption(stringResource(R.string.a_visible_note))

            // Codex
            SectionHeader("Codex")
            LabeledValue(
                stringResource(R.string.s_conexion),
                stringResource(if (store.codexConfigured) R.string.s_sesion_guardada else R.string.s_sin_conectar),
            )
            store.codex.accountLabel?.let { LabeledValue(stringResource(R.string.s_cuenta_de_chatgpt), it) }
            Caption(stringResource(R.string.s_la_cifra_grande_es_lo_disponible_el_porcenta))
            ActionButton(
                stringResource(if (store.codex.isSigningIn) R.string.s_esperando_a_chatgpt else R.string.s_entrar_con_chatgpt),
                enabled = !store.codex.isSigningIn && !disconnecting, tag = "codexNativeSignIn",
            ) {
                scope.launch {
                    store.signInCodex { url ->
                        runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        }.isSuccess
                    }
                }
            }
            if (store.codex.isSigningIn) ActionButton(stringResource(R.string.s_cancelar_inicio_de_sesion)) { store.codex.cancelSignIn() }
            ActionButton(stringResource(R.string.s_borrar_sesion_de_codex), destructive = true) { confirmDisconnect = Provider.CODEX }
            store.errors[Provider.CODEX]?.let { Caption(it, WarningColor) }
            Caption(stringResource(R.string.a_codex_footer))

            // Claude
            SectionHeader("Claude")
            LabeledValue(
                stringResource(R.string.s_conexion),
                stringResource(if (store.claudeConfigured) R.string.s_sesion_web else R.string.s_sin_conectar),
            )
            ActionButton(stringResource(R.string.s_abrir_sesion_de_claude)) { showingClaude = true }
            if (store.claude.organizations.size > 1) {
                Text(stringResource(R.string.s_espacio_de_trabajo), color = Color.White, modifier = Modifier.padding(top = 8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.horizontalScrollCompat()) {
                    store.claude.organizations.forEach { organization ->
                        FilterChip(
                            selected = store.claude.selectedOrganizationID == organization.id,
                            onClick = { scope.launch { store.selectClaudeOrganization(organization.id) } },
                            label = { Text(organization.name) },
                        )
                    }
                }
                services.prefs.long("claudeNativeLastAttempt")?.let { millis ->
                    Caption(
                        stringResource(
                            R.string.s_claude_http_nativo,
                            localizedQuotaStatus(context, services.prefs.string("claudeNativeLastResult") ?: "—"),
                            dateAndTime(context, Instant.ofEpochMilli(millis)),
                        )
                    )
                }
            }
            ActionButton(stringResource(R.string.s_borrar_sesion_web_de_claude), destructive = true) { confirmDisconnect = Provider.CLAUDE }
            store.errors[Provider.CLAUDE]?.let { Caption(it, WarningColor) }
            Caption(stringResource(R.string.s_consulta_los_limites_de_tu_plan_de_claude_y))

            // GitHub Copilot
            SectionHeader("GitHub Copilot")
            if (store.githubConfigured) {
                LabeledValue(stringResource(R.string.s_cuenta_guardada), "@${store.username}")
                Caption(stringResource(R.string.a_secure_saved))
            }
            OutlinedTextField(
                draft.username, { draft = draft.copy(username = it) }, singleLine = true,
                label = { Text(stringResource(R.string.s_usuario_de_github)) },
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth().testTag("githubUsername"),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                token, { token = it }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                label = {
                    Text(stringResource(if (store.githubConfigured) R.string.s_nuevo_token_opcional else R.string.s_token_personal_de_github))
                },
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(stringResource(R.string.s_tipo_de_cuenta), color = Color.White, modifier = Modifier.padding(top = 12.dp, bottom = 4.dp))
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().testTag("githubAccountType")) {
                SegmentedButton(
                    selected = draft.organizationPlan, onClick = { draft = draft.copy(organizationPlan = true) },
                    shape = SegmentedButtonDefaults.itemShape(0, 2),
                ) { Text(stringResource(R.string.s_empresa_u_organizacion), fontSize = 12.sp, maxLines = 1) }
                SegmentedButton(
                    selected = !draft.organizationPlan, onClick = { draft = draft.copy(organizationPlan = false) },
                    shape = SegmentedButtonDefaults.itemShape(1, 2),
                ) { Text(stringResource(R.string.s_personal_pagada_por_mi), fontSize = 12.sp, maxLines = 1) }
            }
            if (draft.organizationPlan) {
                Caption(stringResource(R.string.s_la_cuota_se_consulta_en_tu_cuenta_de_copilot))
                AllowanceField(stringResource(R.string.s_limite_mensual_de_respaldo_opcional), draft.allowanceText) { draft = draft.copy(allowanceText = it) }
            } else {
                ToggleRow(stringResource(R.string.s_plan_con_peticiones_premium_antiguas), draft.legacy) { draft = draft.copy(legacy = it) }
                AllowanceField(
                    stringResource(if (draft.legacy) R.string.s_cuota_mensual_de_peticiones_opcional else R.string.s_creditos_incluidos_al_mes_opcional),
                    draft.allowanceText,
                ) { draft = draft.copy(allowanceText = it) }
            }
            ActionButton(
                stringResource(if (saving) R.string.s_consultando else R.string.s_guardar_y_consultar_copilot),
                enabled = !saving && !disconnecting,
            ) {
                saving = true
                scope.launch {
                    try {
                        store.saveGitHub(draft.username, draft.allowanceText, draft.legacy, token, draft.organizationPlan)
                    } finally {
                        token = ""
                        saving = false
                    }
                }
            }
            LinkButton(stringResource(R.string.s_ver_mi_uso_en_github), "https://github.com/settings/copilot/features")
            LinkButton(stringResource(R.string.s_crear_token_en_github), "https://github.com/settings/personal-access-tokens/new")
            ActionButton(stringResource(R.string.s_borrar_conexion_de_copilot), destructive = true) { confirmDisconnect = Provider.COPILOT }
            store.errors[Provider.COPILOT]?.let { Caption(it, WarningColor) }
            Caption(stringResource(R.string.a_github_footer))

            // Display
            SectionHeader(stringResource(R.string.s_pantalla))
            Text(stringResource(R.string.s_mostrar_cuotas_como), color = Color.White)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 6.dp).testTag("quotaDisplayPicker")) {
                SegmentedButton(
                    selected = store.quotaDisplay == QuotaDisplay.REMAINING,
                    onClick = { store.changeQuotaDisplay(QuotaDisplay.REMAINING) }, shape = SegmentedButtonDefaults.itemShape(0, 2),
                ) { Text(stringResource(R.string.s_restante)) }
                SegmentedButton(
                    selected = store.quotaDisplay == QuotaDisplay.USED,
                    onClick = { store.changeQuotaDisplay(QuotaDisplay.USED) }, shape = SegmentedButtonDefaults.itemShape(1, 2),
                ) { Text(stringResource(R.string.s_usado_3)) }
            }
            Caption(stringResource(R.string.s_se_aplica_al_panel_y_a_los_widgets_la_otra_c))

            // Live activity
            SectionHeader(stringResource(R.string.a_live_section))
            ToggleRow(stringResource(R.string.s_activar_actividad_en_directo), store.liveActivity.enabled, "liveActivityToggle") {
                store.liveActivity.changeEnabled(it)
            }
            if (store.liveActivity.enabled) {
                Text(stringResource(R.string.a_live_provider), color = Color.White, modifier = Modifier.padding(top = 8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag("liveActivityProvider")) {
                    Provider.entries.forEach { provider ->
                        FilterChip(
                            selected = store.liveActivity.provider == provider,
                            onClick = { store.selectLiveActivityProvider(provider) }, label = { Text(provider.title) },
                        )
                    }
                }
                LabeledValue(
                    stringResource(R.string.s_estado),
                    stringResource(if (store.liveActivity.isRunning) R.string.s_en_curso else R.string.s_detenida),
                )
                if (store.liveActivity.isRunning) {
                    ActionButton(stringResource(R.string.s_finalizar_actividad), destructive = true, tag = "stopLiveActivity") { store.liveActivity.stop() }
                } else {
                    ActionButton(stringResource(R.string.s_iniciar_actividad_en_directo), enabled = !disconnecting, tag = "startLiveActivity") {
                        scope.launch {
                            services.notificationPermission?.invoke()
                            store.startLiveActivity()
                        }
                    }
                }
            }
            store.liveActivity.message?.let { Caption(it, WarningColor, Modifier.testTag("liveActivityMessage")) }
            Caption(stringResource(R.string.a_live_footer))

            // Notifications
            SectionHeader(stringResource(R.string.s_notificaciones))
            ToggleRow(stringResource(R.string.s_avisarme_cuando_se_restablezca_una_cuota), store.resetAlerts, "resetAlertsToggle") {
                scope.launch { store.setResetAlerts(it) }
            }
            if (store.notificationsDenied) {
                Caption(stringResource(R.string.a_notifications_denied), WarningColor)
                ActionButton(stringResource(R.string.a_open_settings)) {
                    context.startActivity(
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                }
            }
            Caption(stringResource(R.string.s_el_aviso_se_programa_para_la_hora_exacta_de))

            // Desk
            SectionHeader(stringResource(R.string.s_en_tu_escritorio))
            ToggleRow(stringResource(R.string.s_mantener_pantalla_encendida), store.deskMode) { store.deskMode = it }
            ToggleRow(stringResource(R.string.s_tono_nocturno), store.nightMode) { store.nightMode = it }
            Caption(stringResource(R.string.a_desk_footer))

            // Background
            SectionHeader(stringResource(R.string.s_actualizacion_en_segundo_plano))
            BackgroundSection(services)

            // Debug-only development controls
            SectionHeader("")
            if (BuildConfig.DEBUG) {
                ToggleRow(stringResource(R.string.s_mostrar_datos_de_ejemplo), store.demo, "demoToggle") { store.changeDemo(it) }
                Caption(stringResource(R.string.s_la_demostracion_no_reemplaza_las_lecturas_re))
            }
            ActionButton(stringResource(R.string.s_actualizar_ahora), enabled = !store.refreshing && !store.demo && !disconnecting) {
                scope.launch { store.refresh() }
            }

            SectionHeader(stringResource(R.string.s_acerca_de_pulso))
            Text("© 2026 Jesus Oliva Morales (olivathedev)", fontSize = 13.sp, color = Color.White, modifier = Modifier.testTag("authorCopyright"))
            LinkButton(stringResource(R.string.s_web_del_desarrollador), "https://olivathedev.com/")
            LinkButton(stringResource(R.string.s_invitame_a_un_cafe), "https://ko-fi.com/olivathedev")
            Caption(stringResource(R.string.s_uso_personal_no_comercial_los_derechos_de_ve))
            Spacer(Modifier.height(32.dp))
        }
    }

    confirmDisconnect?.let { provider ->
        AlertDialog(
            onDismissRequest = { confirmDisconnect = null },
            title = { Text(stringResource(R.string.s_borrar_la_conexion_y_sus_datos_locales)) },
            confirmButton = {
                TextButton(onClick = {
                    disconnecting = true
                    confirmDisconnect = null
                    scope.launch {
                        store.disconnect(provider)
                        draft = store.githubDraft
                        disconnecting = false
                    }
                }) { Text(stringResource(R.string.s_desconectar, provider.title), color = Color(0xFFFF453A)) }
            },
            dismissButton = { TextButton(onClick = { confirmDisconnect = null }) { Text(stringResource(R.string.s_cerrar)) } },
        )
    }
}

@Composable
private fun Modifier.horizontalScrollCompat(): Modifier = this.then(Modifier.horizontalScroll(rememberScrollState()))

@Composable
private fun AllowanceField(label: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value, onChange, singleLine = true, label = { Text(label) },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
    )
}

@Composable
private fun BackgroundSection(services: Services) {
    val context = LocalContext.current
    val report = BackgroundRefresh.report(services.prefs)
    val power = context.getSystemService(PowerManager::class.java)
    Column(Modifier.testTag("backgroundSection")) {
        LabeledValue(
            stringResource(R.string.a_battery_saver),
            stringResource(if (power.isPowerSaveMode) R.string.s_activado else R.string.s_desactivado),
        )
        LabeledValue(
            stringResource(R.string.a_battery_optimization),
            stringResource(if (power.isIgnoringBatteryOptimizations(context.packageName)) R.string.s_desactivada else R.string.s_activada),
        )
        report.lastRequest?.let { request ->
            Caption(stringResource(R.string.s_ultima_solicitud, dateAndTime(context, request)), Color.White)
            val error = report.schedulingError
            if (error != null) Caption(stringResource(R.string.s_solicitud_rechazada, error), WarningColor)
            else report.requestedAfter?.let { Caption(stringResource(R.string.s_aceptada_no_antes_de, dateAndTime(context, it))) }
        }
        report.lastRun?.let { run ->
            Caption(stringResource(R.string.s_ultimo_intento, dateAndTime(context, run)), Color.White)
            Caption(localizedQuotaStatus(context, report.outcome ?: "—"))
            Caption(stringResource(R.string.s_despertares_desde_la_instalacion, report.count))
        } ?: Caption(stringResource(R.string.a_bg_never))
        Provider.entries.forEach { provider ->
            services.widgetState.attempt(provider)?.let { attempt ->
                Caption(
                    stringResource(
                        R.string.s_widget, provider.title, localizedQuotaStatus(context, attempt.result), dateAndTime(context, attempt.date),
                    )
                )
            }
        }
        Caption(stringResource(R.string.a_bg_footer))
    }
}

