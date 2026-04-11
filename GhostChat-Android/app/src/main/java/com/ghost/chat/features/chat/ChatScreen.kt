package com.ghost.chat.features.chat

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.core.filetransfer.FileTransferService
import android.content.Intent
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.core.content.FileProvider
import android.util.Log
import com.ghost.chat.models.ChatMessage
import com.ghost.chat.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun ChatScreen(
    viewModel: ChatViewModel,
    onOpenSettings: () -> Unit,
    onLeave: () -> Unit,
    onContactClick: ((com.ghost.chat.models.Contact) -> Unit)? = null
) {
    val context = LocalContext.current
    // Per-contact drafts — saved in SharedPreferences keyed by contactId
    val draftPrefs = remember { context.getSharedPreferences("ghost_drafts", android.content.Context.MODE_PRIVATE) }
    val currentContactKey = remember(viewModel.currentContactId) {
        viewModel.currentContactId?.let { "draft_$it" }
    }
    var messageText by remember(currentContactKey) {
        val initial = currentContactKey?.let { draftPrefs.getString(it, "") } ?: ""
        mutableStateOf(initial ?: "")
    }
    // Persist draft on every keystroke
    LaunchedEffect(messageText, currentContactKey) {
        val key = currentContactKey ?: return@LaunchedEffect
        if (messageText.isEmpty()) {
            draftPrefs.edit().remove(key).apply()
        } else {
            draftPrefs.edit().putString(key, messageText).apply()
        }
    }
    val listState = rememberLazyListState()
    val coroutineScope = rememberCoroutineScope()
    val canAttachFiles = viewModel.isSavedMessagesMode || viewModel.isConnected

    val filePickerLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        Log.d("GhostChat", "[UI] filePickerLauncher result, uri=$uri")
        uri?.let { viewModel.sendFile(it) }
    }

    // Jump-to-bottom state (Telegram-style)
    // User is "near bottom" if the last visible item is within the last 2 of the list.
    val isNearBottom by remember {
        derivedStateOf {
            val layoutInfo = listState.layoutInfo
            val total = layoutInfo.totalItemsCount
            if (total == 0) return@derivedStateOf true
            val lastVisible = layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: return@derivedStateOf true
            lastVisible >= total - 2
        }
    }
    var unreadSinceScroll by remember { mutableIntStateOf(0) }

    // Auto-scroll to bottom on new messages, but ONLY if user is already near bottom.
    // Otherwise increment the unread badge on the jump-to-bottom button.
    LaunchedEffect(viewModel.messages.size) {
        Log.d("GhostChat", "[UI] LaunchedEffect messages.size=${viewModel.messages.size}, isNearBottom=$isNearBottom")
        if (viewModel.messages.isNotEmpty()) {
            if (isNearBottom) {
                listState.animateScrollToItem(viewModel.messages.size - 1)
                unreadSinceScroll = 0
            } else {
                // Only count received messages for the badge
                val last = viewModel.messages.lastOrNull()
                if (last?.type == com.ghost.chat.models.ChatMessage.MessageType.RECEIVED) {
                    unreadSinceScroll += 1
                }
            }
        }
    }
    // Reset badge when user manually scrolls to bottom
    LaunchedEffect(isNearBottom) {
        if (isNearBottom) unreadSinceScroll = 0
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
            .imePadding()
    ) {
        // Header
        ChatHeader(
            fingerprint = viewModel.fingerprint,
            isVerified = viewModel.isVerified,
            isConnected = viewModel.isConnected,
            contactName = viewModel.currentPeerContact?.label,
            isInCall = viewModel.callState != ChatViewModel.CallUIState.IDLE,
            isSavedMessagesMode = viewModel.isSavedMessagesMode,
            peerStatus = viewModel.peerStatus,
            peerIsTyping = viewModel.peerIsTyping,
            onShieldClick = { Log.d("GhostChat", "[UI] Shield button tapped, showVerificationPanel=${!viewModel.showVerificationPanel}"); viewModel.showVerificationPanel = !viewModel.showVerificationPanel },
            onCallClick = { Log.d("GhostChat", "[UI] Call button tapped, isConnected=${viewModel.isConnected}, callState=${viewModel.callState}"); viewModel.startCall() },
            onContactClick = { Log.d("GhostChat", "[UI] Contact name tapped, contact=${viewModel.currentPeerContact?.label}"); viewModel.currentPeerContact?.let { c -> onContactClick?.invoke(c) } },
            onLeaveClick = { Log.d("GhostChat", "[UI] Back/Leave button tapped, screen=${viewModel.screen}, isConnected=${viewModel.isConnected}"); onLeave() }
        )

        // Verification panel
        if (viewModel.showVerificationPanel) {
            VerificationPanel(
                fingerprint = viewModel.fingerprint,
                isVerified = viewModel.isVerified,
                onVerify = { Log.d("GhostChat", "[UI] Verify button tapped"); viewModel.isVerified = true },
                onDismiss = { Log.d("GhostChat", "[UI] Verification panel dismiss tapped"); viewModel.showVerificationPanel = false }
            )
        }

        // Call overlay
        if (viewModel.callState == ChatViewModel.CallUIState.RINGING) {
            IncomingCallBanner(
                onAccept = { Log.d("GhostChat", "[UI] Accept call button tapped"); viewModel.acceptCall() },
                onDecline = { Log.d("GhostChat", "[UI] Decline call button tapped"); viewModel.declineCall() }
            )
        }
        if (viewModel.callState == ChatViewModel.CallUIState.CALLING ||
            viewModel.callState == ChatViewModel.CallUIState.ACTIVE
        ) {
            var showAudioRoutePicker by remember { mutableStateOf(false) }
            ActiveCallBanner(
                timer = viewModel.callTimer,
                isMuted = viewModel.isMuted,
                isSpeakerOn = viewModel.isSpeakerOn,
                isActive = viewModel.callState == ChatViewModel.CallUIState.ACTIVE,
                onToggleMute = { Log.d("GhostChat", "[UI] Toggle mute button tapped, currentMuted=${viewModel.isMuted}"); viewModel.toggleMute() },
                onToggleSpeaker = {
                    Log.d("GhostChat", "[UI] Audio route button tapped")
                    showAudioRoutePicker = true
                },
                onEndCall = { Log.d("GhostChat", "[UI] End call button tapped"); viewModel.endCall() }
            )
            if (showAudioRoutePicker) {
                AudioRoutePickerDialog(
                    routes = viewModel.availableAudioRoutes(),
                    onSelect = { route ->
                        viewModel.selectAudioRoute(route)
                        showAudioRoutePicker = false
                    },
                    onDismiss = { showAudioRoutePicker = false }
                )
            }
        }

        // Save contact prompt
        if (viewModel.showSaveContactPrompt) {
            SaveContactDialog(
                name = viewModel.pendingContactName,
                onNameChange = { viewModel.pendingContactName = it },
                onSave = { Log.d("GhostChat", "[UI] Save contact button tapped, name=${viewModel.pendingContactName}"); viewModel.saveContact(viewModel.pendingContactName) },
                onDismiss = { Log.d("GhostChat", "[UI] Skip save contact button tapped"); viewModel.dismissSavePrompt() }
            )
        }

        // Peer disconnected banner
        if (viewModel.showPeerDisconnectedBanner) {
            PeerDisconnectedBanner(onLeave = { Log.d("GhostChat", "[UI] Peer disconnected leave button tapped"); onLeave() })
        }

        // Messages with jump-to-bottom FAB overlay
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
        ) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 16.dp),
                state = listState,
                verticalArrangement = Arrangement.spacedBy(4.dp),
                contentPadding = PaddingValues(vertical = 8.dp)
            ) {
                items(viewModel.messages, key = { it.id }) { message ->
                    SwipeToReplyWrapper(
                        message = message,
                        onReply = {
                            Log.d("GhostChat", "[UI] Swipe to reply triggered, messageId=${message.id}")
                            viewModel.replyingTo = message
                        }
                    ) {
                        MessageBubble(message, viewModel)
                    }
                }
            }

            // Jump-to-bottom floating button (Telegram-style)
            if (!isNearBottom) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(end = 14.dp, bottom = 10.dp)
                ) {
                    IconButton(
                        onClick = {
                            Log.d("GhostChat", "[UI] Jump-to-bottom tapped, unread=$unreadSinceScroll")
                            coroutineScope.launch {
                                if (viewModel.messages.isNotEmpty()) {
                                    listState.animateScrollToItem(viewModel.messages.size - 1)
                                }
                                unreadSinceScroll = 0
                            }
                        },
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF262626))
                    ) {
                        Icon(
                            Icons.Default.KeyboardArrowDown,
                            contentDescription = "Jump to bottom",
                            tint = GhostWhite
                        )
                    }
                    if (unreadSinceScroll > 0) {
                        Box(
                            modifier = Modifier
                                .offset(x = 16.dp, y = (-16).dp)
                                .size(20.dp)
                                .clip(CircleShape)
                                .background(GhostGreen),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                "$unreadSinceScroll",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = GhostWhite
                            )
                        }
                    }
                }
            }
        }

        // Typing indicator
        AnimatedVisibility(
            visible = viewModel.peerIsTyping,
            enter = fadeIn() + slideInVertically { it },
            exit = fadeOut() + slideOutVertically { it }
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TypingDots()
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    stringResource(R.string.chat_typing),
                    fontSize = 12.sp,
                    color = GhostGray
                )
            }
        }

        // Attach panel (expandable)
        var showAttachPanel by remember { mutableStateOf(false) }

        val photoPickerLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.PickVisualMedia()
        ) { uri ->
            Log.d("GhostChat", "[UI] photoPickerLauncher result, uri=$uri")
            uri?.let { viewModel.sendFile(it) }
        }

        AnimatedVisibility(
            visible = showAttachPanel,
            enter = fadeIn() + slideInVertically { it },
            exit = fadeOut() + slideOutVertically { it }
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(GhostSurface)
                    .padding(horizontal = 24.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(24.dp)
            ) {
                // Photos
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.clickable {
                        Log.d("GhostChat", "[UI] Photos picker tapped")
                        showAttachPanel = false
                        photoPickerLauncher.launch(
                            androidx.activity.result.PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageAndVideo
                            )
                        )
                    }
                ) {
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .clip(CircleShape)
                            .background(GhostAccent.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Default.Photo,
                            contentDescription = "Photos",
                            tint = GhostAccent,
                            modifier = Modifier.size(24.dp)
                        )
                    }
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        stringResource(R.string.attach_photos),
                        fontSize = 11.sp,
                        color = GhostGray
                    )
                }
                // File
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.clickable {
                        Log.d("GhostChat", "[UI] File picker tapped")
                        showAttachPanel = false
                        filePickerLauncher.launch("*/*")
                    }
                ) {
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .clip(CircleShape)
                            .background(GhostPurple.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Default.InsertDriveFile,
                            contentDescription = "File",
                            tint = GhostPurple,
                            modifier = Modifier.size(24.dp)
                        )
                    }
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        stringResource(R.string.attach_file),
                        fontSize = 11.sp,
                        color = GhostGray
                    )
                }
            }
        }

        // Reply preview bar (Telegram-style)
        viewModel.replyingTo?.let { reply ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(GhostSurface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .width(3.dp)
                        .height(36.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(Color(0xFF2196F3))
                )
                Spacer(modifier = Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = if (reply.type == ChatMessage.MessageType.SENT)
                            stringResource(R.string.chat_you) else (viewModel.currentPeerContact?.label ?: ""),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color(0xFF2196F3)
                    )
                    Text(
                        text = reply.text,
                        fontSize = 13.sp,
                        color = GhostGray,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                IconButton(
                    onClick = { Log.d("GhostChat", "[UI] Cancel reply button tapped"); viewModel.replyingTo = null },
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "Cancel reply",
                        tint = GhostGray,
                        modifier = Modifier.size(18.dp)
                    )
                }
            }
        }

        // Input bar — web style
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(GhostBlack)
                .padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.Bottom
        ) {
            // Attach button (paperclip)
            if (canAttachFiles) {
                IconButton(
                    onClick = { Log.d("GhostChat", "[UI] Attach button tapped, showAttachPanel=${!showAttachPanel}"); showAttachPanel = !showAttachPanel },
                    modifier = Modifier.size(40.dp)
                ) {
                    Icon(
                        Icons.Default.AttachFile,
                        contentDescription = "Attach",
                        tint = GhostGray,
                        modifier = Modifier.size(22.dp)
                    )
                }
            }

            // Text field — pill shape
            OutlinedTextField(
                value = messageText,
                onValueChange = {
                    Log.d("GhostChat", "[UI] messageText onValueChange, len=${it.length}")
                    messageText = it
                    if (it.isNotEmpty()) viewModel.userIsTyping() else viewModel.stopTyping()
                },
                placeholder = { Text(stringResource(R.string.chat_placeholder), color = GhostGray, fontSize = 15.sp) },
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 2.dp),
                shape = RoundedCornerShape(24.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = GhostGrayLight,
                    unfocusedBorderColor = GhostGrayLight.copy(alpha = 0.6f),
                    focusedTextColor = GhostWhite,
                    unfocusedTextColor = GhostWhite,
                    cursorColor = GhostAccent,
                    focusedContainerColor = GhostSurface,
                    unfocusedContainerColor = GhostSurface
                ),
                maxLines = 4,
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 15.sp)
            )

            // Send button
            IconButton(
                onClick = {
                    if (messageText.isNotBlank()) {
                        Log.d("GhostChat", "[UI] Send button tapped, textLength=${messageText.trim().length}")
                        viewModel.sendMessage(messageText)
                        messageText = ""
                        showAttachPanel = false
                    }
                },
                enabled = messageText.isNotBlank(),
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(
                        if (messageText.isNotBlank()) GhostAccent
                        else GhostAccent.copy(alpha = 0.15f)
                    )
            ) {
                Icon(
                    Icons.Default.Send,
                    contentDescription = "Send",
                    tint = if (messageText.isNotBlank()) GhostBlack else GhostGray,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

@Composable
private fun ChatHeader(
    fingerprint: String,
    isVerified: Boolean,
    isConnected: Boolean,
    contactName: String?,
    isInCall: Boolean,
    isSavedMessagesMode: Boolean = false,
    peerStatus: ChatViewModel.PeerStatus = ChatViewModel.PeerStatus.OFFLINE,
    peerIsTyping: Boolean = false,
    onShieldClick: () -> Unit,
    onCallClick: () -> Unit,
    onContactClick: () -> Unit,
    onLeaveClick: () -> Unit
) {
    val statusColor = when (peerStatus) {
        ChatViewModel.PeerStatus.ONLINE -> GhostGreen
        ChatViewModel.PeerStatus.CONNECTING -> GhostYellow
        ChatViewModel.PeerStatus.SEARCHING -> GhostOrange
        ChatViewModel.PeerStatus.RECENTLY_ONLINE -> GhostBlue
        ChatViewModel.PeerStatus.OFFLINE -> GhostGray
    }

    val statusText = when (peerStatus) {
        ChatViewModel.PeerStatus.ONLINE -> stringResource(R.string.status_online)
        ChatViewModel.PeerStatus.CONNECTING -> stringResource(R.string.status_connecting)
        ChatViewModel.PeerStatus.SEARCHING -> stringResource(R.string.status_searching)
        ChatViewModel.PeerStatus.RECENTLY_ONLINE -> stringResource(R.string.status_recently_online)
        ChatViewModel.PeerStatus.OFFLINE -> stringResource(R.string.status_offline)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(GhostBlack)
            .padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Back button
        IconButton(onClick = { Log.d("GhostChat", "[UI] Header back button tapped"); onLeaveClick() }) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = GhostWhite,
                modifier = Modifier.size(22.dp)
            )
        }

        // Contact name — tappable
        if (isSavedMessagesMode) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.Bookmark,
                    contentDescription = null,
                    tint = GhostPurple,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    stringResource(R.string.saved_title),
                    fontSize = 16.sp,
                    color = GhostWhite,
                    fontWeight = FontWeight.SemiBold
                )
            }
        } else {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable(enabled = contactName != null) { Log.d("GhostChat", "[UI] Header contact name tapped, name=$contactName"); onContactClick() }
            ) {
                Text(
                    text = contactName ?: fingerprint.take(19) + "…",
                    fontSize = 15.sp,
                    color = GhostWhite,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (peerIsTyping) {
                        TypingDots()
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            stringResource(R.string.chat_typing),
                            fontSize = 11.sp,
                            color = GhostGray
                        )
                    } else {
                        Box(
                            modifier = Modifier
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(statusColor)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = statusText,
                            fontSize = 11.sp,
                            color = statusColor
                        )
                    }
                }
            }
        }

        if (!isSavedMessagesMode && !isInCall) {
            Spacer(modifier = Modifier.width(4.dp))

            // Shield
            IconButton(onClick = { Log.d("GhostChat", "[UI] Header shield button tapped"); onShieldClick() }) {
                Icon(
                    Icons.Default.Shield,
                    contentDescription = "Verify",
                    tint = if (isVerified) GhostGreen else GhostYellow,
                    modifier = Modifier.size(20.dp)
                )
            }

            // Call button — bigger, green circle
            // Not disabled when offline — tapping starts room + waits for peer (like iOS)
            IconButton(
                onClick = { Log.d("GhostChat", "[UI] Header call button tapped, isConnected=$isConnected"); onCallClick() },
                enabled = !isInCall,
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(GhostGreen.copy(alpha = if (!isInCall) 0.15f else 0.05f))
            ) {
                Icon(
                    Icons.Default.Call,
                    contentDescription = "Call",
                    tint = if (!isInCall) GhostGreen else GhostGray,
                    modifier = Modifier.size(22.dp)
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(message: ChatMessage, viewModel: ChatViewModel) {
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val alignment = when (message.type) {
        ChatMessage.MessageType.SENT -> Alignment.CenterEnd
        ChatMessage.MessageType.RECEIVED -> Alignment.CenterStart
        ChatMessage.MessageType.SYSTEM -> Alignment.Center
    }

    val bgColor = when (message.type) {
        ChatMessage.MessageType.SENT -> GhostSentBubble
        ChatMessage.MessageType.RECEIVED -> GhostReceivedBubble
        ChatMessage.MessageType.SYSTEM -> GhostBlack
    }

    val textColor = when (message.type) {
        ChatMessage.MessageType.SENT -> GhostSentText
        ChatMessage.MessageType.RECEIVED -> GhostWhite
        ChatMessage.MessageType.SYSTEM -> GhostGray
    }

    // Responsive bubble width — 75% of screen width
    val screenWidth = LocalConfiguration.current.screenWidthDp.dp
    val maxBubbleWidth = screenWidth * 0.75f

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
        } else if (message.isFileMessage) {
            // File message bubble
            Column(
                modifier = Modifier
                    .widthIn(max = maxBubbleWidth)
                    .clip(RoundedCornerShape(16.dp))
                    .background(bgColor)
                    .clickable {
                        Log.d("GhostChat", "[UI] File message tapped, messageId=${message.id}, fileName=${message.fileName}")
                        val localPath = message.fileLocalPath ?: return@clickable
                        if (message.fileTransferProgress != null) return@clickable
                        val file = viewModel.fileTransfer.localFile(localPath)
                        if (!file.exists()) return@clickable
                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, message.fileMimeType ?: "*/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        context.startActivity(intent)
                    }
                    .padding(10.dp)
            ) {
                // Image / Video preview
                val localPath = message.fileLocalPath
                val mime = message.fileMimeType
                val isImage = mime != null && FileTransferService.isImage(mime)
                val isVideo = mime != null && FileTransferService.isVideo(mime)
                if (localPath != null && (isImage || isVideo)) {
                    val file = viewModel.fileTransfer.localFile(localPath)
                    val bitmap = remember(localPath) {
                        if (!file.exists()) null
                        else if (isVideo) videoThumbnail(file.absolutePath)
                        else decodeSampledBitmap(file.absolutePath, 500, 600)
                    }
                    if (bitmap != null) {
                        Column {
                            Box {
                                Image(
                                    bitmap = bitmap.asImageBitmap(),
                                    contentDescription = message.fileName,
                                    modifier = Modifier
                                        .widthIn(max = 250.dp)
                                        .heightIn(max = 300.dp)
                                        .clip(RoundedCornerShape(12.dp)),
                                    contentScale = ContentScale.Fit
                                )
                                if (isVideo) {
                                    Icon(
                                        Icons.Default.PlayCircle,
                                        contentDescription = "Play",
                                        tint = GhostWhite.copy(alpha = 0.85f),
                                        modifier = Modifier
                                            .size(44.dp)
                                            .align(Alignment.Center)
                                    )
                                }
                            }
                            // Caption: filename + size below image
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                                modifier = Modifier.padding(top = 2.dp)
                            ) {
                                Text(
                                    text = message.fileName ?: "",
                                    fontSize = 10.sp,
                                    color = textColor.copy(alpha = 0.6f),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false)
                                )
                                message.fileSize?.let { size ->
                                    Text(
                                        text = "· ${FileTransferService.formatSize(size)}",
                                        fontSize = 10.sp,
                                        color = textColor.copy(alpha = 0.4f)
                                    )
                                }
                            }
                        }
                    } else {
                        // Image/video but failed to load — filename fallback
                        FileIconRow(message = message, textColor = textColor, mime = mime)
                    }
                } else {
                    // Non-image file icon + name + size
                    FileIconRow(message = message, textColor = textColor, mime = mime)
                }

                // Progress bar during transfer
                message.fileTransferProgress?.let { progress ->
                    Spacer(modifier = Modifier.height(6.dp))
                    LinearProgressIndicator(
                        progress = { progress.toFloat() },
                        modifier = Modifier
                            .widthIn(max = 200.dp)
                            .height(3.dp)
                            .clip(RoundedCornerShape(2.dp)),
                        color = GhostWhite,
                        trackColor = GhostWhite.copy(alpha = 0.2f)
                    )
                }

                // Delivery/read status
                if (message.type == ChatMessage.MessageType.SENT) {
                    Text(
                        text = when {
                            message.isRead -> "\u2713\u2713"
                            message.isDelivered -> "\u2713\u2713"
                            message.isPending -> "\u25F7"
                            else -> "\u2713"
                        },
                        fontSize = 10.sp,
                        color = when {
                            message.isRead -> Color(0xFF4FC3F7)
                            message.isDelivered -> GhostGreen
                            else -> textColor.copy(alpha = 0.5f)
                        },
                        textAlign = TextAlign.End,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        } else {
            // Text message bubble
            var showDropdownMenu by remember { mutableStateOf(false) }
            var showEditDialog by remember { mutableStateOf(false) }
            var editText by remember { mutableStateOf("") }

            Column(
                modifier = Modifier
                    .widthIn(max = maxBubbleWidth)
                    .clip(RoundedCornerShape(16.dp))
                    .background(bgColor)
                    .combinedClickable(
                        onClick = {},
                        onLongClick = {
                            Log.d("GhostChat", "[UI] Message long-press, messageId=${message.id}, type=${message.type}")
                            showDropdownMenu = true
                        }
                    )
            ) {
                // Inline reply quote
                if (message.replyToText != null) {
                    Row(
                        modifier = Modifier
                            .padding(horizontal = 10.dp)
                            .padding(top = 8.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .width(2.5.dp)
                                .height(28.dp)
                                .clip(RoundedCornerShape(1.dp))
                                .background(
                                    if (message.type == ChatMessage.MessageType.SENT)
                                        Color(0xFF2196F3).copy(alpha = 0.6f)
                                    else Color(0xFF2196F3).copy(alpha = 0.5f)
                                )
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = message.replyToText,
                            fontSize = 12.sp,
                            color = if (message.type == ChatMessage.MessageType.SENT)
                                Color(0xFF4D4D4D) else GhostGray,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }

                Text(
                    text = message.text,
                    fontSize = 15.sp,
                    color = textColor,
                    modifier = Modifier.padding(
                        horizontal = 12.dp,
                        vertical = if (message.replyToText != null) 6.dp else 8.dp
                    )
                )

                // Delivery/read status + edited label
                if (message.type != ChatMessage.MessageType.SYSTEM) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp)
                            .padding(bottom = 6.dp),
                        horizontalArrangement = Arrangement.End,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (message.isEdited) {
                            Text(
                                text = stringResource(R.string.chat_edited),
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Medium,
                                color = GhostGray.copy(alpha = 0.6f)
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                        }
                        if (message.type == ChatMessage.MessageType.SENT) {
                            Text(
                                text = when {
                                    message.isRead -> "\u2713\u2713"
                                    message.isDelivered -> "\u2713\u2713"
                                    message.isPending -> "\u25F7"
                                    else -> "\u2713"
                                },
                                fontSize = 10.sp,
                                color = when {
                                    message.isRead -> Color(0xFF4FC3F7)
                                    message.isDelivered -> GhostGreen
                                    else -> GhostWhite.copy(alpha = 0.5f)
                                }
                            )
                        }
                    }
                }
            }

            // Dropdown context menu
            DropdownMenu(
                expanded = showDropdownMenu,
                onDismissRequest = { showDropdownMenu = false }
            ) {
                // Copy
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.chat_copy)) },
                    onClick = {
                        Log.d("GhostChat", "[UI] Copy message tapped, messageId=${message.id}")
                        clipboardManager.setText(AnnotatedString(message.text))
                        android.widget.Toast.makeText(context, context.getString(R.string.chat_copied), android.widget.Toast.LENGTH_SHORT).show()
                        showDropdownMenu = false
                    },
                    leadingIcon = { Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(20.dp)) }
                )
                // Edit (own messages only)
                if (message.type == ChatMessage.MessageType.SENT) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.chat_edit)) },
                        onClick = {
                            Log.d("GhostChat", "[UI] Edit message tapped, messageId=${message.id}")
                            showDropdownMenu = false
                            editText = message.text
                            showEditDialog = true
                        },
                        leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null, modifier = Modifier.size(20.dp)) }
                    )
                }
                // Delete for everyone (own messages with senderMessageId only)
                if (message.type == ChatMessage.MessageType.SENT && message.senderMessageId != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.chat_delete_for_everyone), color = GhostRed) },
                        onClick = {
                            Log.d("GhostChat", "[UI] Delete for everyone tapped, messageId=${message.id}, senderMessageId=${message.senderMessageId}")
                            showDropdownMenu = false
                            viewModel.deleteMessageForEveryone(message)
                        },
                        leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null, tint = GhostRed, modifier = Modifier.size(20.dp)) }
                    )
                }
            }

            // Edit dialog
            if (showEditDialog) {
                AlertDialog(
                    onDismissRequest = { showEditDialog = false },
                    title = { Text(stringResource(R.string.chat_edit), color = GhostWhite) },
                    text = {
                        OutlinedTextField(
                            value = editText,
                            onValueChange = { editText = it },
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = GhostAccent,
                                unfocusedBorderColor = GhostGrayLight,
                                focusedTextColor = GhostWhite,
                                unfocusedTextColor = GhostWhite,
                                cursorColor = GhostAccent
                            ),
                            maxLines = 5
                        )
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                Log.d("GhostChat", "[UI] Edit dialog save tapped, messageId=${message.id}, newTextLength=${editText.trim().length}")
                                if (editText.isNotBlank()) {
                                    viewModel.editMessage(message, editText.trim())
                                }
                                showEditDialog = false
                            },
                            enabled = editText.isNotBlank()
                        ) {
                            Text(stringResource(R.string.chat_save), color = GhostAccent)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showEditDialog = false }) {
                            Text(stringResource(R.string.chat_close), color = GhostGray)
                        }
                    },
                    containerColor = GhostSurface
                )
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
                TextButton(onClick = { Log.d("GhostChat", "[UI] Verification close button tapped"); onDismiss() }) {
                    Text(stringResource(R.string.chat_close), color = GhostGray)
                }
                Spacer(modifier = Modifier.width(8.dp))
                if (!isVerified) {
                    Button(
                        onClick = { Log.d("GhostChat", "[UI] Verification verify button tapped"); onVerify() },
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
                fontWeight = FontWeight.SemiBold,
                fontSize = 18.sp
            )
            IconButton(
                onClick = { Log.d("GhostChat", "[UI] IncomingCall accept button tapped"); onAccept() },
                modifier = Modifier
                    .size(56.dp)
                    .clip(CircleShape)
                    .background(GhostGreen)
            ) {
                Icon(Icons.Default.Call, contentDescription = "Accept", tint = GhostWhite, modifier = Modifier.size(28.dp))
            }
            IconButton(
                onClick = { Log.d("GhostChat", "[UI] IncomingCall decline button tapped"); onDecline() },
                modifier = Modifier
                    .size(56.dp)
                    .clip(CircleShape)
                    .background(GhostRed)
            ) {
                Icon(Icons.Default.CallEnd, contentDescription = "Decline", tint = GhostWhite, modifier = Modifier.size(28.dp))
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
                .padding(horizontal = 16.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                if (isActive) timer else stringResource(R.string.call_calling),
                color = GhostWhite,
                fontWeight = FontWeight.SemiBold,
                fontSize = 22.sp
            )
            Spacer(modifier = Modifier.height(20.dp))
            Row(
                horizontalArrangement = Arrangement.SpaceEvenly,
                modifier = Modifier.fillMaxWidth()
            ) {
                IconButton(
                    onClick = { Log.d("GhostChat", "[UI] ActiveCall mute button tapped, currentMuted=$isMuted"); onToggleMute() },
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape)
                        .background(if (isMuted) GhostRed else GhostSurfaceLight)
                ) {
                    Icon(
                        if (isMuted) Icons.Default.MicOff else Icons.Default.Mic,
                        contentDescription = "Mute",
                        tint = GhostWhite,
                        modifier = Modifier.size(28.dp)
                    )
                }
                IconButton(
                    onClick = { Log.d("GhostChat", "[UI] ActiveCall speaker button tapped, currentSpeaker=$isSpeakerOn"); onToggleSpeaker() },
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape)
                        .background(if (isSpeakerOn) GhostAccent else GhostSurfaceLight)
                ) {
                    Icon(
                        if (isSpeakerOn) Icons.Default.VolumeUp else Icons.Default.VolumeDown,
                        contentDescription = "Speaker",
                        tint = GhostWhite,
                        modifier = Modifier.size(28.dp)
                    )
                }
                IconButton(
                    onClick = { Log.d("GhostChat", "[UI] ActiveCall end button tapped"); onEndCall() },
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape)
                        .background(GhostRed)
                ) {
                    Icon(Icons.Default.CallEnd, contentDescription = "End Call", tint = GhostWhite, modifier = Modifier.size(28.dp))
                }
            }
        }
    }
}

