package com.ghost.chat.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.fragment.app.FragmentActivity
import com.ghost.chat.R
import com.ghost.chat.core.security.BiometricAuthService
import com.ghost.chat.features.chat.ChatViewModel
import com.ghost.chat.ui.theme.*
import androidx.compose.foundation.text.KeyboardOptions

@Composable
fun SettingsScreen(
    viewModel: ChatViewModel,
    onBack: () -> Unit,
    onLanguagePicker: () -> Unit,
    onSoundPicker: () -> Unit,
    onRingtonePicker: () -> Unit
) {
    var showDeleteContactsDialog by remember { mutableStateOf(false) }
    var showDestroyDialog by remember { mutableStateOf(false) }
    var showPinSetupDialog by remember { mutableStateOf(false) }
    var showRemovePinDialog by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    var biometricEnabled by remember { mutableStateOf(BiometricAuthService.isEnabled) }
    var pinSet by remember { mutableStateOf(BiometricAuthService.isPinSet) }
    val biometricAvailable = remember { activity != null && BiometricAuthService.isAvailable(context) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
    ) {
        // Header
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(GhostBlack)
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = GhostWhite)
            }
            Text(
                stringResource(R.string.settings_title),
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = GhostWhite
            )
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            // Language
            SettingsSection(stringResource(R.string.settings_language_section)) {
                SettingsRow(
                    title = stringResource(R.string.settings_language),
                    subtitle = stringResource(R.string.settings_language_current),
                    onClick = onLanguagePicker
                )
            }

            // Security
            SettingsSection(stringResource(R.string.settings_security_section)) {
                // PIN code management
                if (!pinSet) {
                    SettingsRow(
                        title = stringResource(R.string.settings_set_pin),
                        onClick = { showPinSetupDialog = true }
                    )
                } else {
                    SettingsRow(
                        title = stringResource(R.string.settings_change_pin),
                        onClick = { showPinSetupDialog = true }
                    )
                    SettingsRow(
                        title = stringResource(R.string.settings_remove_pin),
                        titleColor = GhostRed,
                        onClick = { showRemovePinDialog = true }
                    )
                }

                // Auto-lock timer — only when PIN is set
                if (pinSet) {
                    SettingsAutoLockPicker(
                        currentSeconds = BiometricAuthService.autoLockSeconds,
                        onSecondsChange = { BiometricAuthService.autoLockSeconds = it }
                    )
                }

                // Biometric toggle — only when PIN is set
                if (biometricAvailable && pinSet) {
                    SettingsToggle(
                        title = stringResource(R.string.settings_biometric),
                        subtitle = stringResource(R.string.settings_biometric_desc),
                        checked = biometricEnabled,
                        onCheckedChange = {
                            val act = activity ?: return@SettingsToggle
                            BiometricAuthService.toggle(
                                act,
                                context.getString(R.string.settings_biometric),
                                context.getString(R.string.biometric_reason),
                                onResult = { enabled -> biometricEnabled = enabled }
                            )
                        }
                    )
                }
                SettingsToggle(
                    title = stringResource(R.string.settings_screenshot_notify),
                    subtitle = stringResource(R.string.settings_screenshot_notify_desc),
                    checked = viewModel.screenshotNotifications,
                    onCheckedChange = {
                        viewModel.screenshotNotifications = it
                        viewModel.saveSettings()
                    }
                )
            }

            // Chat History
            SettingsSection(stringResource(R.string.settings_history)) {
                SettingsToggle(
                    title = stringResource(R.string.settings_save_history),
                    subtitle = stringResource(R.string.settings_history_footer),
                    checked = viewModel.saveMessageHistory,
                    onCheckedChange = {
                        viewModel.saveMessageHistory = it
                        viewModel.saveSettings()
                    }
                )

                // Saved Messages (Избранное)
                var showDisableSavedDialog by remember { mutableStateOf(false) }
                SettingsToggle(
                    title = stringResource(R.string.saved_title),
                    subtitle = stringResource(R.string.saved_hint),
                    checked = viewModel.savedMessagesEnabled,
                    onCheckedChange = {
                        if (it) {
                            viewModel.savedMessagesEnabled = true
                            viewModel.saveSettings()
                            onBack()
                            viewModel.openSavedMessages()
                        } else {
                            showDisableSavedDialog = true
                        }
                    }
                )
                if (showDisableSavedDialog) {
                    AlertDialog(
                        onDismissRequest = { showDisableSavedDialog = false },
                        title = { Text(stringResource(R.string.saved_disable_confirm)) },
                        confirmButton = {
                            TextButton(onClick = {
                                viewModel.disableSavedMessages()
                                showDisableSavedDialog = false
                            }) {
                                Text(stringResource(R.string.settings_delete), color = GhostRed)
                            }
                        },
                        dismissButton = {
                            TextButton(onClick = { showDisableSavedDialog = false }) {
                                Text(stringResource(R.string.settings_cancel))
                            }
                        }
                    )
                }

                if (viewModel.saveMessageHistory) {
                    var showDeleteHistoryDialog by remember { mutableStateOf(false) }
                    SettingsRow(
                        title = stringResource(R.string.settings_delete_all_history),
                        titleColor = GhostRed,
                        onClick = { showDeleteHistoryDialog = true }
                    )
                    if (showDeleteHistoryDialog) {
                        AlertDialog(
                            onDismissRequest = { showDeleteHistoryDialog = false },
                            title = { Text(stringResource(R.string.settings_delete_all_history)) },
                            confirmButton = {
                                TextButton(onClick = {
                                    com.ghost.chat.core.storage.MessageStore(
                                        com.ghost.chat.core.storage.DatabaseService.getInstance(context)
                                    ).deleteAll()
                                    showDeleteHistoryDialog = false
                                }) {
                                    Text(stringResource(R.string.settings_delete), color = GhostRed)
                                }
                            },
                            dismissButton = {
                                TextButton(onClick = { showDeleteHistoryDialog = false }) {
                                    Text(stringResource(R.string.settings_cancel))
                                }
                            }
                        )
                    }
                }
            }

            // Messages
            SettingsSection(stringResource(R.string.settings_messages_section)) {
                SettingsAutoDeletePicker(
                    currentMinutes = viewModel.autoDeleteMinutes,
                    onMinutesChange = {
                        viewModel.autoDeleteMinutes = it
                        viewModel.saveSettings()
                    }
                )
            }

            // Sounds
            SettingsSection(stringResource(R.string.settings_sounds_section)) {
                SettingsToggle(
                    title = stringResource(R.string.settings_sound),
                    checked = viewModel.messageSoundEnabled,
                    onCheckedChange = {
                        viewModel.messageSoundEnabled = it
                        viewModel.saveSettings()
                    }
                )
                SettingsToggle(
                    title = stringResource(R.string.settings_vibration),
                    checked = viewModel.vibrationEnabled,
                    onCheckedChange = {
                        viewModel.vibrationEnabled = it
                        viewModel.saveSettings()
                    }
                )
                SettingsRow(
                    title = stringResource(R.string.settings_ringtone),
                    subtitle = viewModel.ringtoneId,
                    onClick = onRingtonePicker
                )
                SettingsRow(
                    title = stringResource(R.string.settings_msg_sound),
                    subtitle = viewModel.messageSoundId,
                    onClick = onSoundPicker
                )
            }

            // Danger zone
            SettingsSection(stringResource(R.string.settings_danger_section)) {
                SettingsRow(
                    title = stringResource(R.string.settings_delete_contacts),
                    titleColor = GhostRed,
                    onClick = { showDeleteContactsDialog = true }
                )
                SettingsRow(
                    title = stringResource(R.string.settings_destroy_all),
                    titleColor = GhostRed,
                    onClick = { showDestroyDialog = true }
                )
            }
        }
    }

    // Dialogs
    if (showDeleteContactsDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteContactsDialog = false },
            title = { Text(stringResource(R.string.settings_delete_contacts), color = GhostWhite) },
            text = { Text(stringResource(R.string.settings_delete_contacts_confirm), color = GhostGray) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteAllContacts()
                    showDeleteContactsDialog = false
                }) { Text(stringResource(R.string.settings_delete), color = GhostRed) }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteContactsDialog = false }) {
                    Text(stringResource(R.string.settings_cancel), color = GhostGray)
                }
            },
            containerColor = GhostSurface
        )
    }

    if (showDestroyDialog) {
        AlertDialog(
            onDismissRequest = { showDestroyDialog = false },
            title = { Text(stringResource(R.string.settings_destroy_all), color = GhostWhite) },
            text = { Text(stringResource(R.string.settings_destroy_all_confirm), color = GhostGray) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.destroyAllData()
                    showDestroyDialog = false
                }) { Text(stringResource(R.string.settings_destroy), color = GhostRed) }
            },
            dismissButton = {
                TextButton(onClick = { showDestroyDialog = false }) {
                    Text(stringResource(R.string.settings_cancel), color = GhostGray)
                }
            },
            containerColor = GhostSurface
        )
    }

    // PIN setup dialog
    if (showPinSetupDialog) {
        PinSetupDialog(
            isChange = pinSet,
            onConfirm = { newPin ->
                BiometricAuthService.setPin(newPin)
                pinSet = true
                showPinSetupDialog = false
            },
            onDismiss = { showPinSetupDialog = false }
        )
    }

    // Remove PIN confirmation
    if (showRemovePinDialog) {
        AlertDialog(
            onDismissRequest = { showRemovePinDialog = false },
            title = { Text(stringResource(R.string.settings_remove_pin), color = GhostWhite) },
            text = { Text(stringResource(R.string.settings_remove_pin_confirm), color = GhostGray) },
            confirmButton = {
                TextButton(onClick = {
                    BiometricAuthService.removePin()
                    pinSet = false
                    biometricEnabled = false
                    showRemovePinDialog = false
                }) { Text(stringResource(R.string.settings_delete), color = GhostRed) }
            },
            dismissButton = {
                TextButton(onClick = { showRemovePinDialog = false }) {
                    Text(stringResource(R.string.settings_cancel), color = GhostGray)
                }
            },
            containerColor = GhostSurface
        )
    }
}

