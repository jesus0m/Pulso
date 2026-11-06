package com.jesusom.pulso.core

import android.content.Context
import com.jesusom.pulso.R
import kotlinx.coroutines.CancellationException
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64

data class CodexCredentials(
    val accessToken: String,
    val refreshToken: String?,
    val idToken: String?,
    val accountID: String?,
    val email: String?,
    val expiresAt: Instant?,
) {
    fun needsRefresh(now: Instant) = expiresAt?.let { it <= now.plusSeconds(300) } ?: false

    fun toJson(): JSONObject = JSONObject().apply {
        put("accessToken", accessToken)
        refreshToken?.let { put("refreshToken", it) }
        idToken?.let { put("idToken", it) }
        accountID?.let { put("accountID", it) }
        email?.let { put("email", it) }
        expiresAt?.let { put("expiresAt", it.toEpochMilli() / 1000.0) }
    }

    companion object {
        fun fromJson(o: JSONObject) = CodexCredentials(
            o.getString("accessToken"), o.optString("refreshToken").ifEmpty { null },
            o.optString("idToken").ifEmpty { null }, o.optString("accountID").ifEmpty { null },
            o.optString("email").ifEmpty { null }, o.optDoubleOrNull("expiresAt")?.let(::epochToInstant),
        )
    }
}

sealed class CodexAuthError : Exception(), LocalizedError {
    object Random : CodexAuthError()
    object Callback : CodexAuthError()
    object Denied : CodexAuthError()
    object Listener : CodexAuthError()
    object Timeout : CodexAuthError()
    object Browser : CodexAuthError()
    object InvalidResponse : CodexAuthError()
    object SignIn : CodexAuthError()
    object Forbidden : CodexAuthError()
    data class Http(val code: Int) : CodexAuthError()

    override fun describe(c: Context): String = when (this) {
        Random -> c.getString(R.string.s_no_se_pudo_preparar_un_inicio_de_sesion_segu)
        Callback -> c.getString(R.string.s_no_se_pudo_verificar_la_respuesta_del_inicio)
        Denied -> c.getString(R.string.s_no_se_ha_autorizado_la_conexion_con_chatgpt)
        Listener -> c.getString(R.string.s_no_se_pudo_abrir_el_receptor_local_del_inici)
        Timeout -> c.getString(R.string.s_el_inicio_de_sesion_ha_tardado_demasiado_vue)
        Browser -> c.getString(R.string.s_no_se_pudo_abrir_la_ventana_segura_de_chatgp)
        InvalidResponse -> c.getString(R.string.s_chatgpt_devolvio_una_respuesta_de_autenticac)
        SignIn -> c.getString(R.string.s_la_sesion_de_codex_ha_caducado_o_no_es_valid)
        Forbidden -> c.getString(R.string.s_chatgpt_no_permite_consultar_la_cuota_de_cod)
        is Http -> c.getString(R.string.s_no_se_pudo_consultar_chatgpt_http, code)
    }
}

object CodexOAuth {
    // Public Codex registration, not a Pulso-issued client. Quota access is experimental.
    const val CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
    const val TOKEN_URL = "https://auth.openai.com/oauth/token"

    class Attempt(val state: String, val verifier: String)

    fun makeAttempt(random: SecureRandom = SecureRandom()): Attempt {
        fun token(count: Int) = ByteArray(count).also(random::nextBytes).let(::base64Url)
        return Attempt(token(32), token(64))
    }

    fun challenge(verifier: String): String =
        base64Url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))

    private fun base64Url(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    fun percentEncode(value: String): String = buildString {
        for (b in value.toByteArray(Charsets.UTF_8)) {
            val ch = b.toInt().toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch in "-._~") append(ch)
            else append('%').append("%02X".format(b.toInt() and 0xFF))
        }
    }

    fun authorizationUrl(redirect: String, attempt: Attempt): String {
        val query = listOf(
            "client_id" to CLIENT_ID, "redirect_uri" to redirect, "response_type" to "code",
            "scope" to "openid profile email offline_access", "state" to attempt.state,
            "code_challenge" to challenge(attempt.verifier), "code_challenge_method" to "S256",
            "id_token_add_organizations" to "true", "codex_cli_simplified_flow" to "true",
            "originator" to "codex_cli_rs",
        ).joinToString("&") { (k, v) -> "$k=${percentEncode(v)}" }
        return "https://auth.openai.com/oauth/authorize?$query"
    }

    /** Callback must match the redirect exactly, carry the expected state, and exactly one code. */
    fun authorizationCode(callback: String, redirect: String, state: String): String {
        val cb = try { URI(callback) } catch (e: Exception) { throw CodexAuthError.Callback }
        val rd = URI(redirect)
        if (cb.scheme != rd.scheme || cb.host != rd.host || cb.port != rd.port || cb.path != rd.path) {
            throw CodexAuthError.Callback
        }
        val query = (cb.rawQuery ?: "").split("&").filter { it.isNotEmpty() }.map {
            val pair = it.split("=", limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
        }
        fun values(name: String) = query.filter { it.first == name }.map { it.second }
        if (values("state") != listOf(state)) throw CodexAuthError.Callback
        if (values("error").isNotEmpty()) throw CodexAuthError.Denied
        val codes = values("code")
        if (codes.size != 1 || codes[0].isEmpty()) throw CodexAuthError.Callback
        return codes[0]
    }
}