@Composable
private fun TypingDots() {
    var phase by remember { mutableIntStateOf(0) }

    LaunchedEffect(Unit) {
        while (true) {
            delay(400)
            phase = (phase + 1) % 3
        }
    }

    Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        repeat(3) { index ->
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(GhostGray)
                    .graphicsLayer {
                        alpha = if (index == phase) 1f else 0.3f
                    }
            )
        }
    }
}

private fun videoThumbnail(path: String): Bitmap? {
    return try {
        val retriever = MediaMetadataRetriever()
        retriever.setDataSource(path)
        val frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        retriever.release()
        frame
    } catch (_: Exception) {
        null
    }
}

/** Decode bitmap with sampling to avoid OOM for large images */
private fun decodeSampledBitmap(path: String, reqWidth: Int, reqHeight: Int): Bitmap? {
    return try {
        // First decode with inJustDecodeBounds to get dimensions
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, options)
        // Calculate inSampleSize
        options.inSampleSize = calculateInSampleSize(options, reqWidth, reqHeight)
        options.inJustDecodeBounds = false
        BitmapFactory.decodeFile(path, options)
    } catch (_: Exception) {
        null
    }
}

private fun calculateInSampleSize(options: BitmapFactory.Options, reqWidth: Int, reqHeight: Int): Int {
    val (height, width) = options.outHeight to options.outWidth
    var inSampleSize = 1
    if (height > reqHeight || width > reqWidth) {
        val halfHeight = height / 2
        val halfWidth = width / 2
        while (halfHeight / inSampleSize >= reqHeight && halfWidth / inSampleSize >= reqWidth) {
            inSampleSize *= 2
        }
    }
    return inSampleSize
}

