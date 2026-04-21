package com.kordar.ghostchat.features.settings

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
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
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.models.AutoLockTimeout
import com.kordar.ghostchat.models.MessageTTL
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onOpenDashboard: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val privacy by viewModel.settings.privacyMode.collectAsState()
    val biometric by viewModel.settings.biometricEnabled.collectAsState()
    val sound by viewModel.settings.soundEnabled.collectAsState()
    val ttl by viewModel.settings.messageTTL.collectAsState()
    val autoLock by viewModel.settings.autoLockTimeout.collectAsState()

    var confirmWipe by remember { mutableStateOf(false) }
    var languageExpanded by remember { mutableStateOf(false) }
    var ttlExpanded by remember { mutableStateOf(false) }
    var autoLockExpanded by remember { mutableStateOf(false) }
    val ctx = LocalContext.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        SectionHeader(stringResource(R.string.settings_privacy_mode))
        ToggleRow(
            label = stringResource(R.string.settings_privacy_mode),
            checked = privacy,
            onChange = { viewModel.settings.setPrivacyMode(it) }
        )

        SectionHeader(stringResource(R.string.settings_biometric))
        ToggleRow(
            label = stringResource(R.string.settings_biometric),
            checked = biometric,
            onChange = { viewModel.settings.setBiometricEnabled(it) }
        )
        TextButton(onClick = onOpenDashboard) {
            Text(stringResource(R.string.settings_security_dashboard), color = Color.White)
        }

        SectionHeader(stringResource(R.string.settings_auto_lock))
        DropdownRow(
            label = stringResource(R.string.settings_auto_lock),
            current = formatAutoLock(ctx, autoLock),
            expanded = autoLockExpanded,
            onToggleExpanded = { autoLockExpanded = it },
            options = AutoLockTimeout.values().map { it to formatAutoLock(ctx, it) },
            onSelect = { viewModel.settings.setAutoLockTimeout(it); autoLockExpanded = false }
        )
        DropdownRow(
            label = stringResource(R.string.settings_message_ttl),
            current = ttlLabel(ttl),
            expanded = ttlExpanded,
            onToggleExpanded = { ttlExpanded = it },
            options = MessageTTL.values().map { it to ttlLabel(it) },
            onSelect = { viewModel.settings.setMessageTTL(it); ttlExpanded = false }
        )

        SectionHeader(stringResource(R.string.settings_language))
        ExposedDropdownMenuBox(
            expanded = languageExpanded,
            onExpandedChange = { languageExpanded = !languageExpanded }
        ) {
            OutlinedTextField(
                value = viewModel.localization.locale.getDisplayLanguage(viewModel.localization.locale).replaceFirstChar { it.uppercase() },
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

        ToggleRow(
            label = stringResource(R.string.settings_sound),
            checked = sound,
            onChange = { viewModel.settings.setSoundEnabled(it) }
        )

        HorizontalDivider(color = Color.White.copy(alpha = 0.1f))

        TextButton(onClick = { confirmWipe = true }) {
            Text(stringResource(R.string.settings_wipe), color = Color(0xFFE53935), fontWeight = FontWeight.SemiBold)
        }
    }

    if (confirmWipe) {
        AlertDialog(
            onDismissRequest = { confirmWipe = false },
            title = { Text(stringResource(R.string.settings_wipe)) },
            text = { Text("This erases every contact, message, and key. It cannot be undone.") },
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

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text.uppercase(),
        color = Color.Gray,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(top = 8.dp)
    )
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        Text(label, color = Color.White, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> DropdownRow(
    label: String,
    current: String,
    expanded: Boolean,
    onToggleExpanded: (Boolean) -> Unit,
    options: List<Pair<T, String>>,
    onSelect: (T) -> Unit
) {
    Column {
        Text(label, color = Color.Gray)
        Spacer(Modifier.padding(2.dp))
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
