package com.jesusom.pulso.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Pulso is always dark: an OLED-friendly black surface, as on iOS. */
@Composable
fun PulsoTheme(content: @Composable () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val dark = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = darkColorScheme(
            background = Color.Black, surface = Color.Black, onBackground = Color.White, onSurface = Color.White,
            primary = Color(0.55f, 0.94f, 0.77f), surfaceVariant = Color(0.11f, 0.11f, 0.12f),
            onSurfaceVariant = Color(0.62f, 0.64f, 0.66f), secondaryContainer = Color(0.16f, 0.17f, 0.18f),
            onSecondaryContainer = Color.White,
        ),
        content = content,
    )
}

val SecondaryText = Color(0.62f, 0.64f, 0.66f)
val WarningColor = Color(1f, 0.62f, 0.04f)