@Composable
private fun FileIconRow(message: ChatMessage, textColor: Color, mime: String?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            imageVector = when {
                mime != null && FileTransferService.isImage(mime) -> Icons.Default.Image
                mime != null && FileTransferService.isVideo(mime) -> Icons.Default.PlayCircle
                mime != null && mime.startsWith("audio/") -> Icons.Default.MusicNote
                mime == "application/pdf" -> Icons.Default.Description
                else -> Icons.Default.InsertDriveFile
            },
            contentDescription = null,
            tint = textColor.copy(alpha = 0.8f),
            modifier = Modifier.size(28.dp)
        )
        Column {
            Text(
                text = message.fileName ?: "File",
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = textColor,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            message.fileSize?.let { size ->
                Text(
                    text = FileTransferService.formatSize(size),
                    fontSize = 11.sp,
                    color = textColor.copy(alpha = 0.6f)
                )
            }
        }
    }
}

@Composable
private fun PeerDisconnectedBanner(onLeave: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(GhostRed.copy(alpha = 0.1f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(
            Icons.Default.CloudOff,
            contentDescription = null,
            tint = GhostRed,
            modifier = Modifier.size(16.dp)
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                stringResource(R.string.system_peer_disconnected),
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = GhostWhite
            )
            Text(
                stringResource(R.string.system_waiting_reconnect),
                fontSize = 12.sp,
                color = GhostGray
            )
        }
        TextButton(
            onClick = { Log.d("GhostChat", "[UI] PeerDisconnected leave button tapped"); onLeave() },
            colors = ButtonDefaults.textButtonColors(contentColor = GhostRed)
        ) {
            Text(
                stringResource(R.string.chat_leave),
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

@Composable
private fun SwipeToReplyWrapper(
    message: ChatMessage,
    onReply: () -> Unit,
    content: @Composable () -> Unit
) {
    // Don't allow swipe on system messages
    if (message.type == ChatMessage.MessageType.SYSTEM) {
        content()
        return
    }

    var offsetX by remember { mutableFloatStateOf(0f) }
    val threshold = with(LocalDensity.current) { 60.dp.toPx() }
    var replied by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .draggable(
                orientation = Orientation.Horizontal,
                state = rememberDraggableState { delta ->
                    // Only allow right-to-left swipe (negative delta = left swipe)
                    // or allow both directions based on message type
                    val newOffset = offsetX + delta
                    // Clamp: allow drag to the right (positive) for reply
                    offsetX = newOffset.coerceIn(-threshold, threshold)

                    if (!replied && kotlin.math.abs(offsetX) >= threshold) {
                        replied = true
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        onReply()
                    }
                },
                onDragStopped = {
                    offsetX = 0f
                    replied = false
                }
            )
    ) {
        // Reply icon indicator
        if (kotlin.math.abs(offsetX) > 10f) {
            Box(
                modifier = Modifier
                    .align(
                        if (offsetX > 0) Alignment.CenterStart else Alignment.CenterEnd
                    )
                    .padding(horizontal = 8.dp),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Default.Reply,
                    contentDescription = "Reply",
                    tint = GhostGray.copy(
                        alpha = (kotlin.math.abs(offsetX) / threshold).coerceIn(0f, 1f)
                    ),
                    modifier = Modifier.size(20.dp)
                )
            }
        }

        Box(
            modifier = Modifier.offset(x = with(LocalDensity.current) { offsetX.toDp() })
        ) {
            content()
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
                    focusedBorderColor = GhostAccent,
                    unfocusedBorderColor = GhostGrayLight,
                    focusedTextColor = GhostWhite,
                    unfocusedTextColor = GhostWhite,
                    cursorColor = GhostAccent
                ),
                singleLine = true
            )
        },
        confirmButton = {
            TextButton(onClick = { Log.d("GhostChat", "[UI] SaveContact save button tapped, name=$name"); onSave() }, enabled = name.isNotBlank()) {
                Text(stringResource(R.string.contacts_save), color = GhostAccent)
            }
        },
        dismissButton = {
            TextButton(onClick = { Log.d("GhostChat", "[UI] SaveContact dismiss button tapped"); onDismiss() }) {
                Text(stringResource(R.string.chat_close), color = GhostGray)
            }
        },
        containerColor = GhostSurface
    )
}