class CodexOAuthClient(
    private val transport: HttpTransport = UrlConnectionTransport,
    val now: () -> Instant = Instant::now,
) {
    suspend fun exchange(code: String, redirect: String, verifier: String): CodexCredentials = tokens(
        listOf("grant_type" to "authorization_code", "code" to code, "redirect_uri" to redirect, "code_verifier" to verifier),
        null,
    )

    suspend fun refresh(credentials: CodexCredentials): CodexCredentials {
        val refresh = credentials.refreshToken?.takeIf { it.isNotEmpty() } ?: throw CodexAuthError.SignIn
        return tokens(listOf("grant_type" to "refresh_token", "refresh_token" to refresh), credentials)
    }

    private suspend fun tokens(fields: List<Pair<String, String>>, previous: CodexCredentials?): CodexCredentials {
        val body = (fields + ("client_id" to CodexOAuth.CLIENT_ID))
            .joinToString("&") { (k, v) -> "$k=${CodexOAuth.percentEncode(v)}" }
        val data = perform(
            HttpRequest(
                CodexOAuth.TOKEN_URL, "POST", mapOf("Content-Type" to "application/x-www-form-urlencoded"),
                body.toByteArray(), 20_000,
            )
        )
        val reply = try {
            val o = parseObject(data)
            val access = o.requiredString("access_token")
            if (access.isEmpty()) throw SchemaException()
            Reply(access, o.strictString("refresh_token"), o.strictString("id_token"), o.strictDouble("expires_in"))
        } catch (e: SchemaException) {
            throw CodexAuthError.InvalidResponse
        }
        val idToken = reply.idToken ?: previous?.idToken
        // Claims are display/routing hints only, never proof of a verified identity.
        val claims = payload(reply.accessToken)
        val identity = idToken?.let(::payload) ?: JSONObject()
        fun accountIn(o: JSONObject) = o.optJSONObject("https://api.openai.com/auth")?.optString("chatgpt_account_id")?.ifEmpty { null }
        val account = accountIn(identity) ?: accountIn(claims) ?: previous?.accountID
        val expiry = reply.expiresIn?.let { now().plusMillis((it * 1000).toLong()) }
            ?: claims.optDoubleOrNull("exp")?.let(::epochToInstant)
        return CodexCredentials(
            reply.accessToken, reply.refreshToken ?: previous?.refreshToken, idToken, account,
            identity.optString("email").ifEmpty { null } ?: previous?.email, expiry,
        )
    }

    suspend fun fetchUsage(credentials: CodexCredentials): UsageSnapshot {
        // Private ChatGPT backend, not a public quota API for third-party clients.
        val headers = mutableMapOf(
            "Authorization" to "Bearer ${credentials.accessToken}", "Accept" to "application/json", "User-Agent" to "Pulso",
        )
        credentials.accountID?.takeIf { it.isNotEmpty() }?.let { headers["ChatGPT-Account-Id"] = it }
        val data = perform(HttpRequest("https://chatgpt.com/backend-api/wham/usage", headers = headers, timeoutMs = 20_000))
        return CodexUsageParser.parse(data, now()).copy(source = "Codex · OAuth experimental · API no pública")
    }

    private suspend fun perform(request: HttpRequest): ByteArray {
        val response = transport.execute(request)
        return when (response.status) {
            in 200..299 -> response.body
            401 -> throw CodexAuthError.SignIn
            403 -> throw CodexAuthError.Forbidden
            else -> throw CodexAuthError.Http(response.status)
        }
    }

    private fun payload(jwt: String): JSONObject {
        val parts = jwt.split(".")
        if (parts.size != 3) return JSONObject()
        return try {
            JSONObject(String(Base64.getUrlDecoder().decode(parts[1].trimEnd('='))))
        } catch (e: Exception) { JSONObject() }
    }

    private class Reply(val accessToken: String, val refreshToken: String?, val idToken: String?, val expiresIn: Double?)
}

class CodexCredentialVault(private val store: SecretStore) {
    fun load(): CodexCredentials? = store.load(NAME)?.let { CodexCredentials.fromJson(JSONObject(String(it))) }

    fun save(credentials: CodexCredentials) = SharedQuotaAccess.transaction {
        store.save(NAME, credentials.toJson().toString().toByteArray())
    }

    fun delete() = SharedQuotaAccess.transaction { store.delete(NAME) }

    fun replace(credentials: CodexCredentials, matching: CodexCredentials) = SharedQuotaAccess.transaction {
        if (load() != matching) throw CancellationException("Credentials changed")
        save(credentials)
    }

    private companion object { const val NAME = "codex.oauth" }
}
