package com.ghost.chat.features.contacts

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.models.Contact
import com.ghost.chat.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Locale

@Composable
fun ContactDetailScreen(
    contact: Contact,
    viewModel: ContactsViewModel,
    onBack: () -> Unit,
    onStartChat: (Contact) -> Unit
) {
    var currentContact by remember { mutableStateOf(contact) }
    var isEditing by remember { mutableStateOf(false) }
    var editedName by remember { mutableStateOf(contact.label) }
    var notesText by remember { mutableStateOf(contact.notes ?: "") }
    var showDeleteConfirmation by remember { mutableStateOf(false) }
    val dateFormat = remember { SimpleDateFormat("dd.MM.yyyy", Locale.getDefault()) }

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
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = GhostWhite)
            }
            Text(
                stringResource(R.string.contacts_title),
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = GhostWhite
            )
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Avatar + Name
            item {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Spacer(modifier = Modifier.height(16.dp))

                    Box(
                        modifier = Modifier
                            .size(80.dp)
                            .clip(CircleShape)
                            .background(avatarColor(currentContact.identityKey)),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = currentContact.label.take(1).uppercase(),
                            fontSize = 32.sp,
                            fontWeight = FontWeight.Bold,
                            color = GhostWhite
                        )
                    }

                    Spacer(modifier = Modifier.height(12.dp))

                    if (isEditing) {
                        OutlinedTextField(
                            value = editedName,
                            onValueChange = { editedName = it },
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = GhostAccent,
                                unfocusedBorderColor = GhostGrayLight,
                                focusedTextColor = GhostWhite,
                                unfocusedTextColor = GhostWhite,
                                cursorColor = GhostAccent
                            ),
                            singleLine = true,
                            modifier = Modifier.width(200.dp)
                        )
                    } else {
                        Text(
                            text = currentContact.label,
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            color = GhostWhite
                        )
                    }
                }
            }

            // Actions
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = GhostSurface)
                ) {
                    Column {
                        // Start Chat
                        TextButton(
                            onClick = { onStartChat(currentContact) },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Default.Chat, contentDescription = null, tint = GhostAccent)
                            Spacer(modifier = Modifier.width(12.dp))
                            Text(
                                stringResource(R.string.contacts_start_chat),
                                color = GhostAccent,
                                modifier = Modifier.weight(1f)
                            )
                        }

                        HorizontalDivider(color = GhostBlack.copy(alpha = 0.3f))

                        // Edit Name
                        TextButton(
                            onClick = {
                                if (isEditing) {
                                    if (editedName.isNotBlank()) {
                                        viewModel.updateLabel(currentContact, editedName)
                                        currentContact = currentContact.copy(label = editedName)
                                        isEditing = false
                                    }
                                } else {
                                    editedName = currentContact.label
                                    isEditing = true
                                }
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(
                                if (isEditing) Icons.Default.Check else Icons.Default.Edit,
                                contentDescription = null,
                                tint = GhostAccent
                            )
                            Spacer(modifier = Modifier.width(12.dp))
                            Text(
                                if (isEditing) stringResource(R.string.contacts_save) else stringResource(R.string.contacts_edit),
                                color = GhostAccent,
                                modifier = Modifier.weight(1f)
                            )
                        }

                    }
                }
            }

            // Notes section
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = GhostSurface)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            stringResource(R.string.contacts_notes),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = GhostGray,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                        OutlinedTextField(
                            value = notesText,
                            onValueChange = {
                                val limited = it.take(999)
                                notesText = limited
                                viewModel.updateNotes(currentContact, limited.ifBlank { null })
                            },
                            placeholder = { Text(stringResource(R.string.contacts_notes_placeholder), color = GhostGray.copy(alpha = 0.5f)) },
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 80.dp),
                            shape = RoundedCornerShape(12.dp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = GhostGrayLight,
                                unfocusedBorderColor = GhostGrayLight,
                                focusedTextColor = GhostWhite,
                                unfocusedTextColor = GhostWhite,
                                cursorColor = GhostAccent
                            ),
                            maxLines = 6
                        )
                    }
                }
            }

            // Message TTL section
            item {
                val ttlOptions = listOf(
                    0 to stringResource(R.string.contacts_ttl_off),
                    3600 to stringResource(R.string.contacts_ttl_1h),
                    86400 to stringResource(R.string.contacts_ttl_1d),
                    604800 to stringResource(R.string.contacts_ttl_7d),
                    2592000 to stringResource(R.string.contacts_ttl_30d)
                )
                var expanded by remember { mutableStateOf(false) }
                val currentTTL = currentContact.messageTTL ?: 0
                val currentLabel = ttlOptions.firstOrNull { it.first == currentTTL }?.second
                    ?: stringResource(R.string.contacts_ttl_off)

                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = GhostSurface)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            stringResource(R.string.contacts_ttl_header),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = GhostGray,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )

                        Box {
                            TextButton(
                                onClick = { expanded = true },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Icon(Icons.Default.Timer, contentDescription = null, tint = GhostAccent)
                                Spacer(modifier = Modifier.width(12.dp))
                                Text(
                                    stringResource(R.string.contacts_ttl),
                                    color = GhostWhite,
                                    modifier = Modifier.weight(1f)
                                )
                                Text(currentLabel, color = GhostGray)
                            }

                            DropdownMenu(
                                expanded = expanded,
                                onDismissRequest = { expanded = false }
                            ) {
                                ttlOptions.forEach { (value, label) ->
                                    DropdownMenuItem(
                                        text = { Text(label) },
                                        onClick = {
                                            val ttl: Int? = if (value == 0) null else value
                                            viewModel.updateMessageTTL(currentContact, ttl)
                                            currentContact = currentContact.copy(messageTTL = ttl)
                                            expanded = false
                                        }
                                    )
                                }
                            }
                        }

                        Text(
                            stringResource(R.string.contacts_ttl_footer),
                            fontSize = 11.sp,
                            color = GhostGray.copy(alpha = 0.7f),
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }
                }
            }

            // Details section
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = GhostSurface)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            stringResource(R.string.contacts_details),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = GhostGray,
                            modifier = Modifier.padding(bottom = 12.dp)
                        )

                        // Created
                        DetailRow(
                            icon = Icons.Default.CalendarMonth,
                            label = stringResource(R.string.contacts_created),
                            value = dateFormat.format(currentContact.createdAt)
                        )

                        HorizontalDivider(
                            color = GhostBlack.copy(alpha = 0.3f),
                            modifier = Modifier.padding(vertical = 8.dp)
                        )

                        // Sessions
                        DetailRow(
                            icon = Icons.Default.Repeat,
                            label = stringResource(R.string.contacts_sessions),
                            value = "${currentContact.sessionCount}"
                        )

                        HorizontalDivider(
                            color = GhostBlack.copy(alpha = 0.3f),
                            modifier = Modifier.padding(vertical = 8.dp)
                        )

                        // Key State
                        DetailRow(
                            icon = Icons.Default.Lock,
                            label = stringResource(R.string.contacts_key_state),
                            value = if (currentContact.ratchetState != null)
                                stringResource(R.string.contacts_key_state_saved)
                            else
                                stringResource(R.string.contacts_key_state_none),
                            valueColor = if (currentContact.ratchetState != null) GhostGreen else GhostGray
                        )
                    }
                }
            }

            // Delete
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = GhostSurface)
                ) {
                    TextButton(
                        onClick = { showDeleteConfirmation = true },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Delete, contentDescription = null, tint = GhostRed)
                        Spacer(modifier = Modifier.width(12.dp))
                        Text(
                            stringResource(R.string.contacts_delete),
                            color = GhostRed,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
        }
    }

    // Delete confirmation
    if (showDeleteConfirmation) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirmation = false },
            title = { Text(stringResource(R.string.contacts_delete), color = GhostWhite) },
            text = {
                Text(
                    stringResource(R.string.contacts_delete_confirm, currentContact.label),
                    color = GhostGray
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteContact(currentContact)
                    showDeleteConfirmation = false
                    onBack()
                }) { Text(stringResource(R.string.settings_delete), color = GhostRed) }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirmation = false }) {
                    Text(stringResource(R.string.settings_cancel), color = GhostGray)
                }
            },
            containerColor = GhostSurface
        )
    }
}

@Composable
private fun DetailRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String,
    valueColor: androidx.compose.ui.graphics.Color = GhostGray,
    isMonospaced: Boolean = false
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = GhostGray, modifier = Modifier.size(18.dp))
        Spacer(modifier = Modifier.width(8.dp))
        Text(label, fontSize = 14.sp, color = GhostWhite)
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = value,
            fontSize = if (isMonospaced) 12.sp else 14.sp,
            color = valueColor,
            fontFamily = if (isMonospaced) FontFamily.Monospace else FontFamily.Default
        )
    }
}

