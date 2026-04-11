package com.ghost.chat.features.settings

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Backspace
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.ghost.chat.R
import com.ghost.chat.core.security.BiometricAuthService
import com.ghost.chat.ui.theme.*
import kotlinx.coroutines.launch

/// Lock screen overlay — PIN entry pad with optional biometric button
/// 4-6 digit PIN, auto-verifies at 4+ digits, shake animation on error
@Composable
fun LockScreen(onUnlocked: () -> Unit) {
    val context = LocalContext.current
    var enteredPin by remember { mutableStateOf("") }
    var isError by remember { mutableStateOf(false) }
    val shakeOffset = remember { Animatable(0f) }
    val coroutineScope = rememberCoroutineScope()
    val pinDigits = remember { BiometricAuthService.pinLength }

    val biometricAvailable = remember {
        BiometricAuthService.isEnabled &&
                BiometricAuthService.isAvailable(context)
    }

    fun authenticateBiometric() {
        val activity = context as? FragmentActivity ?: return
        BiometricAuthService.authenticate(
            activity = activity,
            title = context.getString(R.string.biometric_reason),
            subtitle = "",
            onSuccess = { onUnlocked() },
            onError = { /* user can retry or use PIN */ }
        )
    }

    fun onDigit(digit: String) {
        if (enteredPin.length >= pinDigits) return
        isError = false
        val newPin = enteredPin + digit
        enteredPin = newPin

        // Auto-verify at exact PIN length
        if (newPin.length == pinDigits) {
            if (BiometricAuthService.verifyPin(newPin)) {
                onUnlocked()
            } else {
                // Wrong PIN — shake and reset
                isError = true
                coroutineScope.launch {
                    shakeOffset.animateTo(
                        targetValue = 0f,
                        animationSpec = spring(dampingRatio = 0.3f, stiffness = 2000f),
                        initialVelocity = 1200f
                    )
                    enteredPin = ""
                    isError = false
                }
            }
        }
    }

    fun onBackspace() {
        if (enteredPin.isNotEmpty()) {
            enteredPin = enteredPin.dropLast(1)
            isError = false
        }
    }

    // Auto-prompt biometric on appear
    LaunchedEffect(Unit) {
        if (biometricAvailable) {
            authenticateBiometric()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxSize()
        ) {
            Spacer(modifier = Modifier.weight(0.8f))

            // Lock icon
            Icon(
                Icons.Default.Lock,
                contentDescription = null,
                tint = GhostWhite.copy(alpha = 0.6f),
                modifier = Modifier.size(48.dp)
            )

            Spacer(modifier = Modifier.height(16.dp))

            Text(
                stringResource(R.string.biometric_locked),
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                color = GhostWhite
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                stringResource(R.string.pin_enter),
                fontSize = 14.sp,
                color = GhostGray
            )

            Spacer(modifier = Modifier.height(32.dp))

            // PIN dot indicators with shake animation
            Row(
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.graphicsLayer {
                    translationX = shakeOffset.value
                }
            ) {
                repeat(pinDigits) { index ->
                    Box(
                        modifier = Modifier
                            .size(14.dp)
                            .clip(CircleShape)
                            .background(
                                when {
                                    isError -> GhostRed
                                    index < enteredPin.length -> GhostWhite
                                    else -> GhostGrayLight
                                }
                            )
                    )
                }
            }

            Spacer(modifier = Modifier.weight(0.5f))

            // Numeric keypad (3x4 grid)
            val buttons = listOf(
                listOf("1", "2", "3"),
                listOf("4", "5", "6"),
                listOf("7", "8", "9"),
                listOf("", "0", "⌫")
            )

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.padding(horizontal = 48.dp)
            ) {
                buttons.forEach { row ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(24.dp),
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        row.forEach { key ->
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .aspectRatio(1.3f),
                                contentAlignment = Alignment.Center
                            ) {
                                when (key) {
                                    "" -> {} // Empty space
                                    "⌫" -> {
                                        Box(
                                            modifier = Modifier
                                                .size(64.dp)
                                                .clip(CircleShape)
                                                .clickable { onBackspace() },
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Icon(
                                                Icons.Default.Backspace,
                                                contentDescription = "Delete",
                                                tint = GhostWhite,
                                                modifier = Modifier.size(24.dp)
                                            )
                                        }
                                    }
                                    else -> {
                                        Box(
                                            modifier = Modifier
                                                .size(64.dp)
                                                .clip(CircleShape)
                                                .background(GhostSurface)
                                                .clickable { onDigit(key) },
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Text(
                                                key,
                                                fontSize = 28.sp,
                                                fontWeight = FontWeight.Medium,
                                                color = GhostWhite
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Biometric button (only if biometric is enabled)
            if (biometricAvailable) {
                IconButton(
                    onClick = { authenticateBiometric() },
                    modifier = Modifier
                        .size(56.dp)
                        .clip(CircleShape)
                        .background(GhostSurface)
                ) {
                    Icon(
                        Icons.Default.Fingerprint,
                        contentDescription = "Biometric",
                        tint = GhostWhite,
                        modifier = Modifier.size(28.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(40.dp))
        }
    }
}
