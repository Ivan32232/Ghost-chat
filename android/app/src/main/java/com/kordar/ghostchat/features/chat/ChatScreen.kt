package com.kordar.ghostchat.features.chat

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Call
import androidx.compose.material.icons.outlined.FiberManualRecord
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Radar
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.core.files.FileCatalog
import com.kordar.ghostchat.models.ConnectionState
import java.util.Locale

@Composable
fun ChatScreen(
    onLeave: () -> Unit,
    onStartCall: () -> Unit,
    viewModel: ChatViewModel = hiltViewModel()
) {
    val state by viewModel.connection.state.collectAsState()
    val safetyNumber by viewModel.connection.safetyNumber.collectAsState()
    val messages by viewModel.messages.messages.collectAsState()
    val draft by viewModel.draft.collectAsState()
    val isRecording by viewModel.isRecordingVoice.collectAsState()
    val listState = rememberLazyListState()
    val ctx = LocalContext.current

    var previewPath by remember { mutableStateOf<String?>(null) }

    DisposableEffect(Unit) {
        viewModel.start()
        onDispose { viewModel.stop() }
    }

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1)
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color.White.copy(alpha = 0.05f))
                    .padding(14.dp)
            ) {
                TextButton(onClick = {
                    viewModel.leave()
                    onLeave()
                }) {
                    Text(stringResource(R.string.chat_leave), color = Color.White)
                }
                Spacer(Modifier.weight(1f))
                Text(
                    text = viewModel.peerLabel(),
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = {
                    viewModel.startCall(); onStartCall()
                }) {
                    Icon(Icons.Outlined.Call, contentDescription = stringResource(R.string.chat_call), tint = Color.White)
                }
            }

            StatusBanner(state, safetyNumber)

            LazyColumn(
                state = listState,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                items(messages, key = { it.id }) { msg ->
                    ChatBubble(msg, onPreviewImage = { previewPath = it })
                }
            }

            InputBar(
                draft = draft,
                canSend = state == ConnectionState.ENCRYPTED,
                isRecording = isRecording,
                onDraftChange = viewModel::updateDraft,
                onSend = viewModel::send,
                onPickedImage = { bytes, name, mime ->
                    viewModel.sendAttachment(bytes, name, mime)
                },
                onPickedFile = { bytes, name, mime ->
                    if (viewModel.isSupportedMime(mime)) {
                        viewModel.sendAttachment(bytes, name, mime)
                    }
                },
                onStartVoice = viewModel::startVoiceRecording,
                onStopVoice = viewModel::stopVoiceRecordingAndSend,
                ctx = ctx
            )
        }

        val path = previewPath
        if (path != null) {
            FullScreenImageView(path = path, onClose = { previewPath = null })
        }
    }
}

@Composable
private fun StatusBanner(state: ConnectionState, safetyNumber: String?) {
    val encrypted = state == ConnectionState.ENCRYPTED
    val bg = if (encrypted) Color(0xFF0B3D20).copy(alpha = 0.6f) else Color(0xFF6B3200).copy(alpha = 0.6f)
    val fg = if (encrypted) Color(0xFF60D884) else Color(0xFFFFB26A)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(bg)
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Icon(
            imageVector = if (encrypted) Icons.Outlined.Lock else Icons.Outlined.Radar,
            contentDescription = null,
            tint = fg,
            modifier = Modifier.size(16.dp)
        )
        Spacer(Modifier.size(8.dp))
        Text(
            text = when (state) {
                ConnectionState.ENCRYPTED    -> stringResource(R.string.chat_connected)
                 ConnectionState.DISCONNECTED -> stringResource(R.string.chat_disconnected)
                else                         -> stringResource(R.string.chat_connecting)
            },
            color = fg
        )
        if (encrypted && !safetyNumber.isNullOrEmpty()) {
            Spacer(Modifier.weight(1f))
            Text(
                text = safetyNumber.take(9) + "…",
                color = Color.Gray
            )
        }
    }
}

