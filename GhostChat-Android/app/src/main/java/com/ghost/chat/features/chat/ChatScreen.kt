package com.ghost.chat.features.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.models.ChatMessage
import com.ghost.chat.ui.theme.*
import kotlinx.coroutines.launch

@Composable
fun ChatScreen(
    viewModel: ChatViewModel,
    onOpenSettings: () -> Unit,
    onLeave: () -> Unit
) {
    var messageText by remember { mutableStateOf("") }
    val listState = rememberLazyListState()
    val coroutineScope = rememberCoroutineScope()

    // Auto-scroll to bottom on new messages
    LaunchedEffect(viewModel.messages.size) {
        if (viewModel.messages.isNotEmpty()) {
            listState.animateScrollToItem(viewModel.messages.size - 1)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
    ) {
        // Header
        ChatHeader(
            fingerprint = viewModel.fingerprint,
            isVerified = viewModel.isVerified,
            contactName = viewModel.currentPeerContact?.label,
            onShieldClick = { viewModel.showVerificationPanel = !viewModel.showVerificationPanel },
            onCallClick = { viewModel.startCall() },
            onSettingsClick = onOpenSettings,
            onLeaveClick = onLeave
        )

        // Verification panel
        if (viewModel.showVerificationPanel) {
            VerificationPanel(
                fingerprint = viewModel.fingerprint,
                isVerified = viewModel.isVerified,
                onVerify = { viewModel.isVerified = true },
                onDismiss = { viewModel.showVerificationPanel = false }
            )
        }

        // Call overlay
        if (viewModel.callState == ChatViewModel.CallUIState.RINGING) {
            IncomingCallBanner(
                onAccept = { viewModel.acceptCall() },
                onDecline = { viewModel.declineCall() }
            )
        }
        if (viewModel.callState == ChatViewModel.CallUIState.CALLING ||
            viewModel.callState == ChatViewModel.CallUIState.ACTIVE
        ) {
            ActiveCallBanner(
                timer = viewModel.callTimer,
                isMuted = viewModel.isMuted,
                isSpeakerOn = viewModel.isSpeakerOn,
                isActive = viewModel.callState == ChatViewModel.CallUIState.ACTIVE,
                onToggleMute = { viewModel.toggleMute() },
                onToggleSpeaker = { viewModel.toggleSpeaker() },
                onEndCall = { viewModel.endCall() }
            )
        }

        // Save contact prompt
        if (viewModel.showSaveContactPrompt) {
            SaveContactDialog(
                name = viewModel.pendingContactName,
                onNameChange = { viewModel.pendingContactName = it },
                onSave = { viewModel.saveContact(viewModel.pendingContactName) },
                onDismiss = { viewModel.dismissSavePrompt() }
            )
        }

        // Messages
        LazyColumn(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            state = listState,
            verticalArrangement = Arrangement.spacedBy(4.dp),
            contentPadding = PaddingValues(vertical = 8.dp)
        ) {
            items(viewModel.messages, key = { it.id }) { message ->
                MessageBubble(message)
            }
        }

        // Input bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(GhostSurface)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = messageText,
                onValueChange = { messageText = it },
                placeholder = { Text(stringResource(R.string.chat_placeholder), color = GhostGray) },
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(20.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = GhostGrayLight,
                    unfocusedBorderColor = GhostGrayLight,
                    focusedTextColor = GhostWhite,
                    unfocusedTextColor = GhostWhite,
                    cursorColor = GhostBlue
                ),
                maxLines = 4
            )

            Spacer(modifier = Modifier.width(8.dp))

            IconButton(
                onClick = {
                    if (messageText.isNotBlank()) {
                        viewModel.sendMessage(messageText)
                        messageText = ""
                    }
                },
                enabled = messageText.isNotBlank()
            ) {
                Icon(
                    Icons.Default.Send,
                    contentDescription = "Send",
                    tint = if (messageText.isNotBlank()) GhostBlue else GhostGray
                )
            }
        }
    }
}

