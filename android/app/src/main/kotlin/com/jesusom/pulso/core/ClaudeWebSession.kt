package com.jesusom.pulso.core

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Bitmap
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.jesusom.pulso.BuildConfig
import com.jesusom.pulso.R
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class ClaudeOrganization(val id: String, val name: String)

sealed class ClaudeSessionError : Exception(), LocalizedError {
    object SignIn : ClaudeSessionError()
    object Unsupported : ClaudeSessionError()
    object Unavailable : ClaudeSessionError()
    object Organization : ClaudeSessionError()

    override fun describe(c: Context): String = when (this) {
        SignIn -> c.getString(R.string.s_abre_la_sesion_de_claude_y_vuelve_a_consulta)
        Unsupported -> c.getString(R.string.s_claude_ha_devuelto_un_formato_de_cuota_no_co)
        Unavailable -> c.getString(R.string.s_no_se_ha_podido_consultar_claude_comprueba_l)
        Organization -> c.getString(R.string.s_selecciona_una_organizacion_de_claude_y_vuel)
    }
}

/**
 * The embedded browser session for claude.ai. A successful read exports only the `sessionKey` cookie
 * into the encrypted vault so widgets and background work can query Claude natively.
 */
class ClaudeWebSession(
    private val appContext: Context,
    private val prefs: PulsoPrefs,
    private val vault: ClaudeCredentialVault,
    private val nativeClient: ClaudeQuotaClient = ClaudeQuotaClient(),
    private val isForeground: () -> Boolean = {
        ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
    },
) {
    var address by mutableStateOf("claude.ai")
        private set
    var loading by mutableStateOf(false)
        private set
    var emailLoginNotice by mutableStateOf<String?>(null)
        private set
    var organizations by mutableStateOf<List<ClaudeOrganization>>(emptyList())
        private set
    var selectedOrganizationID by mutableStateOf<String?>(prefs.string(ORGANIZATION_KEY))
        private set

    /** Google refuses OAuth inside embedded browsers and renders a blank page instead. */
    val blockedLoginHost: String? get() = if (address == "accounts.google.com") address else null

    private val scope by lazy { CoroutineScope(Dispatchers.Main.immediate) }
    private var webViewInstance: WebView? = null
    private var contextWrapper: MutableContextWrapper? = null
    private var pendingLoad: CompletableDeferred<Unit>? = null
    private val pendingScripts = HashMap<String, CompletableDeferred<JSONObject>>()
    private var generation = 0
    private var fetching = false
    private var clearing = false
    private var pendingEmail: String? = null
    private var emailLoginJob: Job? = null

    init {
        runCatching {
            prefs.string(ORGANIZATIONS_KEY)?.let { text ->
                val array = JSONArray(text)
                organizations = (0 until array.length()).map { array.getJSONObject(it) }
                    .map { ClaudeOrganization(it.getString("id"), it.getString("name")) }
                    .filter { isUuid(it.id) }
            }
        }
    }

    /** The browser view; [host] is the activity context so keyboard and themes behave. */
    fun webView(host: Context): WebView {
        val view = webViewInstance ?: createWebView()
        contextWrapper?.baseContext = host
        return view
    }

    fun detach() {
        contextWrapper?.baseContext = appContext
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView(): WebView {
        val wrapper = MutableContextWrapper(appContext)
        val view = WebView(wrapper)
        contextWrapper = wrapper
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(view, "pulsoBridge", setOf("https://claude.ai")) { _, message: WebMessageCompat, sourceOrigin, _, _ ->
                if (sourceOrigin.toString() != "https://claude.ai") return@addWebMessageListener
                val payload = runCatching { JSONObject(message.data ?: "") }.getOrNull() ?: return@addWebMessageListener
                pendingScripts.remove(payload.optString("id"))?.complete(payload)
            }
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val scheme = request.url.scheme
                return !(scheme == "https" || scheme == "about")
            }

            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                emailLoginJob?.cancel()
                loading = true
                address = hostOf(url)
            }

            override fun onPageFinished(view: WebView, url: String?) {
                loading = false
                address = hostOf(url)
                pendingLoad?.complete(Unit)
                pendingLoad = null
                fillLoginEmail()
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!request.isForMainFrame) return
                loading = false
                pendingLoad?.completeExceptionally(ClaudeSessionError.Unavailable)
                pendingLoad = null
            }

            override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
                pendingLoad?.completeExceptionally(ClaudeSessionError.Unavailable)
                pendingLoad = null
                pendingScripts.values.forEach { it.completeExceptionally(ClaudeSessionError.Unavailable) }
                pendingScripts.clear()
                webViewInstance = null
                contextWrapper = null
                return true
            }
        }
        webViewInstance = view
        return view
    }

    private fun hostOf(url: String?): String = url?.let { runCatching { java.net.URI(it).host }.getOrNull() } ?: "claude.ai"

    private fun isUuid(text: String) = runCatching { UUID.fromString(text).toString().equals(text, true) }.getOrDefault(false)

    private val isClaudeOrigin: Boolean
        get() {
            val url = webViewInstance?.url ?: return false
            val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return false
            return uri.scheme == "https" && uri.host == "claude.ai" && (uri.port == -1 || uri.port == 443) && uri.userInfo == null
        }

    fun openLogin(email: String? = null) {
        if (clearing) return
        cancelEmailLogin()
        emailLoginNotice = null
        pendingEmail = email?.trim()
        (webViewInstance ?: createWebView()).loadUrl(USAGE_URL)
    }

    fun cancelEmailLogin() {
        emailLoginJob?.cancel()
        emailLoginJob = null
        pendingEmail = null
    }

    private fun fillLoginEmail() {
        val email = pendingEmail?.takeIf { it.isNotEmpty() } ?: return
        if (!isClaudeOrigin) return
        // Consume once before submitting: navigation must never trigger a second email.
        pendingEmail = null
        emailLoginJob = scope.launch {
            try {
                repeat(20) {
                    val result = runScript(EMAIL_LOGIN_SCRIPT, JSONObject().put("email", email), 5_000)?.optString("value")
                    if (result == "submitted") {
                        emailLoginNotice = appContext.getString(R.string.s_correo_completado_introduce_en_claude_ai_el)
                        return@launch
                    }
                    if (result != "waiting") throw BreakLoop()
                    delay(250)
                }
            } catch (e: BreakLoop) {
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
            emailLoginNotice = appContext.getString(R.string.s_si_el_correo_no_aparece_completalo_directame)
        }
    }

    private class BreakLoop : Exception()

    fun selectOrganization(id: String) {
        if (organizations.none { it.id == id }) throw ClaudeSessionError.Organization
        if (selectedOrganizationID == id) return
        generation += 1
        pendingLoad?.completeExceptionally(CancellationException())
        pendingLoad = null
        selectedOrganizationID = id
        prefs.put(ORGANIZATION_KEY, id)
    }

    private fun validateGeneration(expected: Int) {
        if (generation != expected || clearing) throw CancellationException("Claude session changed")
    }

    suspend fun fetchUsage(): UsageSnapshot {
        if (fetching || clearing) throw ClaudeSessionError.Unavailable
        fetching = true
        try {
            return fetchInternal()
        } finally {
            fetching = false
        }
    }

    private suspend fun fetchInternal(): UsageSnapshot {
        val currentGeneration = generation
        val native: ClaudeWebCredentials? = try { vault.load() } catch (e: Exception) {
            if (!isForeground()) throw e
            null
        }
        if (native != null && native.organizationID == selectedOrganizationID) {
            prefs.put("claudeNativeLastAttempt", System.currentTimeMillis())
            prefs.put("claudeNativeLastResult", "En curso")
            try {
                val reading = nativeClient.fetch(native)
                validateGeneration(currentGeneration)
                vault.replace(reading.credentials, native)
                prefs.put("claudeNativeLastResult", "Actualizado")
                return reading.snapshot
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                prefs.put("claudeNativeLastResult", "Error ${e.javaClass.simpleName}")
                val recoverable = e == ClaudeQuotaError.SignIn || e == ClaudeQuotaError.Cloudflare
                if (!recoverable || !isForeground()) throw e
            }
        }
        if (!isForeground()) throw ClaudeQuotaError.SignIn
        if (!isClaudeOrigin || webViewInstance?.progress?.let { it < 100 } == true) loadUsagePage()
        validateGeneration(currentGeneration)
        if (!isClaudeOrigin) throw ClaudeSessionError.SignIn

        val organizationData = read("/api/organizations", organizationsOnly = true)
        validateGeneration(currentGeneration)
        val raw = try {
            val array = JSONArray(String(organizationData))
            (0 until array.length()).map { array.getJSONObject(it) }.map { it.getString("uuid") to it.getString("name") }
        } catch (e: Exception) { throw ClaudeSessionError.Unsupported }
        if (raw.isEmpty() || !raw.all { isUuid(it.first) && it.second.isNotBlank() } || raw.map { it.first }.toSet().size != raw.size) {
            throw ClaudeSessionError.Unsupported
        }
        organizations = raw.map { ClaudeOrganization(it.first, it.second) }
        prefs.put(ORGANIZATIONS_KEY, JSONArray(organizations.map { JSONObject().put("id", it.id).put("name", it.name) }).toString())
        if (organizations.none { it.id == selectedOrganizationID }) {
            selectedOrganizationID = null
            prefs.remove(ORGANIZATION_KEY)
        }
        if (organizations.size == 1 && selectedOrganizationID == null) {
            selectedOrganizationID = organizations[0].id
            prefs.put(ORGANIZATION_KEY, selectedOrganizationID!!)
        }
        val organizationID = selectedOrganizationID ?: throw ClaudeSessionError.Organization
        // UUID validation above limits the path component; JS also URI-encodes it.
        val usageData = read("/api/organizations/$organizationID/usage")
        validateGeneration(currentGeneration)
        val snapshot = try { ClaudeUsageParser.parse(usageData) } catch (e: UsageError) { throw ClaudeSessionError.Unsupported }
        val cookies = sessionCookies()
        validateGeneration(currentGeneration)
        vault.save(ClaudeWebCredentials.capture(cookies, organizationID))
        return snapshot
    }

    /** The cookie store reports name and value only; it is queried for the first-party https origin. */
    private fun sessionCookies(): List<WebCookie> {
        val header = CookieManager.getInstance().getCookie("https://claude.ai") ?: return emptyList()
        return header.split(";").map { it.trim() }.mapNotNull {
            val pair = it.split("=", limit = 2)
            if (pair.size == 2) WebCookie(pair[0], pair[1], "claude.ai", "/", secure = true, expires = null) else null
        }
    }

    /** JavaScript returns quota JSON only; the session export uses the native cookie store. */
    private suspend fun read(path: String, organizationsOnly: Boolean = false): ByteArray {
        if (!isClaudeOrigin) throw ClaudeSessionError.SignIn
        val requestID = UUID.randomUUID().toString()
        val args = JSONObject().put("path", path).put("organizationsOnly", organizationsOnly).put("requestID", requestID)
        val result = try {
            runScript(READ_SCRIPT, args, 15_000, scriptID = requestID, abortOnTimeout = true)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) { throw ClaudeSessionError.Unavailable }
        val value = result?.optString("value")?.takeIf { it.isNotEmpty() } ?: throw ClaudeSessionError.Unavailable
        val obj = runCatching { JSONObject(value) }.getOrNull() ?: throw ClaudeSessionError.Unsupported
        val status = obj.optInt("status", -1)
        if (status == -1) throw ClaudeSessionError.Unsupported
        if (status == 401 || status == 403) throw ClaudeSessionError.SignIn
        if (status != 200) throw ClaudeSessionError.Unavailable
        val data = obj.opt("data")
        if (data !is JSONObject && data !is JSONArray) throw ClaudeSessionError.Unsupported
        return data.toString().toByteArray()
    }

    /**
     * Runs [body] as an async function in the page and waits for its result through the origin-restricted
     * message channel. Only claude.ai pages can reach the channel.
     */
    private suspend fun runScript(
        body: String, args: JSONObject, timeoutMs: Long,
        scriptID: String = UUID.randomUUID().toString(), abortOnTimeout: Boolean = false,
    ): JSONObject? {
        val view = webViewInstance ?: throw ClaudeSessionError.Unavailable
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) throw ClaudeSessionError.Unavailable
        val deferred = CompletableDeferred<JSONObject>()
        pendingScripts[scriptID] = deferred
        val wrapped = """
            (async () => {
              const args = ${args};
              const requestID = ${JSONObject.quote(scriptID)};
              try {
                const value = await (async () => { $body })();
                pulsoBridge.postMessage(JSON.stringify({id: requestID, value: value}));
              } catch (e) {
                pulsoBridge.postMessage(JSON.stringify({id: requestID, error: String(e)}));
              }
            })();
        """.trimIndent()
        view.evaluateJavascript(wrapped, null)
        try {
            val result = withTimeoutOrNull(timeoutMs) { deferred.await() }
            if (result == null && abortOnTimeout) {
                view.evaluateJavascript("globalThis.__pulsoQuotaRequests?.[${JSONObject.quote(scriptID)}]?.abort();", null)
            }
            if (result != null && result.has("error")) throw ClaudeSessionError.Unavailable
            return result
        } finally {
            pendingScripts.remove(scriptID)
        }
    }

    private suspend fun loadUsagePage() {
        if (pendingLoad != null) throw ClaudeSessionError.Unavailable
        val deferred = CompletableDeferred<Unit>()
        pendingLoad = deferred
        cancelEmailLogin()
        emailLoginNotice = null
        (webViewInstance ?: createWebView()).loadUrl(USAGE_URL)
        try {
            withTimeoutOrNull(25_000) { deferred.await() } ?: run {
                webViewInstance?.stopLoading()
                throw ClaudeSessionError.Unavailable
            }
        } finally {
            if (pendingLoad === deferred) pendingLoad = null
        }
    }

    fun cancelQuotaFetch() {
        if (!fetching) return
        generation += 1
        fetching = false
        pendingLoad?.completeExceptionally(CancellationException())
        pendingLoad = null
        pendingScripts.values.forEach { it.completeExceptionally(CancellationException()) }
        pendingScripts.clear()
    }

    suspend fun clearSession() {
        if (clearing) return
        clearing = true
        try {
            cancelEmailLogin()
            emailLoginNotice = null
            generation += 1
            pendingLoad?.completeExceptionally(CancellationException())
            pendingLoad = null
            pendingScripts.values.forEach { it.completeExceptionally(CancellationException()) }
            pendingScripts.clear()
            organizations = emptyList()
            selectedOrganizationID = null
            prefs.remove(ORGANIZATION_KEY, ORGANIZATIONS_KEY)
            webViewInstance?.apply {
                stopLoading()
                loadUrl("about:blank")
                clearHistory()
                clearCache(true)
            }
            WebStorage.getInstance().deleteAllData()
            val removed = CompletableDeferred<Unit>()
            CookieManager.getInstance().removeAllCookies { removed.complete(Unit) }
            removed.await()
            CookieManager.getInstance().flush()
        } finally {
            clearing = false
        }
    }

    companion object {
        private const val USAGE_URL = "https://claude.ai/settings/usage"
        private const val ORGANIZATION_KEY = "claudeSelectedOrganizationID"
        private const val ORGANIZATIONS_KEY = "claudeOrganizations"

        /** Errors that prove the stored Claude access is unusable, as opposed to a transient failure. */
        fun isAuthoritativeUsageFailure(error: Throwable): Boolean = when (error) {
            is ClaudeQuotaError -> error == ClaudeQuotaError.SignIn || error == ClaudeQuotaError.InvalidResponse
            is ClaudeSessionError -> error != ClaudeSessionError.Unavailable
            else -> false
        }

        const val EMAIL_LOGIN_SCRIPT = """
            if (location.origin !== 'https://claude.ai') return 'manual';
            const input = document.querySelector('input[type="email"]');
            if (!input) return 'waiting';
            const email = args.email;
            const form = input.closest('form');
            if (!form || input.disabled || input.readOnly ||
                new URL(form.action, location.href).origin !== location.origin ||
                form.querySelector('input[type="password"], input[type="checkbox"], input[type="radio"], input[autocomplete="one-time-code"]'))
              return 'manual';
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            setter.call(input, email);
            input.dispatchEvent(new Event('input', {bubbles:true}));
            input.dispatchEvent(new Event('change', {bubbles:true}));
            await new Promise(resolve => setTimeout(resolve, 100));
            if (!input.isConnected || input.value !== email || !form.checkValidity()) return 'manual';
            const submit = form.querySelector('button[type="submit"], input[type="submit"], button:not([type])');
            if (!submit || submit.disabled) return 'manual';
            form.requestSubmit(submit);
            return 'submitted';
        """

        const val READ_SCRIPT = """
            if (location.origin !== 'https://claude.ai') throw new Error('origin');
            const path = args.path;
            const organizationsOnly = args.organizationsOnly;
            const controller = new AbortController();
            const requests = globalThis.__pulsoQuotaRequests ??= {};
            requests[requestID] = controller;
            const timer = setTimeout(() => controller.abort(), 15000);
            try {
              const safePath = path.split('/').map(encodeURIComponent).join('/');
              const response = await fetch(safePath, {credentials:'include', redirect:'error', signal:controller.signal});
              if (!response.ok) return JSON.stringify({status:response.status});
              const payload = await response.json();
              if (organizationsOnly) {
                if (!Array.isArray(payload)) return JSON.stringify({status:200});
                return JSON.stringify({status:200, data:payload.map(item => ({uuid:item.uuid, name:item.name}))});
              }
              return JSON.stringify({status:200, data:payload});
            } finally {
              clearTimeout(timer);
              delete requests[requestID];
            }
        """
    }
}

