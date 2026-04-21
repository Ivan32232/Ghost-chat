package com.kordar.ghostchat.features.chat

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.PlayCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.kordar.ghostchat.core.files.FileCatalog
import com.kordar.ghostchat.models.ChatMessage
import com.kordar.ghostchat.models.MessageType
import com.kordar.ghostchat.models.Sender
import com.kordar.ghostchat.ui.theme.bubbleShape
import java.io.File

@Composable
fun ChatBubble(
    message: ChatMessage,
    modifier: Modifier = Modifier,
    onPreviewImage: (String) -> Unit = {}
) {
    when (message.sender) {
        Sender.SYSTEM -> SystemPill(message.text, modifier)
        else -> PeerOrMeBubble(message, modifier, onPreviewImage)
    }
}

@Composable
private fun SystemPill(text: String, modifier: Modifier) {
    Box(modifier = modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Text(
            text = text,
            color = Color.Gray,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(Color.White.copy(alpha = 0.05f))
                .padding(horizontal = 14.dp, vertical = 6.dp)
        )
    }
}

@Composable
private fun PeerOrMeBubble(
    message: ChatMessage,
    modifier: Modifier,
    onPreviewImage: (String) -> Unit
) {
    val isMine = message.sender == Sender.ME
    val bg = if (isMine) Color.White else Color.White.copy(alpha = 0.1f)
    val fg = if (isMine) Color.Black else Color.White

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = if (isMine) Arrangement.End else Arrangement.Start
    ) {
        if (isMine) Spacer(Modifier.widthIn(min = 48.dp))
        val bubbleModifier = Modifier
            .widthIn(max = 280.dp)
            .clip(bubbleShape(isMe = isMine))
            .background(bg)

        when (message.type) {
            MessageType.TEXT, MessageType.SYSTEM -> TextContent(message.text, fg, bubbleModifier)
            MessageType.VOICE -> VoiceContent(message, fg, bubbleModifier)
            MessageType.FILE  -> {
                val isImage = message.fileMimeType
                    ?.let { FileCatalog.categoryFor(it) == FileCatalog.Category.IMAGE } ?: false
                if (isImage) ImageContent(message, bubbleModifier, onPreviewImage)
                else FileCardContent(message, fg, bubbleModifier)
            }
        }

        if (!isMine) Spacer(Modifier.widthIn(min = 48.dp))
    }
}

@Composable
private fun TextContent(text: String, fg: Color, modifier: Modifier) {
    Text(
        text = text,
        color = fg,
        style = MaterialTheme.typography.bodyLarge,
        modifier = modifier.padding(horizontal = 14.dp, vertical = 10.dp)
    )
}

@Composable
private fun VoiceContent(message: ChatMessage, fg: Color, modifier: Modifier) {
    Row(
        modifier = modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(Icons.Outlined.PlayCircle, contentDescription = "play", tint = fg)
        Spacer(Modifier.size(8.dp))
        Text(durationLabel(message), color = fg.copy(alpha = 0.85f))
        message.fileSize?.let {
            Spacer(Modifier.size(8.dp))
            Text(formatBytes(it), color = fg.copy(alpha = 0.6f), style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun ImageContent(
    message: ChatMessage,
    modifier: Modifier,
    onPreviewImage: (String) -> Unit
) {
    val path = message.fileLocalPath ?: return
    val bitmap = remember(path) {
        runCatching {
            val opts = BitmapFactory.Options().apply { inSampleSize = 2 }
            BitmapFactory.decodeFile(path, opts)
        }.getOrNull()
    }
    if (bitmap == null) {
        FileCardContent(message, Color.White, modifier)
        return
    }
    Image(
        bitmap = bitmap.asImageBitmap(),
        contentDescription = message.fileName,
        contentScale = ContentScale.Fit,
        modifier = modifier
            .heightIn(max = 220.dp)
            .clickable { onPreviewImage(path) }
    )
}

@Composable
private fun FileCardContent(message: ChatMessage, fg: Color, modifier: Modifier) {
    Row(
        modifier = modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(Icons.Outlined.Description, contentDescription = null, tint = fg)
        Spacer(Modifier.size(10.dp))
        Column {
            Text(
                text = message.fileName ?: "file",
                color = fg,
                fontWeight = FontWeight.Medium,
                maxLines = 1
            )
            message.fileSize?.let {
                Text(
                    text = formatBytes(it),
                    color = fg.copy(alpha = 0.6f),
                    style = MaterialTheme.typography.labelSmall
                )
            }
        }
    }
}

private fun durationLabel(message: ChatMessage): String {
    val size = message.fileSize ?: return "voice"
    if (size <= 0) return "voice"
    // 64 kbps ≈ 8 KiB/sec
    val seconds = (size / 8192).coerceAtLeast(1)
    val m = seconds / 60; val s = seconds % 60
    return "%d:%02d".format(m, s)
}

private fun formatBytes(bytes: Int): String {
    if (bytes < 1024) return "${bytes} B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.1f KB".format(kb)
    val mb = kb / 1024.0
    return "%.1f MB".format(mb)
}