/// Telegram-style audio route picker — dialog listing all available output devices
/// (earpiece, speaker, bluetooth headset, wired headset) with the active one highlighted.
@Composable
private fun AudioRoutePickerDialog(
    routes: List<com.ghost.chat.core.webrtc.GhostVoice.AudioRouteOption>,
    onSelect: (com.ghost.chat.core.webrtc.GhostVoice.AudioRoute) -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.call_audio_output), color = GhostWhite) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (routes.isEmpty()) {
                    Text(stringResource(R.string.call_audio_no_devices), color = GhostGray)
                } else {
                    routes.forEach { option ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .clickable {
                                    Log.d("GhostChat", "[UI] AudioRoutePicker selected route=${option.route}")
                                    onSelect(option.route)
                                }
                                .padding(horizontal = 12.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            val icon = when (option.route) {
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.EARPIECE -> Icons.Default.Phone
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.SPEAKER -> Icons.Default.VolumeUp
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.BLUETOOTH -> Icons.Default.Bluetooth
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.WIRED_HEADSET -> Icons.Default.Headset
                            }
                            val label = when (option.route) {
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.EARPIECE -> stringResource(R.string.call_route_earpiece)
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.SPEAKER -> stringResource(R.string.call_route_speaker)
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.BLUETOOTH -> option.name
                                com.ghost.chat.core.webrtc.GhostVoice.AudioRoute.WIRED_HEADSET -> option.name
                            }
                            Icon(
                                icon,
                                contentDescription = label,
                                tint = if (option.isActive) GhostAccent else GhostWhite,
                                modifier = Modifier.size(24.dp)
                            )
                            Spacer(modifier = Modifier.width(16.dp))
                            Text(
                                label,
                                color = if (option.isActive) GhostAccent else GhostWhite,
                                fontSize = 15.sp,
                                modifier = Modifier.weight(1f)
                            )
                            if (option.isActive) {
                                Icon(
                                    Icons.Default.Check,
                                    contentDescription = null,
                                    tint = GhostAccent,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.chat_close), color = GhostGray)
            }
        },
        containerColor = GhostSurface
    )
}
