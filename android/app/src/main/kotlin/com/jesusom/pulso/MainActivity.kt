package com.jesusom.pulso

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.jesusom.pulso.ui.PulsoRoot
import com.jesusom.pulso.ui.PulsoTheme
import kotlinx.coroutines.CompletableDeferred

class MainActivity : ComponentActivity() {
    private var permissionResult: CompletableDeferred<Boolean>? = null
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        permissionResult?.complete(it)
    }
    private var showConnections by mutableStateOf(false)

    private val services get() = (application as PulsoApplication).services

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Pulso is always dark, so system bar icons must always be light, whatever the system theme.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        services.notificationPermission = ::requestNotificationPermission
        handle(intent)
        setContent {
            PulsoTheme {
                PulsoRoot(
                    store = services.store, services = services,
                    showConnections = showConnections, onShowConnections = { showConnections = it },
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** pulso://dashboard opens the dashboard; any other pulso:// link opens connections. */
    private fun handle(intent: Intent) {
        intent.data?.takeIf { it.scheme == "pulso" }?.let { showConnections = it.host != "dashboard" }
        // Development controls exist only in Debug builds; Release ignores them entirely.
        if (BuildConfig.DEBUG) {
            if (intent.getBooleanExtra("reset-preferences", false)) services.store.resetDevelopmentPreferences()
            if (intent.getBooleanExtra("demo", false)) services.store.changeDemo(true)
        }
    }

    private suspend fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return true
        val result = CompletableDeferred<Boolean>()
        permissionResult = result
        permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        return result.await()
    }

    override fun onDestroy() {
        if (isFinishing) services.store.claude.detach()
        super.onDestroy()
    }
}