@Composable
private fun PinSetupDialog(
    isChange: Boolean,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var pin by remember { mutableStateOf("") }
    var confirmPin by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var selectedLength by remember { mutableIntStateOf(BiometricAuthService.pinLength) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                if (isChange) stringResource(R.string.settings_change_pin)
                else stringResource(R.string.settings_set_pin),
                color = GhostWhite
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // PIN length picker
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    listOf(4, 6).forEach { len ->
                        FilterChip(
                            selected = selectedLength == len,
                            onClick = {
                                selectedLength = len
                                pin = ""
                                confirmPin = ""
                                error = null
                            },
                            label = { Text("$len ${stringResource(R.string.pin_digits)}") },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = GhostAccent,
                                selectedLabelColor = GhostWhite,
                                containerColor = GhostSurfaceLight,
                                labelColor = GhostGray
                            )
                        )
                    }
                }

                OutlinedTextField(
                    value = pin,
                    onValueChange = {
                        if (it.length <= selectedLength && it.all { c -> c.isDigit() }) {
                            pin = it
                            error = null
                        }
                    },
                    label = { Text(stringResource(R.string.pin_enter), color = GhostGray) },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = GhostAccent,
                        unfocusedBorderColor = GhostGrayLight,
                        focusedTextColor = GhostWhite,
                        unfocusedTextColor = GhostWhite,
                        cursorColor = GhostAccent,
                        focusedLabelColor = GhostAccent,
                        unfocusedLabelColor = GhostGray
                    ),
                    singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = androidx.compose.ui.text.input.KeyboardType.NumberPassword
                    )
                )
                OutlinedTextField(
                    value = confirmPin,
                    onValueChange = {
                        if (it.length <= selectedLength && it.all { c -> c.isDigit() }) {
                            confirmPin = it
                            error = null
                        }
                    },
                    label = { Text(stringResource(R.string.pin_confirm), color = GhostGray) },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = GhostAccent,
                        unfocusedBorderColor = GhostGrayLight,
                        focusedTextColor = GhostWhite,
                        unfocusedTextColor = GhostWhite,
                        cursorColor = GhostAccent,
                        focusedLabelColor = GhostAccent,
                        unfocusedLabelColor = GhostGray
                    ),
                    singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = androidx.compose.ui.text.input.KeyboardType.NumberPassword
                    )
                )
                if (error != null) {
                    Text(error!!, color = GhostRed, fontSize = 12.sp)
                }
            }
        },
        confirmButton = {
            val errLength = stringResource(R.string.pin_length_error, selectedLength)
            val errMismatch = stringResource(R.string.pin_mismatch)
            TextButton(onClick = {
                when {
                    pin.length != selectedLength -> error = errLength
                    pin != confirmPin -> error = errMismatch
                    else -> {
                        BiometricAuthService.pinLength = selectedLength
                        onConfirm(pin)
                    }
                }
            }) {
                Text(stringResource(R.string.contacts_save), color = GhostAccent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.settings_cancel), color = GhostGray)
            }
        },
        containerColor = GhostSurface
    )
}

