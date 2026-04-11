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
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
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

@Composable
fun ContactsScreen(
    viewModel: ContactsViewModel,
    onBack: () -> Unit,
    onStartChat: (Contact) -> Unit
) {
    var selectedContact by remember { mutableStateOf<Contact?>(null) }

    LaunchedEffect(Unit) { viewModel.loadContacts() }

    // Navigation: detail or list
    val contact = selectedContact
    if (contact != null) {
        ContactDetailScreen(
            contact = contact,
            viewModel = viewModel,
            onBack = {
                viewModel.loadContacts()
                selectedContact = null
            },
            onStartChat = onStartChat
        )
    } else {
        ContactsListScreen(
            viewModel = viewModel,
            onBack = onBack,
            onContactClick = { selectedContact = it }
        )
    }
}

@Composable
private fun ContactsListScreen(
    viewModel: ContactsViewModel,
    onBack: () -> Unit,
    onContactClick: (Contact) -> Unit
) {
    var searchText by remember { mutableStateOf("") }
    val filteredContacts = remember(viewModel.contacts.toList(), searchText) {
        if (searchText.isBlank()) viewModel.contacts.toList()
        else viewModel.contacts.filter { it.label.contains(searchText, ignoreCase = true) }
    }

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

        // Search bar
        if (viewModel.contacts.isNotEmpty()) {
            OutlinedTextField(
                value = searchText,
                onValueChange = { searchText = it },
                placeholder = { Text(stringResource(R.string.contacts_search), color = GhostGray) },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = GhostGray) },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                shape = RoundedCornerShape(12.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = GhostGrayLight,
                    unfocusedBorderColor = GhostGrayLight,
                    focusedTextColor = GhostWhite,
                    unfocusedTextColor = GhostWhite,
                    cursorColor = GhostAccent
                ),
                singleLine = true
            )
        }

        if (viewModel.contacts.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        Icons.Default.Person,
                        contentDescription = null,
                        tint = GhostGray.copy(alpha = 0.4f),
                        modifier = Modifier.size(56.dp)
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(
                        stringResource(R.string.contacts_empty),
                        color = GhostGray,
                        fontSize = 16.sp
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        stringResource(R.string.contacts_empty_hint),
                        color = GhostGray.copy(alpha = 0.6f),
                        fontSize = 12.sp
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(filteredContacts, key = { it.id }) { contact ->
                    ContactRow(
                        contact = contact,
                        onClick = { onContactClick(contact) }
                    )
                }
            }
        }
    }
}

@Composable
private fun ContactRow(
    contact: Contact,
    onClick: () -> Unit
) {
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
            // Colored avatar from identity key hash
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(avatarColor(contact.identityKey)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = contact.label.take(1).uppercase(),
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = GhostWhite
                )
            }

            Spacer(modifier = Modifier.width(14.dp))

            // Info
            Column(modifier = Modifier.weight(1f)) {
                Text(contact.label, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = GhostWhite)
            }

            // Session count badge
            if (contact.sessionCount > 0) {
                Text(
                    text = "${contact.sessionCount}",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = GhostWhite.copy(alpha = 0.7f),
                    modifier = Modifier
                        .background(GhostSurfaceLight, RoundedCornerShape(50))
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
            }

            // Lock icon for saved keys
            if (contact.ratchetState != null) {
                Icon(
                    Icons.Default.Lock,
                    contentDescription = null,
                    tint = GhostGreen.copy(alpha = 0.7f),
                    modifier = Modifier.size(16.dp)
                )
            }
        }
    }
}

