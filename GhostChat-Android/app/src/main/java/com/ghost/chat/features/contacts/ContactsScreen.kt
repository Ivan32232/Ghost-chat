package com.ghost.chat.features.contacts

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.models.Contact
import com.ghost.chat.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Locale

@Composable
fun ContactsScreen(
    viewModel: ContactsViewModel,
    onBack: () -> Unit,
    onStartChat: (Contact) -> Unit
) {
    var editingContact by remember { mutableStateOf<Contact?>(null) }
    var editName by remember { mutableStateOf("") }
    var deletingContact by remember { mutableStateOf<Contact?>(null) }

    LaunchedEffect(Unit) { viewModel.loadContacts() }

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
                stringResource(R.string.contacts_title),
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = GhostWhite
            )
        }

        if (viewModel.contacts.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    stringResource(R.string.contacts_empty),
                    color = GhostGray,
                    fontSize = 16.sp
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(viewModel.contacts, key = { it.id }) { contact ->
                    ContactRow(
                        contact = contact,
                        onClick = { onStartChat(contact) },
                        onEdit = {
                            editingContact = contact
                            editName = contact.label
                        },
                        onDelete = { deletingContact = contact }
                    )
                }
            }
        }
    }

    // Edit dialog
    editingContact?.let { contact ->
        AlertDialog(
            onDismissRequest = { editingContact = null },
            title = { Text(stringResource(R.string.contacts_edit), color = GhostWhite) },
            text = {
                OutlinedTextField(
                    value = editName,
                    onValueChange = { editName = it },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = GhostBlue,
                        unfocusedBorderColor = GhostGrayLight,
                        focusedTextColor = GhostWhite,
                        unfocusedTextColor = GhostWhite,
                        cursorColor = GhostBlue
                    ),
                    singleLine = true
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.updateLabel(contact, editName)
                    editingContact = null
                }) { Text(stringResource(R.string.contacts_save), color = GhostBlue) }
            },
            dismissButton = {
                TextButton(onClick = { editingContact = null }) {
                    Text(stringResource(R.string.settings_cancel), color = GhostGray)
                }
            },
            containerColor = GhostSurface
        )
    }

    // Delete dialog
    deletingContact?.let { contact ->
        AlertDialog(
            onDismissRequest = { deletingContact = null },
            title = { Text(stringResource(R.string.contacts_delete), color = GhostWhite) },
            text = { Text(stringResource(R.string.contacts_delete_confirm, contact.label), color = GhostGray) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteContact(contact)
                    deletingContact = null
                }) { Text(stringResource(R.string.settings_delete), color = GhostRed) }
            },
            dismissButton = {
                TextButton(onClick = { deletingContact = null }) {
                    Text(stringResource(R.string.settings_cancel), color = GhostGray)
                }
            },
            containerColor = GhostSurface
        )
    }
}

@Composable
private fun ContactRow(
    contact: Contact,
    onClick: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    val dateFormat = remember { SimpleDateFormat("dd.MM.yyyy", Locale.getDefault()) }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = GhostSurface)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Avatar
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(GhostSurfaceLight),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.Person, contentDescription = null, tint = GhostGray, modifier = Modifier.size(24.dp))
            }

            Spacer(modifier = Modifier.width(12.dp))

            // Info
            Column(modifier = Modifier.weight(1f)) {
                Text(contact.label, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = GhostWhite)
                val sessions = contact.sessionCount
                val lastDate = contact.lastSessionAt?.let { dateFormat.format(it) } ?: ""
                Text(
                    "$sessions sessions" + if (lastDate.isNotEmpty()) " · $lastDate" else "",
                    fontSize = 12.sp,
                    color = GhostGray
                )
            }

            // Actions
            IconButton(onClick = onEdit, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Default.Edit, contentDescription = "Edit", tint = GhostGray, modifier = Modifier.size(18.dp))
            }
            IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Default.Delete, contentDescription = "Delete", tint = GhostRed, modifier = Modifier.size(18.dp))
            }
        }
    }
}
