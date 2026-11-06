package com.jesusom.pulso.core

import android.content.Context
import com.jesusom.pulso.R
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

data class WebCookie(
    val name: String, val value: String, val domain: String, val path: String,
    val secure: Boolean, val expires: Instant?,
)

data class ClaudeWebCredentials(
    val sessionKey: String,
    val organizationID: String,
    val expiresAt: Instant?,
) {
    fun validate(now: Instant) {
        val validOrg = try { UUID.fromString(organizationID).toString().equals(organizationID, true) } catch (e: Exception) { false }
        val validKey = sessionKey.startsWith("sk-ant-") &&
            sessionKey.toByteArray(Charsets.UTF_8).all { it.toInt() in 33..126 && it.toInt() !in intArrayOf(34, 44, 59, 92) }
        if (!validOrg || !validKey || expiresAt?.let { it <= now } == true) throw ClaudeQuotaError.SignIn
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("sessionKey", sessionKey); put("organizationID", organizationID)
        expiresAt?.let { put("expiresAt", it.toEpochMilli() / 1000.0) }
    }

    companion object {
        fun fromJson(o: JSONObject) = ClaudeWebCredentials(
            o.getString("sessionKey"), o.getString("organizationID"),
            o.optDoubleOrNull("expiresAt")?.let(::epochToInstant),
        )

        /** Only a secure, unambiguous, first-party `sessionKey` cookie is ever shared with background work. */
        fun capture(cookies: List<WebCookie>, organizationID: String, now: Instant = Instant.now()): ClaudeWebCredentials {
            val matches = cookies.filter {
                it.name == "sessionKey" && it.domain.lowercase() in setOf("claude.ai", ".claude.ai") &&
                    it.path == "/" && it.secure && (it.expires?.isAfter(now) ?: true)
            }
            val cookie = matches.firstOrNull() ?: throw ClaudeQuotaError.SignIn
            if (matches.map { it.value }.toSet().size != 1) throw ClaudeQuotaError.SignIn
            val credentials = ClaudeWebCredentials(cookie.value, organizationID, cookie.expires)
            credentials.validate(now)
            return credentials
        }
    }
}

class ClaudeCredentialVault(private val store: SecretStore) {
    fun load(): ClaudeWebCredentials? = SharedQuotaAccess.transaction {
        store.load(NAME)?.let { ClaudeWebCredentials.fromJson(JSONObject(String(it))) }
    }

    fun save(credentials: ClaudeWebCredentials) {
        credentials.validate(Instant.now())
        SharedQuotaAccess.transaction { store.save(NAME, credentials.toJson().toString().toByteArray()) }
    }

    /** Compare-and-swap: a rotation that lost a race with sign-out or re-login must not resurrect a session. */
    fun replace(credentials: ClaudeWebCredentials, matching: ClaudeWebCredentials) {
        SharedQuotaAccess.transaction {
            if (load() != matching) throw kotlinx.coroutines.CancellationException("Credentials changed")
            save(credentials)
        }
    }

    fun delete() = SharedQuotaAccess.transaction { store.delete(NAME) }

    private companion object { const val NAME = "claude.web-session" }
}

sealed class ClaudeQuotaError : Exception(), LocalizedError {
    object SignIn : ClaudeQuotaError()
    object Cloudflare : ClaudeQuotaError()
    object InvalidResponse : ClaudeQuotaError()
    data class Http(val status: Int) : ClaudeQuotaError()

    override fun describe(c: Context): String = when (this) {
        SignIn -> c.getString(R.string.s_abre_la_sesion_de_claude_en_pulso_para_renov)
        Cloudflare -> c.getString(R.string.s_claude_pide_una_comprobacion_web_abre_su_ses)
        InvalidResponse -> c.getString(R.string.s_claude_ha_devuelto_una_respuesta_de_cuota_no)
        is Http -> c.getString(R.string.s_no_se_pudo_consultar_la_cuota_de_claude_http, status)
    }
}
