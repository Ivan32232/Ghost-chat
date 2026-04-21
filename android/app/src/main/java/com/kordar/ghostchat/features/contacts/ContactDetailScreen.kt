package com.kordar.ghostchat.features.contacts

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.features.welcome.WelcomeViewModel
import com.kordar.ghostchat.models.Contact
import com.kordar.ghostchat.models.MessageTTL

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactDetailScreen(
    contactId: String,
    onBack: () -> Unit,
    viewModel: WelcomeViewModel = hiltViewModel()
) {
    val list by viewModel.contacts.contacts.collectAsState()
    val contact = list.firstOrNull { it.id == contactId }

    if (contact == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }

    var label by remember(contact.id) { mutableStateOf(contact.label) }
    var notes by remember(contact.id) { mutableStateOf(contact.notes ?: "") }
    var ttl by remember(contact.id) { mutableStateOf(MessageTTL.fromSeconds(contact.messageTTL)) }
    var ttlExpanded by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(horizontal = 16.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        LabelledField(label = stringResource(R.string.contacts_rename), value = label, onChange = { label = it })
        LabelledField(
            label = stringResource(R.string.contacts_notes),
            value = notes,
            onChange = { notes = it },
            multiline = true
        )

        Column {
            Text(stringResource(R.string.settings_message_ttl), color = Color.Gray)
            Spacer(Modifier.size(4.dp))
            ExposedDropdownMenuBox(
                expanded = ttlExpanded,
                onExpandedChange = { ttlExpanded = !ttlExpanded }
            ) {
                OutlinedTextField(
                    value = ttlResourceLabel(ttl),
                    onValueChange = {},
                    readOnly = true,
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = ttlExpanded) },
                    colors = darkTextFieldColors(),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier
                        .menuAnchor(MenuAnchorType.PrimaryEditable, enabled = true)
                        .fillMaxWidth()
                )
                DropdownMenu(
                    expanded = ttlExpanded,
                    onDismissRequest = { ttlExpanded = false }
                ) {
                    MessageTTL.values().forEach { value ->
                        DropdownMenuItem(
                            text = { Text(ttlResourceLabel(value)) },
                            onClick = { ttl = value; ttlExpanded = false }
                        )
                    }
                }
            }
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Button(
                onClick = {
                    val updated = contact.copy(
                        label = label,
                        notes = notes.ifBlank { null },
                        messageTTL = ttl.seconds
                    )
                    viewModel.contacts.save(updated)
                    onBack()
                },
                colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black),
                modifier = Modifier.weight(1f)
            ) { Text(stringResource(R.string.action_save)) }

            Button(
                onClick = { confirmDelete = true },
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE53935)),
                modifier = Modifier.weight(1f)
            ) { Text(stringResource(R.string.contacts_delete)) }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.contacts_delete)) },
            text = { Text("This permanently removes the contact and its messages.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.contacts.delete(contact.id)
                    confirmDelete = false
                    onBack()
                }) { Text(stringResource(R.string.contacts_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            }
        )
    }
}

@Composable
private fun LabelledField(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    multiline: Boolean = false
) {
    Column {
        Text(label, color = Color.Gray)
        Spacer(Modifier.size(4.dp))
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            colors = darkTextFieldColors(),
            shape = RoundedCornerShape(12.dp),
            singleLine = !multiline,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun darkTextFieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = Color.White.copy(alpha = 0.08f),
    unfocusedContainerColor = Color.White.copy(alpha = 0.08f),
    focusedTextColor = Color.White,
    unfocusedTextColor = Color.White,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent
)

@Composable
private fun ttlResourceLabel(ttl: MessageTTL): String = when (ttl) {
    MessageTTL.THIRTY_SECONDS  -> stringResource(R.string.ttl_thirty_seconds)
    MessageTTL.ONE_MINUTE      -> stringResource(R.string.ttl_one_minute)
    MessageTTL.FIVE_MINUTES    -> stringResource(R.string.ttl_five_minutes)
    MessageTTL.FIFTEEN_MINUTES -> stringResource(R.string.ttl_fifteen_minutes)
    MessageTTL.ONE_HOUR        -> stringResource(R.string.ttl_one_hour)
}

private fun Contact.copy(
    label: String = this.label,
    notes: String? = this.notes,
    messageTTL: Int = this.messageTTL
): Contact = Contact(
    id = id,
    label = label,
    identityKey = identityKey,
    publicKey = publicKey,
    previousKey = previousKey,
    fallbackKey = fallbackKey,
    pushToken = pushToken,
    notifyToken = notifyToken,
    ratchetState = ratchetState,
    rotationCounter = rotationCounter,
    sessionCount = sessionCount,
    messageTTL = messageTTL,
    notes = notes,
    isMuted = isMuted,
    createdAt = createdAt,
    lastSessionAt = lastSessionAt
)
