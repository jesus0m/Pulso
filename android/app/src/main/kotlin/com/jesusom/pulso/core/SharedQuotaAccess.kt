package com.jesusom.pulso.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The app, its widgets and background work share one process, so a process-wide lock
 * replaces the iOS cross-process file lock. Quota storage and OAuth rotation stay serialized.
 */
object SharedQuotaAccess {
    private val storageLock = Any()
    private val oauthLock = Mutex()

    fun <T> transaction(block: () -> T): T = synchronized(storageLock, block)

    /** Rotating refresh tokens must never be spent twice by concurrent consumers. */
    suspend fun <T> withOAuthLock(wait: Long? = null, block: suspend () -> T): T {
        if (wait == null) return oauthLock.withLock { block() }
        return withTimeoutOrNull(wait * 1000) {
            oauthLock.withLock { block() }
        } ?: throw kotlinx.coroutines.CancellationException("OAuth lock busy")
    }
}
