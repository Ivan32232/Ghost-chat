package com.ghost.chat.features.welcome

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.models.ChatMessage
import com.ghost.chat.models.Contact
import com.ghost.chat.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Locale
import kotlin.math.abs

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WelcomeScreen(
    privacyMode: Boolean,
    onPrivacyModeChange: (Boolean) -> Unit,
    onCreateRoom: () -> Unit,
    onJoinRoom: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenContacts: () -> Unit,
    contacts: List<Contact> = emptyList(),
    lastMessages: Map<String, ChatMessage> = emptyMap(),
    unreadCounts: Map<String, Int> = emptyMap(),
    onContactClick: ((Contact) -> Unit)? = null,
    onDeleteContact: ((Contact) -> Unit)? = null,
    onOpenSavedMessages: (() -> Unit)? = null,
    savedMessagesLastMessage: ChatMessage? = null
) {
    var roomInput by remember { mutableStateOf("") }
    var showJoinField by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
    ) {
        // Top bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(GhostBlack.copy(alpha = 0.95f))
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Ghost",
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = GhostWhite
            )
            Spacer(modifier = Modifier.weight(1f))
            IconButton(onClick = onCreateRoom) {
                Icon(Icons.Default.Edit, contentDescription = "New Chat", tint = GhostWhite)
            }
            IconButton(onClick = onOpenSettings) {
                Icon(Icons.Default.Settings, contentDescription = "Settings", tint = GhostGray)
            }
        }

        if (contacts.isEmpty() && onOpenSavedMessages == null) {
            // Classic welcome — no contacts yet
            ClassicWelcome(
                privacyMode = privacyMode,
                onPrivacyModeChange = onPrivacyModeChange,
                onCreateRoom = onCreateRoom,
                onJoinRoom = onJoinRoom
            )
        } else {
            // Ghost Threads — contact list with previews
            LazyColumn(
                modifier = Modifier.weight(1f)
            ) {
                // Saved Messages (pinned at top, only when enabled)
                if (onOpenSavedMessages != null) {
                    item(key = "saved-messages") {
                        SavedMessagesRow(
                            lastMessage = savedMessagesLastMessage,
                            onClick = { onOpenSavedMessages.invoke() }
                        )
                        HorizontalDivider(
                            modifier = Modifier.padding(start = 72.dp),
                            color = GhostGrayLight.copy(alpha = 0.2f)
                        )
                    }
                }

                items(contacts, key = { it.id }) { contact ->
                    val dismissState = rememberSwipeToDismissBoxState(
                        confirmValueChange = { value ->
                            if (value == SwipeToDismissBoxValue.EndToStart) {
                                onDeleteContact?.invoke(contact)
                                true
                            } else false
                        }
                    )
                    SwipeToDismissBox(
                        state = dismissState,
                        backgroundContent = {
                            Box(
                                modifier = Modifier
                                    .fillMaxSize()
                                    .background(MaterialTheme.colorScheme.error)
                                    .padding(horizontal = 20.dp),
                                contentAlignment = Alignment.CenterEnd
                            ) {
                                Icon(
                                    Icons.Default.Delete,
                                    contentDescription = "Delete",
                                    tint = GhostWhite
                                )
                            }
                        },
                        enableDismissFromStartToEnd = false,
                        enableDismissFromEndToStart = onDeleteContact != null
                    ) {
                        Column(modifier = Modifier.background(GhostBlack)) {
                            ThreadRow(
                                contact = contact,
                                lastMessage = lastMessages[contact.id],
                                unreadCount = unreadCounts[contact.id] ?: 0,
                                onClick = { onContactClick?.invoke(contact) }
                            )
                            HorizontalDivider(
                                modifier = Modifier.padding(start = 72.dp),
                                color = GhostGrayLight.copy(alpha = 0.2f)
                            )
                        }
                    }
                }
            }

            // Bottom bar
            Column(
                modifier = Modifier
                    .background(GhostBlack.copy(alpha = 0.95f))
                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                AnimatedVisibility(
                    visible = showJoinField,
                    enter = slideInVertically { it } + fadeIn(),
                    exit = slideOutVertically { it } + fadeOut()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        OutlinedTextField(
                            value = roomInput,
                            onValueChange = { roomInput = it },
                            placeholder = { Text(stringResource(R.string.welcome_enter_code), color = GhostGray) },
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(10.dp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = GhostGray,
                                unfocusedBorderColor = GhostGrayLight,
                                focusedTextColor = GhostWhite,
                                unfocusedTextColor = GhostWhite,
                                cursorColor = GhostAccent,
                                focusedContainerColor = GhostSurface,
                                unfocusedContainerColor = GhostSurface
                            ),
                            singleLine = true
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        IconButton(
                            onClick = { if (roomInput.isNotBlank()) onJoinRoom(roomInput) },
                            enabled = roomInput.isNotBlank()
                        ) {
                            Icon(
                                Icons.Default.Edit,
                                contentDescription = "Join",
                                tint = if (roomInput.isNotBlank()) GhostWhite else GhostGray
                            )
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(onClick = { showJoinField = !showJoinField }) {
                        Icon(Icons.Default.Tag, contentDescription = "Join by code", tint = GhostGray)
                    }
                    Spacer(modifier = Modifier.weight(1f))
                    IconButton(onClick = onOpenContacts) {
                        Icon(Icons.Default.People, contentDescription = "Contacts", tint = GhostGray)
                    }
                }
            }
        }
    }
}

