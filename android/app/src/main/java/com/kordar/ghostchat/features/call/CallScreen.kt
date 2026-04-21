package com.kordar.ghostchat.features.call

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CallEnd
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.MicOff
import androidx.compose.material.icons.outlined.VolumeDown
import androidx.compose.material.icons.outlined.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.features.chat.ChatViewModel
import com.kordar.ghostchat.models.CallState

@Composable
fun CallScreen(
    onDismiss: () -> Unit,
    chatViewModel: ChatViewModel = hiltViewModel()
) {
    val calls = chatViewModel.calls
    val state by calls.state.collectAsState()
    val muted by calls.muted.collectAsState()
    val speaker by calls.speakerOn.collectAsState()
    val durationMs by calls.durationMs.collectAsState()

    LaunchedEffect(state) {
        if (state == CallState.IDLE || state == CallState.ENDED) onDismiss()
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(24.dp),
        verticalArrangement = Arrangement.SpaceBetween,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.size(60.dp))

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Avatar(name = calls.peerName)
            Spacer(Modifier.size(16.dp))
            Text(
                text = calls.peerName,
                color = Color.White,
                fontSize = 28.sp,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(Modifier.size(8.dp))
            Text(text = stateLabel(state), color = Color.Gray)
            if (state == CallState.ACTIVE) {
                Spacer(Modifier.size(8.dp))
                Text(
                    text = formatDuration(durationMs),
                    color = Color.White,
                    fontSize = 20.sp
                )
            }
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(32.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            CircleButton(
                icon = if (muted) Icons.Outlined.MicOff else Icons.Outlined.Mic,
                tint = if (muted) Color(0xFFE74C3C) else Color.White.copy(alpha = 0.2f),
                contentDescription = stringResource(if (muted) R.string.call_unmute else R.string.call_mute),
                onClick = { calls.setMuted(!muted) }
            )
            CircleButton(
                icon = Icons.Outlined.CallEnd,
                tint = Color(0xFFE53935),
                size = 72.dp,
                contentDescription = stringResource(R.string.call_end),
                onClick = { calls.end(); onDismiss() }
            )
            CircleButton(
                icon = if (speaker) Icons.Outlined.VolumeUp else Icons.Outlined.VolumeDown,
                tint = Color.White.copy(alpha = 0.2f),
                contentDescription = stringResource(if (speaker) R.string.call_earpiece else R.string.call_speaker),
                onClick = { calls.setSpeaker(!speaker) }
            )
        }

        Spacer(Modifier.size(32.dp))
    }
}

@Composable
fun IncomingCallScreen(
    peerName: String,
    onAccept: () -> Unit,
    onDecline: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(24.dp),
        verticalArrangement = Arrangement.SpaceBetween,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.size(60.dp))
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Avatar(name = peerName)
            Spacer(Modifier.size(16.dp))
            Text(peerName, color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.size(8.dp))
            Text(stringResource(R.string.call_incoming), color = Color.Gray)
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(48.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            CircleButton(
                icon = Icons.Outlined.CallEnd,
                tint = Color(0xFFE53935),
                size = 84.dp,
                contentDescription = stringResource(R.string.call_decline),
                onClick = onDecline
            )
            CircleButton(
                icon = Icons.Outlined.Mic, // Placeholder — real phone icon in Stage 7 polish
                tint = Color(0xFF2ECC71),
                size = 84.dp,
                contentDescription = stringResource(R.string.call_accept),
                onClick = onAccept
            )
        }
        Spacer(Modifier.size(32.dp))
    }
}

// MARK: - Private components

@Composable
private fun Avatar(name: String) {
    Box(
        modifier = Modifier
            .size(120.dp)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.08f)),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = name.take(1).uppercase(),
            color = Color.White,
            fontSize = 40.sp,
            fontWeight = FontWeight.Bold
        )
    }
}

@Composable
private fun CircleButton(
    icon: ImageVector,
    tint: Color,
    contentDescription: String?,
    onClick: () -> Unit,
    size: androidx.compose.ui.unit.Dp = 56.dp
) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(tint),
        contentAlignment = Alignment.Center
    ) {
        IconButton(onClick = onClick) {
            Icon(icon, contentDescription = contentDescription, tint = Color.White)
        }
    }
}

@Composable
private fun stateLabel(state: CallState): String = when (state) {
    CallState.OUTGOING_PENDING  -> stringResource(R.string.chat_connecting)
    CallState.OUTGOING_RINGING  -> "Calling…"
    CallState.INCOMING          -> stringResource(R.string.call_incoming)
    CallState.ACTIVE            -> stringResource(R.string.chat_connected)
    CallState.ENDED, CallState.IDLE -> ""
}

private fun formatDuration(ms: Long): String {
    val total = (ms / 1000).toInt()
    return "%02d:%02d".format(total / 60, total % 60)
}