@Composable
private fun ChatHeader(
    fingerprint: String,
    isVerified: Boolean,
    contactName: String?,
    onShieldClick: () -> Unit,
    onCallClick: () -> Unit,
    onSettingsClick: () -> Unit,
    onLeaveClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(GhostSurface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Fingerprint
        Column(
            modifier = Modifier
                .weight(1f)
                .clickable(onClick = onShieldClick)
        ) {
            if (contactName != null) {
                Text(contactName, fontSize = 14.sp, color = GhostWhite, fontWeight = FontWeight.SemiBold)
            }
            Text(
                fingerprint,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                color = GhostGray,
                maxLines = 1
            )
        }

        // Shield (verification)
        IconButton(onClick = onShieldClick) {
            Icon(
                Icons.Default.Shield,
                contentDescription = "Verify",
                tint = if (isVerified) GhostGreen else GhostYellow,
                modifier = Modifier.size(20.dp)
            )
        }

        // Call
        IconButton(onClick = onCallClick) {
            Icon(Icons.Default.Call, contentDescription = "Call", tint = GhostGreen, modifier = Modifier.size(20.dp))
        }

        // Settings
        IconButton(onClick = onSettingsClick) {
            Icon(Icons.Default.Settings, contentDescription = "Settings", tint = GhostGray, modifier = Modifier.size(20.dp))
        }

        // Leave
        IconButton(onClick = onLeaveClick) {
            Icon(Icons.AutoMirrored.Filled.ExitToApp, contentDescription = "Leave", tint = GhostRed, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessage) {
    val alignment = when (message.type) {
        ChatMessage.MessageType.SENT -> Alignment.CenterEnd
        ChatMessage.MessageType.RECEIVED -> Alignment.CenterStart
        ChatMessage.MessageType.SYSTEM -> Alignment.Center
    }

    val bgColor = when (message.type) {
        ChatMessage.MessageType.SENT -> GhostBlue
        ChatMessage.MessageType.RECEIVED -> GhostSurface
        ChatMessage.MessageType.SYSTEM -> GhostBlack
    }

    val textColor = when (message.type) {
        ChatMessage.MessageType.SYSTEM -> GhostGray
        else -> GhostWhite
    }

    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = alignment
    ) {
        if (message.type == ChatMessage.MessageType.SYSTEM) {
            Text(
                text = message.text,
                fontSize = 12.sp,
                color = textColor,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(vertical = 4.dp)
            )
        } else {
            Column(
                modifier = Modifier
                    .widthIn(max = 280.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(bgColor)
                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                Text(
                    text = message.text,
                    fontSize = 15.sp,
                    color = textColor
                )
                if (message.type == ChatMessage.MessageType.SENT && message.isDelivered) {
                    Text(
                        text = "✓",
                        fontSize = 10.sp,
                        color = GhostWhite.copy(alpha = 0.7f),
                        textAlign = TextAlign.End,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        }
    }
}

@Composable
private fun VerificationPanel(
    fingerprint: String,
    isVerified: Boolean,
    onVerify: () -> Unit,
    onDismiss: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        colors = CardDefaults.cardColors(containerColor = GhostSurface),
        shape = RoundedCornerShape(12.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                stringResource(R.string.chat_verification_title),
                fontWeight = FontWeight.SemiBold,
                color = GhostWhite
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                fingerprint,
                fontFamily = FontFamily.Monospace,
                fontSize = 18.sp,
                color = GhostWhite,
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                stringResource(R.string.chat_verification_info),
                fontSize = 12.sp,
                color = GhostGray,
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.height(12.dp))
            Row {
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.chat_close), color = GhostGray)
                }
                Spacer(modifier = Modifier.width(8.dp))
                if (!isVerified) {
                    Button(
                        onClick = onVerify,
                        colors = ButtonDefaults.buttonColors(containerColor = GhostGreen)
                    ) {
                        Text(stringResource(R.string.chat_verify))
                    }
                } else {
                    Text("✓ " + stringResource(R.string.chat_verified), color = GhostGreen)
                }
            }
        }
    }
}

@Composable
private fun IncomingCallBanner(
    onAccept: () -> Unit,
    onDecline: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        colors = CardDefaults.cardColors(containerColor = GhostSurface),
        shape = RoundedCornerShape(12.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                stringResource(R.string.call_incoming),
                color = GhostWhite,
                fontWeight = FontWeight.SemiBold
            )
            IconButton(
                onClick = onAccept,
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(GhostGreen)
            ) {
                Icon(Icons.Default.Call, contentDescription = "Accept", tint = GhostWhite)
            }
            IconButton(
                onClick = onDecline,
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(GhostRed)
            ) {
                Icon(Icons.Default.CallEnd, contentDescription = "Decline", tint = GhostWhite)
            }
        }
    }
}

@Composable
private fun ActiveCallBanner(
    timer: String,
    isMuted: Boolean,
    isSpeakerOn: Boolean,
    isActive: Boolean,
    onToggleMute: () -> Unit,
    onToggleSpeaker: () -> Unit,
    onEndCall: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        colors = CardDefaults.cardColors(containerColor = GhostSurface),
        shape = RoundedCornerShape(12.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                if (isActive) timer else stringResource(R.string.call_calling),
                color = GhostWhite,
                fontWeight = FontWeight.SemiBold,
                fontSize = 18.sp
            )
            Spacer(modifier = Modifier.height(12.dp))
            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth()
            ) {
                IconButton(
                    onClick = onToggleMute,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(if (isMuted) GhostRed else GhostSurfaceLight)
                ) {
                    Icon(
                        if (isMuted) Icons.Default.MicOff else Icons.Default.Mic,
                        contentDescription = "Mute",
                        tint = GhostWhite
                    )
                }
                IconButton(
                    onClick = onToggleSpeaker,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(if (isSpeakerOn) GhostBlue else GhostSurfaceLight)
                ) {
                    Icon(
                        if (isSpeakerOn) Icons.Default.VolumeUp else Icons.Default.VolumeDown,
                        contentDescription = "Speaker",
                        tint = GhostWhite
                    )
                }
                IconButton(
                    onClick = onEndCall,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(GhostRed)
                ) {
                    Icon(Icons.Default.CallEnd, contentDescription = "End Call", tint = GhostWhite)
                }
            }
        }
    }
}

@Composable
private fun SaveContactDialog(
    name: String,
    onNameChange: (String) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.contacts_save_title), color = GhostWhite) },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = onNameChange,
                placeholder = { Text(stringResource(R.string.contacts_name_placeholder), color = GhostGray) },
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
            TextButton(onClick = onSave, enabled = name.isNotBlank()) {
                Text(stringResource(R.string.contacts_save), color = GhostBlue)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.chat_close), color = GhostGray)
            }
        },
        containerColor = GhostSurface
    )
}
