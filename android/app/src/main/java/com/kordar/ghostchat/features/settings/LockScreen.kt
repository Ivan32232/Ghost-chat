package com.kordar.ghostchat.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.core.security.BiometricAuthService

@Composable
fun LockScreen(
    onUnlocked: () -> Unit,
    onDecoy: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    var pin by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        if (viewModel.auth.biometricEnabled) {
            val ok = viewModel.auth.authenticateBiometric("Unlock Ghost Chat")
            if (ok) onUnlocked()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Spacer(Modifier.size(60.dp))
        Icon(Icons.Outlined.Lock, contentDescription = null, tint = Color.White, modifier = Modifier.size(48.dp))
        Text(stringResource(R.string.lock_unlock_biometric), color = Color.White, fontWeight = FontWeight.SemiBold)
        error?.let { Text(it, color = Color(0xFFE53935)) }

        Text(
            text = "●".repeat(pin.length) + "○".repeat((4 - pin.length).coerceAtLeast(0)),
            color = Color.White,
            fontSize = 24.sp
        )

        Keypad(
            onDigit = { d ->
                if (pin.length < 6) {
                    pin += d
                    if (pin.length >= 4) {
                        val result = viewModel.auth.authenticate(pin)
                        pin = ""
                        when (result) {
                            BiometricAuthService.AuthResult.Authenticated -> onUnlocked()
                            BiometricAuthService.AuthResult.AuthenticatedDecoy -> onDecoy()
                            BiometricAuthService.AuthResult.Invalid -> error = "Invalid PIN"
                            BiometricAuthService.AuthResult.Wiped   -> error = "All data wiped"
                        }
                    }
                }
            },
            onBackspace = { if (pin.isNotEmpty()) pin = pin.dropLast(1) }
        )
    }
}

@Composable
private fun Keypad(onDigit: (String) -> Unit, onBackspace: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        (0..2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                (1..3).forEach { col ->
                    val digit = (row * 3 + col).toString()
                    KeyButton(digit, onClick = { onDigit(digit) })
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.size(64.dp))
            KeyButton("0", onClick = { onDigit("0") })
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.05f)),
                contentAlignment = Alignment.Center
            ) {
                IconButton(onClick = onBackspace) {
                    Icon(Icons.AutoMirrored.Outlined.Backspace, contentDescription = "Backspace", tint = Color.White)
                }
            }
        }
    }
}

@Composable
private fun KeyButton(title: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(64.dp)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.05f)),
        contentAlignment = Alignment.Center
    ) {
        IconButton(onClick = onClick, modifier = Modifier.size(64.dp)) {
            Text(title, color = Color.White, fontSize = 24.sp)
        }
    }
}
