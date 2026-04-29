package com.kordar.ghostchat.features.settings

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.models.AutoLockTimeout
import com.kordar.ghostchat.models.MessageTTL
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onOpenDashboard: () -> Unit,
    onOpenAbout: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val privacy by viewModel.settings.privacyMode.collectAsState()
    val biometric by viewModel.settings.biometricEnabled.collectAsState()
    val notifications by viewModel.settings.notificationsEnabled.collectAsState()
    val sound by viewModel.settings.soundEnabled.collectAsState()
    val ttl by viewModel.settings.messageTTL.collectAsState()
    val autoLock by viewModel.settings.autoLockTimeout.collectAsState()

    var confirmWipe by remember { mutableStateOf(false) }
    var languageExpanded by remember { mutableStateOf(false) }
    var ttlExpanded by remember { mutableStateOf(false) }
    var autoLockExpanded by remember { mutableStateOf(false) }
    var notificationsDenied by remember { mutableStateOf(false) }
    val ctx = LocalContext.current

    // Runtime POST_NOTIFICATIONS launcher (API 33+). On older APIs the system
    // grants the permission automatically, so the launcher result is always true.
    val notificationsPermissionLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            viewModel.settings.setNotificationsEnabled(true)
            android.util.Log.i("PushManager", "🔔 Notifications opt-in granted")
        } else {
            viewModel.settings.setNotificationsEnabled(false)
            notificationsDenied = true
            android.util.Log.i("PushManager", "🔔 Notifications opt-in denied")
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp)
    ) {
        // Privacy
        SettingRow(
            label = stringResource(R.string.settings_privacy_mode),
            description = stringResource(R.string.settings_privacy_mode_desc)
        ) {
            Switch(checked = privacy, onCheckedChange = { viewModel.settings.setPrivacyMode(it) })
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.06f))

        // Biometric
        SettingRow(
            label = stringResource(R.string.settings_biometric),
            description = stringResource(R.string.settings_biometric_desc)
        ) {
            Switch(checked = biometric, onCheckedChange = { viewModel.settings.setBiometricEnabled(it) })
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.06f))

        // Notifications opt-in (default OFF; tapping ON triggers POST_NOTIFICATIONS
        // runtime prompt on API 33+). If denied, toggle bounces back to OFF and we
        // surface a one-shot dialog pointing the user to system settings.
        SettingRow(
            label = stringResource(R.string.settings_notifications),
            description = stringResource(R.string.settings_notifications_desc)
        ) {
            Switch(
                checked = notifications,
                onCheckedChange = { newValue ->
                    if (newValue) {
                        if (android.os.Build.VERSION.SDK_INT >= 33) {
                            notificationsPermissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            viewModel.settings.setNotificationsEnabled(true)
                        }
                    } else {
                        viewModel.settings.setNotificationsEnabled(false)
                    }
                }
            )
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.06f))

        if (notificationsDenied) {
            AlertDialog(
                onDismissRequest = { notificationsDenied = false },
                title = { Text(stringResource(R.string.settings_notifications_denied_title)) },
                text = { Text(stringResource(R.string.settings_notifications_denied_message)) },
                confirmButton = {
                    TextButton(onClick = { notificationsDenied = false }) {
                        Text(stringResource(R.string.action_done))
                    }
                }
            )
        }

        // Security dashboard — independent section, NOT nested under biometric.
        NavigationRow(
            label = stringResource(R.string.settings_security_dashboard),
            description = stringResource(R.string.settings_security_dashboard_desc),
            onClick = onOpenDashboard
        )
        HorizontalDivider(color = Color.White.copy(alpha = 0.06f))

        // Auto-lock
        DropdownRow(
            label = stringResource(R.string.settings_auto_lock),
            description = stringResource(R.string.settings_auto_lock_desc),
            current = formatAutoLock(ctx, autoLock),
            expanded = autoLockExpanded,
            onToggleExpanded = { autoLockExpanded = it },
            options = AutoLockTimeout.values().map { it to formatAutoLock(ctx, it) },
            onSelect = { viewModel.settings.setAutoLockTimeout(it); autoLockExpanded = false }
        )

        // Message auto-delete
        DropdownRow(
            label = stringResource(R.string.settings_message_ttl),
            description = stringResource(R.string.settings_message_ttl_desc),
            current = ttlLabel(ttl),
            expanded = ttlExpanded,
            onToggleExpanded = { ttlExpanded = it },
            options = MessageTTL.values().map { it to ttlLabel(it) },
            onSelect = { viewModel.settings.setMessageTTL(it); ttlExpanded = false }
        )

        // Language
        Column {
            Text(
                stringResource(R.string.settings_language),
                color = Color.White,
                fontWeight = FontWeight.Medium
            )
            Spacer(Modifier.padding(2.dp))
            ExposedDropdownMenuBox(
                expanded = languageExpanded,
                onExpandedChange = { languageExpanded = !languageExpanded }
            ) {
                OutlinedTextField(
                    value = viewModel.localization.locale
                        .getDisplayLanguage(viewModel.localization.locale)
                        .replaceFirstChar { it.uppercase() },
                    onValueChange = {},
                    readOnly = true,
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = languageExpanded) },
                    colors = darkColors(),
                    modifier = Modifier
                        .menuAnchor(MenuAnchorType.PrimaryEditable, enabled = true)
                        .fillMaxWidth()
                )
                DropdownMenu(
                    expanded = languageExpanded,
                    onDismissRequest = { languageExpanded = false }
                ) {
                    listOf("en" to "English", "ru" to "Русский").forEach { (code, name) ->
                        DropdownMenuItem(
                            text = { Text(name) },
                            onClick = {
                                viewModel.localization.setOverride(Locale(code))
                                languageExpanded = false
                            }
                        )
                    }
                }
            }
        }

        // Sound
        SettingRow(
            label = stringResource(R.string.settings_sound),
            description = stringResource(R.string.settings_sound_desc)
        ) {
            Switch(checked = sound, onCheckedChange = { viewModel.settings.setSoundEnabled(it) })
        }

        HorizontalDivider(color = Color.White.copy(alpha = 0.1f))

        // Wipe — danger zone
        NavigationRow(
            label = stringResource(R.string.settings_wipe),
            description = stringResource(R.string.settings_wipe_desc),
            labelColor = Color(0xFFE53935),
            trailing = null,
            onClick = { confirmWipe = true }
        )

        HorizontalDivider(color = Color.White.copy(alpha = 0.06f))

        // About
        NavigationRow(
            label = stringResource(R.string.settings_about),
            description = null,
            onClick = onOpenAbout
        )
    }

    if (confirmWipe) {
        AlertDialog(
            onDismissRequest = { confirmWipe = false },
            title = { Text(stringResource(R.string.settings_wipe)) },
            text  = { Text(stringResource(R.string.settings_wipe_desc)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.contacts.panicWipe(ctx)
                    confirmWipe = false
                }) { Text(stringResource(R.string.settings_wipe), color = Color(0xFFE53935)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmWipe = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            }
        )
    }
}

