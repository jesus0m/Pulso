package com.jesusom.pulso.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class HttpRequest(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null,
    val timeoutMs: Int = 20_000,
)

class HttpResponse(
    val status: Int,
    /** Header names are lower-cased. */
    val headers: Map<String, List<String>>,
    val body: ByteArray,
    val url: String,
) {
    fun header(name: String): String? = headers[name.lowercase()]?.firstOrNull()
}

/** Seam for tests; production code uses [UrlConnectionTransport]. */
fun interface HttpTransport {
    suspend fun execute(request: HttpRequest): HttpResponse
}

/** Never follows redirects, stores no cookies and caches nothing: provider sessions stay explicit. */
object UrlConnectionTransport : HttpTransport {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override suspend fun execute(request: HttpRequest): HttpResponse = suspendCancellableCoroutine { continuation ->
        val connection = URL(request.url).openConnection() as HttpURLConnection
        // A blocked read is only interruptible by closing the connection.
        continuation.invokeOnCancellation { connection.disconnect() }
        scope.launch {
            try {
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.connectTimeout = request.timeoutMs
                connection.readTimeout = request.timeoutMs
                connection.requestMethod = request.method
                request.headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
                request.body?.let {
                    connection.doOutput = true
                    connection.outputStream.use { out -> out.write(it) }
                }
                val status = connection.responseCode
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                val body = stream?.use { it.readBytes() } ?: ByteArray(0)
                val headers = connection.headerFields.entries
                    .filter { it.key != null }
                    .associate { it.key.lowercase() to it.value.toList() }
                if (continuation.isActive) continuation.resume(HttpResponse(status, headers, body, connection.url.toString()))
            } catch (e: Exception) {
                if (continuation.isActive) continuation.resumeWithException(e)
            } finally {
                connection.disconnect()
            }
        }
    }
}