@Composable
private fun SettingsAutoLockPicker(
    currentSeconds: Int,
    onSecondsChange: (Int) -> Unit
) {
    val options = listOf(
        0 to stringResource(R.string.autolock_instant),
        15 to stringResource(R.string.autolock_15s),
        30 to stringResource(R.string.autolock_30s),
        60 to stringResource(R.string.autolock_1m),
        300 to stringResource(R.string.autolock_5m)
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp)
    ) {
        Text(
            stringResource(R.string.settings_autolock),
            fontSize = 15.sp,
            color = GhostWhite
        )
        Spacer(modifier = Modifier.height(8.dp))
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            options.forEach { (seconds, label) ->
                FilterChip(
                    selected = currentSeconds == seconds,
                    onClick = { onSecondsChange(seconds) },
                    label = { Text(label, fontSize = 11.sp) },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = GhostAccent,
                        selectedLabelColor = GhostWhite,
                        containerColor = GhostSurfaceLight,
                        labelColor = GhostGray
                    )
                )
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Text(
        title,
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        color = GhostGray,
        modifier = Modifier.padding(top = 16.dp, bottom = 4.dp)
    )
    Card(
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = GhostSurface)
    ) {
        Column(modifier = Modifier.fillMaxWidth(), content = content)
    }
}

