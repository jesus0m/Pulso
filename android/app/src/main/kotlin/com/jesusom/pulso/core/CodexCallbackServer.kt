package com.jesusom.pulso.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException

/**
 * One-shot loopback receiver for the OAuth redirect. It accepts only the verified callback
 * and keeps waiting through unrelated or unverifiable requests.
 */
class CodexCallbackServer private constructor(
    private val socket: ServerSocket,
    private val state: String,
    private val successMessage: String,
    private val invalidMessage: String,
) {
    val redirect: String = "http://localhost:${socket.localPort}/auth/callback"
    private val result = CompletableDeferred<String>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        scope.launch {
            while (!socket.isClosed && !result.isCompleted) {
                val client = try { socket.accept() } catch (e: Exception) { break }
                launch { handle(client) }
            }
        }
    }

    suspend fun await(timeoutSeconds: Long = 180): String =
        withTimeoutOrNull(timeoutSeconds * 1000) { result.await() } ?: throw CodexAuthError.Timeout

    fun cancel() {
        runCatching { socket.close() }
        result.cancel()
        scope.cancel()
    }

    private fun handle(client: Socket) {
        client.use {
            it.soTimeout = 5_000
            val head = ByteArray(8192)
            var length = 0
            try {
                while (length < head.size) {
                    val n = it.getInputStream().read(head, length, head.size - length)
                    if (n < 0) break
                    length += n
                    if (String(head, 0, length, Charsets.ISO_8859_1).contains("\r\n\r\n")) break
                }
            } catch (_: SocketTimeoutException) { return }
            val request = String(head, 0, length, Charsets.ISO_8859_1)
            if (!request.contains("\r\n\r\n")) return
            val first = request.substringBefore("\r\n").split(" ")
            var verified = false
            var denied = false
            if (first.size == 3 && first[0] == "GET" && first[1].startsWith("/")) {
                val callback = "http://localhost:${socket.localPort}${first[1]}"
                try {
                    val code = CodexOAuth.authorizationCode(callback, redirect, state)
                    verified = true
                    result.complete(code)
                } catch (e: CodexAuthError.Denied) {
                    denied = true
                } catch (_: Exception) { /* Ignore unrelated requests; keep waiting for the real callback. */ }
            }
            val body = (if (verified) successMessage else invalidMessage).toByteArray()
            val status = if (verified) "200 OK" else "400 Bad Request"
            val header = "HTTP/1.1 $status\r\nContent-Type: text/plain; charset=utf-8\r\n" +
                "Content-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            runCatching { it.getOutputStream().apply { write(header.toByteArray()); write(body); flush() } }
            if (denied) result.completeExceptionally(CodexAuthError.Denied)
        }
    }

    companion object {
        fun start(state: String, successMessage: String, invalidMessage: String, ports: List<Int> = listOf(1455, 1457)): CodexCallbackServer {
            for (port in ports) {
                try {
                    val socket = ServerSocket(port, 8, InetAddress.getLoopbackAddress())
                    return CodexCallbackServer(socket, state, successMessage, invalidMessage)
                } catch (_: Exception) { continue }
            }
            throw CodexAuthError.Listener
        }
    }
}

