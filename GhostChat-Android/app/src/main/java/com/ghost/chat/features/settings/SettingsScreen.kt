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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.features.chat.ChatViewModel
import com.ghost.chat.ui.theme.*

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

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
    ) {
        // Header
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(GhostSurface)
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = GhostBlue)
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
                SettingsToggle(
                    title = stringResource(R.string.settings_biometric),
                    subtitle = stringResource(R.string.settings_biometric_desc),
                    checked = false, // BiometricAuthService state
                    onCheckedChange = { /* BiometricAuthService.toggle() */ }
                )
                SettingsToggle(
                    title = stringResource(R.string.settings_privacy_mode),
                    subtitle = stringResource(R.string.settings_privacy_mode_desc),
                    checked = viewModel.privacyMode,
                    onCheckedChange = {
                        viewModel.privacyMode = it
                        viewModel.saveSettings()
                    }
                )
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
                        selectedContainerColor = GhostBlue,
                        selectedLabelColor = GhostWhite,
                        containerColor = GhostSurfaceLight,
                        labelColor = GhostGray
                    )
                )
            }
        }
    }
}
