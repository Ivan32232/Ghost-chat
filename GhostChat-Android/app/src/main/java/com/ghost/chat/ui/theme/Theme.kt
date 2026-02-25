package com.ghost.chat.ui.theme

import android.app.Activity
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val DarkColorScheme = darkColorScheme(
    primary = GhostBlue,
    secondary = GhostGreen,
    tertiary = GhostPurple,
    background = GhostBlack,
    surface = GhostSurface,
    surfaceVariant = GhostSurfaceLight,
    onPrimary = GhostWhite,
    onSecondary = GhostWhite,
    onTertiary = GhostWhite,
    onBackground = GhostWhite,
    onSurface = GhostWhite,
    onSurfaceVariant = GhostGray,
    error = GhostRed,
    outline = GhostGrayLight
)

@Composable
fun GhostChatTheme(content: @Composable () -> Unit) {
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = GhostBlack.toArgb()
            window.navigationBarColor = GhostBlack.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = false
        }
    }

    MaterialTheme(
        colorScheme = DarkColorScheme,
        typography = Typography,
        content = content
    )
}