@Composable
private fun ClassicWelcome(
    privacyMode: Boolean,
    onPrivacyModeChange: (Boolean) -> Unit,
    onCreateRoom: () -> Unit,
    onJoinRoom: (String) -> Unit
) {
    var roomInput by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(32.dp))

        Box(
            modifier = Modifier
                .size(80.dp)
                .clip(CircleShape)
                .background(GhostSurface),
            contentAlignment = Alignment.Center
        ) {
            Text("G", fontSize = 36.sp, fontWeight = FontWeight.Bold, color = GhostWhite)
        }

        Spacer(modifier = Modifier.height(16.dp))
        Text("Ghost", fontSize = 32.sp, fontWeight = FontWeight.Bold, color = GhostWhite)
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            stringResource(R.string.welcome_subtitle),
            fontSize = 14.sp, color = GhostGray, textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(40.dp))

        // Primary button — web style: light bg, dark text, rounded 14dp
        Button(
            onClick = onCreateRoom,
            modifier = Modifier.fillMaxWidth().height(54.dp),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = GhostAccent,
                contentColor = GhostBlack
            )
        ) {
            Text(stringResource(R.string.welcome_new_chat), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = Modifier.width(8.dp))
            Text("→", fontSize = 17.sp)
        }

        Spacer(modifier = Modifier.height(16.dp))

        OutlinedTextField(
            value = roomInput,
            onValueChange = { roomInput = it },
            placeholder = { Text(stringResource(R.string.welcome_enter_code), color = GhostGray) },
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = GhostGray,
                unfocusedBorderColor = GhostGrayLight,
                focusedTextColor = GhostWhite,
                unfocusedTextColor = GhostWhite,
                cursorColor = GhostAccent,
                focusedContainerColor = GhostSurface,
                unfocusedContainerColor = GhostSurface
            ),
            singleLine = true
        )

        Spacer(modifier = Modifier.height(12.dp))

        // Join button — web style: surface bg, border, white text
        Button(
            onClick = { onJoinRoom(roomInput) },
            modifier = Modifier.fillMaxWidth().height(50.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = GhostSurface,
                contentColor = GhostWhite
            ),
            enabled = roomInput.isNotBlank()
        ) {
            Text(stringResource(R.string.welcome_join), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }

        Spacer(modifier = Modifier.height(24.dp))
    }
}

@Composable
private fun ThreadRow(
    contact: Contact,
    lastMessage: ChatMessage?,
    unreadCount: Int,
    onClick: () -> Unit
) {
    val timeFormat = remember { SimpleDateFormat("HH:mm", Locale.getDefault()) }
    val avatarColors = listOf(
        GhostAccent.copy(alpha = 0.2f), GhostGreen.copy(alpha = 0.4f),
        GhostPurple.copy(alpha = 0.4f), GhostOrange.copy(alpha = 0.4f),
        GhostRed.copy(alpha = 0.4f), GhostCyan.copy(alpha = 0.4f)
    )
    val avatarColor = avatarColors[abs(contact.id.hashCode()) % avatarColors.size]

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Avatar
        Box(
            modifier = Modifier
                .size(50.dp)
                .clip(CircleShape)
                .background(avatarColor),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = contact.label.take(1).uppercase(),
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                color = GhostWhite
            )
        }

        Spacer(modifier = Modifier.width(14.dp))

        // Name + preview
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = contact.label,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                color = GhostWhite,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = lastMessage?.text ?: stringResource(R.string.contacts_no_messages),
                fontSize = 14.sp,
                color = if (lastMessage != null) GhostGray else GhostGray.copy(alpha = 0.5f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }

        Spacer(modifier = Modifier.width(8.dp))

        // Time + badge
        Column(horizontalAlignment = Alignment.End) {
            if (lastMessage != null) {
                Text(
                    text = timeFormat.format(lastMessage.timestamp),
                    fontSize = 11.sp,
                    color = GhostGray
                )
            }
            if (unreadCount > 0) {
                Spacer(modifier = Modifier.height(4.dp))
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(GhostGreen)
                        .padding(horizontal = 7.dp, vertical = 2.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "$unreadCount",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = GhostWhite
                    )
                }
            }
        }
    }
}

@Composable
private fun SavedMessagesRow(
    lastMessage: ChatMessage?,
    onClick: () -> Unit
) {
    val timeFormat = remember { SimpleDateFormat("HH:mm", Locale.getDefault()) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Bookmark avatar
        Box(
            modifier = Modifier
                .size(50.dp)
                .clip(CircleShape)
                .background(GhostPurple.copy(alpha = 0.4f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Default.Bookmark,
                contentDescription = null,
                tint = GhostWhite,
                modifier = Modifier.size(24.dp)
            )
        }

        Spacer(modifier = Modifier.width(14.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = stringResource(R.string.saved_title),
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                color = GhostWhite,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = lastMessage?.text ?: stringResource(R.string.saved_hint),
                fontSize = 14.sp,
                color = if (lastMessage != null) GhostGray else GhostGray.copy(alpha = 0.5f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }

        Spacer(modifier = Modifier.width(8.dp))

        if (lastMessage != null) {
            Text(
                text = timeFormat.format(lastMessage.timestamp),
                fontSize = 11.sp,
                color = GhostGray
            )
        }
    }
}