@Composable
private fun SettingsRow(
    title: String,
    subtitle: String? = null,
    titleColor: androidx.compose.ui.graphics.Color = GhostWhite,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontSize = 15.sp, color = titleColor)
        if (subtitle != null) {
            Text(subtitle, fontSize = 14.sp, color = GhostGray)
        }
    }
}

@Composable
private fun SettingsToggle(
    title: String,
    subtitle: String? = null,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, color = GhostWhite)
            if (subtitle != null) {
                Text(subtitle, fontSize = 12.sp, color = GhostGray)
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = GhostGreen,
                checkedTrackColor = GhostGreen.copy(alpha = 0.3f),
                uncheckedThumbColor = GhostGray,
                uncheckedTrackColor = GhostGrayLight
            )
        )
    }
}

@Composable
private fun SettingsAutoDeletePicker(
    currentMinutes: Int,
    onMinutesChange: (Int) -> Unit
) {
    val options = listOf(1, 3, 5, 10, 30)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp)
    ) {
        Text(
            stringResource(R.string.settings_auto_delete),
            fontSize = 15.sp,
            color = GhostWhite
        )
        Spacer(modifier = Modifier.height(8.dp))
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            options.forEach { minutes ->
                FilterChip(
                    selected = currentMinutes == minutes,
                    onClick = { onMinutesChange(minutes) },
                    label = { Text("${minutes}m") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = GhostAccent,
                        selectedLabelColor = GhostWhite,
                        containerColor = GhostSurfaceLight,
                        labelColor = GhostGray
                    )
                )
            }
        }
    }
}
