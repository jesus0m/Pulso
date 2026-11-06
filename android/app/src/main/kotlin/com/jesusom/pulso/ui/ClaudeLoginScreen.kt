package com.jesusom.pulso.ui

import android.view.ViewGroup
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GppMaybe
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.jesusom.pulso.R
import com.jesusom.pulso.core.UsageStore
import kotlinx.coroutines.launch

/** Claude sign-in: email entry first (Google refuses embedded browsers), then the official page. */
@Composable
fun ClaudeLoginScreen(store: UsageStore, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }
    var enteringEmail by remember { mutableStateOf(true) }
    val validEmail = remember(email) { isValidEmail(email) }

    DisposableEffect(Unit) {
        onDispose { store.claude.cancelEmailLogin() }
    }

    Column(Modifier.fillMaxSize().background(Color.Black).statusBarsPadding().navigationBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onClose) { Text(stringResource(R.string.s_cerrar)) }
            Text("Claude", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = Color.White)
            if (!enteringEmail) {
                TextButton(onClick = {
                    onClose()
                    scope.launch { store.enableClaude() }
                }) { Text(stringResource(R.string.s_consultar_cuota)) }
            } else Spacer(Modifier.size(48.dp))
        }
        if (enteringEmail) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp)) {
                Text(stringResource(R.string.s_entra_con_tu_correo), fontSize = 22.sp, fontWeight = FontWeight.Medium, color = Color.White)
                Text(
                    stringResource(R.string.s_pulso_rellena_y_envia_tu_correo_en_la_web_of),
                    fontSize = 14.sp, color = SecondaryText, modifier = Modifier.padding(vertical = 8.dp),
                )
                OutlinedTextField(
                    email, { email = it }, singleLine = true,
                    label = { Text(stringResource(R.string.s_correo_de_tu_cuenta_de_claude)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth().testTag("claudeLoginEmail"),
                )
                TextButton(
                    onClick = {
                        store.beginClaudeLogin(email)
                        email = ""
                        enteringEmail = false
                    },
                    enabled = validEmail, modifier = Modifier.testTag("claudeContinueEmail"),
                ) { Text(stringResource(R.string.s_continuar_con_correo)) }
                TextButton(onClick = {
                    store.beginClaudeLogin()
                    email = ""
                    enteringEmail = false
                }) { Text(stringResource(R.string.s_abrir_web_sin_rellenar_el_correo)) }
                Text(stringResource(R.string.a_claude_email_footer), fontSize = 12.sp, color = SecondaryText)
            }
        } else {
            WebContent(store)
        }
    }
}

internal fun isValidEmail(text: String): Boolean {
    val email = text.trim()
    val parts = email.split("@")
    return email.length <= 254 && parts.size == 2 && parts[0].isNotEmpty() && parts[1].contains(".") && email.none { it.isWhitespace() }
}

@Composable
private fun WebContent(store: UsageStore) {
    val session = store.claude
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().background(Color(0xFF1C1C1E)).padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Lock, null, Modifier.size(16.dp), tint = Color.White)
            Text(session.address, fontSize = 12.sp, color = Color.White, modifier = Modifier.weight(1f).padding(start = 8.dp))
            if (session.loading) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Color.White)
        }
        if (session.blockedLoginHost != null) EmbeddedLoginBlocked { session.openLogin() }
        AndroidView(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            factory = { host ->
                session.webView(host).also { view ->
                    (view.parent as? ViewGroup)?.removeView(view)
                    view.layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                }
            },
            onRelease = { session.detach() },
        )
        session.emailLoginNotice?.let { Text(it, fontSize = 12.sp, color = SecondaryText, modifier = Modifier.padding(12.dp)) }
        Text(
            stringResource(R.string.s_inicia_sesion_en_claude_ai_y_pulsa_consultar),
            fontSize = 12.sp, color = SecondaryText, modifier = Modifier.padding(12.dp),
        )
    }
}

@Composable
private fun EmbeddedLoginBlocked(retry: () -> Unit) {
    val site = "claude.ai"
    Column(
        Modifier.fillMaxWidth().background(Color(0xFFFF9F0A).copy(alpha = 0.12f)).padding(12.dp).testTag("embeddedLoginBlocked"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.GppMaybe, null, Modifier.size(16.dp), tint = Color.White)
            Text(
                stringResource(R.string.s_google_no_permite_iniciar_sesion_aqui), fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp, color = Color.White, modifier = Modifier.padding(start = 6.dp),
            )
        }
        Text(stringResource(R.string.s_es_una_proteccion_antiphishing_de_google_fre), fontSize = 12.sp, color = Color.White)
        Text(stringResource(R.string.s_vuelve_a_y_entra_con_tu_correo_te_envia_un_c, site), fontSize = 12.sp, color = Color.White)
        TextButton(onClick = retry) { Text(stringResource(R.string.s_volver_a, site)) }
        Spacer(Modifier.height(0.dp))
    }
}