/** Two-line row: primary label on top, gray description below, trailing content slot. */
@Composable
private fun SettingRow(
    label: String,
    description: String?,
    labelColor: Color = Color.White,
    trailing: @Composable () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(label, color = labelColor, fontWeight = FontWeight.Medium)
            if (description != null) {
                Text(
                    description,
                    color = Color.Gray,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
        }
        trailing()
    }
}

/** Row with a right-chevron suffix that acts as a navigation entry point. */
@Composable
private fun NavigationRow(
    label: String,
    description: String?,
    labelColor: Color = Color.White,
    trailing: Any? = Unit,   // `null` hides the chevron (used by the wipe button).
    onClick: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(label, color = labelColor, fontWeight = FontWeight.Medium)
            if (description != null) {
                Text(
                    description,
                    color = Color.Gray,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
        }
        if (trailing != null) {
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = Color.Gray
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> DropdownRow(
    label: String,
    description: String?,
    current: String,
    expanded: Boolean,
    onToggleExpanded: (Boolean) -> Unit,
    options: List<Pair<T, String>>,
    onSelect: (T) -> Unit
) {
    Column {
        Text(label, color = Color.White, fontWeight = FontWeight.Medium)
        if (description != null) {
            Text(
                description,
                color = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 2.dp, bottom = 4.dp)
            )
        }
        ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = onToggleExpanded) {
            OutlinedTextField(
                value = current,
                onValueChange = {},
                readOnly = true,
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                colors = darkColors(),
                modifier = Modifier
                    .menuAnchor(MenuAnchorType.PrimaryEditable, enabled = true)
                    .fillMaxWidth()
            )
            DropdownMenu(expanded = expanded, onDismissRequest = { onToggleExpanded(false) }) {
                options.forEach { (value, displayName) ->
                    DropdownMenuItem(text = { Text(displayName) }, onClick = { onSelect(value) })
                }
            }
        }
    }
}

@Composable
private fun darkColors() = TextFieldDefaults.colors(
    focusedContainerColor = Color.White.copy(alpha = 0.08f),
    unfocusedContainerColor = Color.White.copy(alpha = 0.08f),
    focusedTextColor = Color.White,
    unfocusedTextColor = Color.White,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent
)

@Composable
private fun ttlLabel(ttl: MessageTTL): String = when (ttl) {
    MessageTTL.THIRTY_SECONDS  -> stringResource(R.string.ttl_thirty_seconds)
    MessageTTL.ONE_MINUTE      -> stringResource(R.string.ttl_one_minute)
    MessageTTL.FIVE_MINUTES    -> stringResource(R.string.ttl_five_minutes)
    MessageTTL.FIFTEEN_MINUTES -> stringResource(R.string.ttl_fifteen_minutes)
    MessageTTL.ONE_HOUR        -> stringResource(R.string.ttl_one_hour)
}

private fun formatAutoLock(context: Context, t: AutoLockTimeout): String = when (t.seconds) {
    0     -> "Immediate"
    in 1 until 60 -> "${t.seconds}s"
    60    -> "1m"
    in 61 until 3600 -> "${t.seconds / 60}m"
    else  -> "${t.seconds / 3600}h"
}
