package com.kordar.ghostchat

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import dagger.hilt.android.AndroidEntryPoint

/**
 * Root Activity. FLAG_SECURE is enabled as early as possible so the screen is excluded
 * from recent-apps preview, screenshots, and screen-recording APIs. Scoped enforcement
 * in [SecurityMonitor] will keep the flag even if the system retries the window.
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        setContent {
            GhostChatTheme { BootPlaceholder() }
        }
    }
}

@Composable
fun GhostChatTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme()) { content() }
}

/**
 * Minimal root composable for Stage 1. Replaced by navigation graph in Stage 17.
 */
@Composable
private fun BootPlaceholder() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = stringResourceSafe(R.string.app_name, "Ghost Chat"),
            color = Color.White,
            style = MaterialTheme.typography.titleLarge
        )
    }
}

@Composable
private fun stringResourceSafe(id: Int, fallback: String): String =
    runCatching { androidx.compose.ui.res.stringResource(id) }.getOrDefault(fallback)
