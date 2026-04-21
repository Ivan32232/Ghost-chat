package com.kordar.ghostchat.features.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.kordar.ghostchat.models.ChatMessage
import com.kordar.ghostchat.models.Sender

@Composable
fun ChatBubble(message: ChatMessage, modifier: Modifier = Modifier) {
    when (message.sender) {
        Sender.SYSTEM -> SystemPill(message.text, modifier)
        else -> PeerOrMeBubble(message, modifier)
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
private fun PeerOrMeBubble(message: ChatMessage, modifier: Modifier) {
    val isMine = message.sender == Sender.ME
    val bg = if (isMine) Color.White else Color.White.copy(alpha = 0.1f)
    val fg = if (isMine) Color.Black else Color.White

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = if (isMine) Arrangement.End else Arrangement.Start
    ) {
        if (isMine) Spacer(Modifier.widthIn(min = 48.dp))
        Text(
            text = message.text,
            color = fg,
            modifier = Modifier
                .widthIn(max = 280.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(bg)
                .padding(horizontal = 14.dp, vertical = 10.dp)
        )
        if (!isMine) Spacer(Modifier.widthIn(min = 48.dp))
    }
}