@Composable
private fun InputBar(
    draft: String,
    canSend: Boolean,
    isRecording: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onPickedImage: (ByteArray, String, String) -> Unit,
    onPickedFile: (ByteArray, String, String) -> Unit,
    onStartVoice: () -> Unit,
    onStopVoice: () -> Unit,
    ctx: Context
) {
    var showAttachDialog by remember { mutableStateOf(false) }

    val photoLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        val (bytes, name, mime) = readUri(ctx, uri, defaultMime = "image/jpeg") ?: return@rememberLauncherForActivityResult
        onPickedImage(bytes, name, mime)
    }

    val fileLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        val (bytes, name, mime) = readUri(ctx, uri, defaultMime = "application/octet-stream")
            ?: return@rememberLauncherForActivityResult
        onPickedFile(bytes, name, mime)
    }

    if (showAttachDialog) {
        AlertDialog(
            onDismissRequest = { showAttachDialog = false },
            title = { Text("Attach") },
            text = { Text("Select an attachment source.") },
            confirmButton = {
                TextButton(onClick = {
                    showAttachDialog = false
                    photoLauncher.launch(
                        androidx.activity.result.PickVisualMediaRequest(
                            ActivityResultContracts.PickVisualMedia.ImageOnly
                        )
                    )
                }) { Text("Photo") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showAttachDialog = false
                    fileLauncher.launch(arrayOf(
                        "application/pdf", "text/plain", "application/zip",
                        "application/msword",
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                        "audio/*", "video/*", "image/*"
                    ))
                }) { Text("File") }
            }
        )
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(12.dp)
    ) {
        IconButton(onClick = { showAttachDialog = true }, enabled = canSend && !isRecording) {
            Icon(Icons.Outlined.AttachFile, contentDescription = "attach", tint = Color.White)
        }
        Spacer(Modifier.size(4.dp))

        if (isRecording) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .weight(1f)
                    .padding(vertical = 4.dp)
                    .background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(20.dp))
                    .padding(12.dp)
            ) {
                Icon(Icons.Outlined.FiberManualRecord, contentDescription = null, tint = Color.Red)
                Spacer(Modifier.size(8.dp))
                Text("Recording…", color = Color.White)
            }
        } else {
            val colors = TextFieldDefaults.colors(
                focusedContainerColor = Color.White.copy(alpha = 0.08f),
                unfocusedContainerColor = Color.White.copy(alpha = 0.08f),
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White
            )
            OutlinedTextField(
                value = draft,
                onValueChange = onDraftChange,
                placeholder = { Text(stringResource(R.string.chat_type_message), color = Color.Gray) },
                colors = colors,
                shape = RoundedCornerShape(20.dp),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                singleLine = false,
                enabled = canSend,
                modifier = Modifier.weight(1f)
            )
        }

        Spacer(Modifier.size(8.dp))

        if (draft.trim().isNotEmpty()) {
            IconButton(onClick = onSend, enabled = canSend) {
                Icon(
                    Icons.AutoMirrored.Outlined.Send,
                    contentDescription = stringResource(R.string.chat_send),
                    tint = Color.White
                )
            }
        } else {
            val icon = if (isRecording) Icons.Outlined.Stop else Icons.Outlined.Mic
            val tint = if (isRecording) Color.Red else Color.White
            Icon(
                icon, contentDescription = "voice", tint = tint,
                modifier = Modifier
                    .size(28.dp)
                    .pointerInput(canSend) {
                        if (!canSend) return@pointerInput
                        detectTapGestures(
                            onLongPress = { onStartVoice() },
                            onPress = {
                                tryAwaitRelease()
                                onStopVoice()
                            }
                        )
                    }
            )
        }
    }
}

/** Read the content at [uri] fully into memory and resolve its display name + MIME.
 *  Returns null on failure; callers should surface a user-visible error. */
private fun readUri(
    ctx: Context,
    uri: Uri,
    defaultMime: String
): Triple<ByteArray, String, String>? {
    val resolver = ctx.contentResolver
    val mime = resolver.getType(uri) ?: defaultMime
    val name = run {
        var result: String? = null
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && cursor.moveToFirst()) result = cursor.getString(idx)
        }
        result ?: (FileCatalog.primaryExtension(mime)?.let {
            "file-${System.currentTimeMillis()}.${it.lowercase(Locale.US)}"
        } ?: "file-${System.currentTimeMillis()}.bin")
    }
    val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
    return Triple(bytes, name, mime)
}
