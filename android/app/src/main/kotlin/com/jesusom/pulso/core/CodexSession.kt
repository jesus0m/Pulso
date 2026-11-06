package com.jesusom.pulso.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jesusom.pulso.R
import kotlinx.coroutines.CancellationException

/** Native OAuth session for Codex: PKCE through the system browser plus a loopback redirect. */
class CodexSession(
    private val appContext: Context,
    private val client: CodexOAuthClient = CodexOAuthClient(),
    private val vault: CodexCredentialVault,
) {
    var isSigningIn by mutableStateOf(false)
        private set
    var accountLabel by mutableStateOf<String?>(runCatching { vault.load()?.email }.getOrNull())
        private set

    private var server: CodexCallbackServer? = null
    private var generation = 0

    /** [openBrowser] hands the authorization URL to the system browser; false means it could not be opened. */
    suspend fun signIn(openBrowser: (String) -> Boolean) {
        if (isSigningIn) throw CancellationException("Sign-in already running")
        isSigningIn = true
        val version = generation
        try {
            val attempt = CodexOAuth.makeAttempt()
            val callback = CodexCallbackServer.start(
                attempt.state,
                appContext.getString(R.string.s_listo_puedes_volver_a_pulso),
                appContext.getString(R.string.s_solicitud_no_valida),
            )
            server = callback
            try {
                if (!openBrowser(CodexOAuth.authorizationUrl(callback.redirect, attempt))) throw CodexAuthError.Browser
                val code = callback.await()
                val credentials = client.exchange(code, callback.redirect, attempt.verifier)
                if (version != generation) throw CancellationException("Sign-in superseded")
                vault.save(credentials)
                generation += 1
                accountLabel = credentials.email
            } finally {
                callback.cancel()
                server = null
            }
        } finally {
            isSigningIn = false
        }
    }

    fun cancelSignIn() {
        server?.cancel()
    }

    suspend fun fetchUsage(): UsageSnapshot {
        val version = generation
        var credentials = vault.load() ?: throw CodexAuthError.SignIn
        var renewed = false
        if (credentials.needsRefresh(client.now()) && credentials.refreshToken != null) {
            credentials = refresh(credentials)
            renewed = true
        }
        val snapshot = try {
            client.fetchUsage(credentials)
        } catch (e: CodexAuthError.SignIn) {
            if (renewed || credentials.refreshToken == null) throw e
            credentials = refresh(credentials)
            client.fetchUsage(credentials)
        }
        if (version != generation) throw CancellationException("Session changed")
        accountLabel = credentials.email
        return snapshot
    }

    /** Rotation is serialized with background work: a spent refresh token is never reused. */
    private suspend fun refresh(credentials: CodexCredentials): CodexCredentials {
        val version = generation
        return SharedQuotaAccess.withOAuthLock {
            val current = vault.load()
            if (current == null || version != generation) throw CancellationException("Signed out")
            if (current != credentials) return@withOAuthLock current
            val updated = client.refresh(current)
            SharedQuotaAccess.transaction {
                if (version != generation || vault.load() != current) throw CancellationException("Session changed")
                vault.save(updated)
            }
            updated
        }
    }

    fun clearSession() {
        generation += 1
        server?.cancel()
        vault.delete()
        accountLabel = null
    }
}

