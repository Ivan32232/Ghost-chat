package com.kordar.ghostchat.features.chat

import androidx.compose.foundation.background
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
import androidx.compose.material.icons.outlined.Call
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Radar
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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.models.ConnectionState

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
    val listState = rememberLazyListState()

    DisposableEffect(Unit) {
        viewModel.start()
        onDispose { viewModel.stop() }
    }

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
    ) {
        // Header
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
            items(messages, key = { it.id }) { msg -> ChatBubble(msg) }
        }

        InputBar(
            value = draft,
            onValueChange = { viewModel.updateDraft(it) },
            onSend = { viewModel.send() }
        )
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
private fun InputBar(value: String, onValueChange: (String) -> Unit, onSend: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(12.dp)
    ) {
        val colors = TextFieldDefaults.colors(
            focusedContainerColor = Color.White.copy(alpha = 0.08f),
            unfocusedContainerColor = Color.White.copy(alpha = 0.08f),
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedTextColor = Color.White,
            unfocusedTextColor = Color.White
        )
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            placeholder = { Text(stringResource(R.string.chat_type_message), color = Color.Gray) },
            colors = colors,
            shape = RoundedCornerShape(20.dp),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            singleLine = false,
            modifier = Modifier.weight(1f)
        )
        Spacer(Modifier.size(10.dp))
        IconButton(onClick = onSend) {
            Icon(
                Icons.AutoMirrored.Outlined.Send,
                contentDescription = stringResource(R.string.chat_send),
                tint = Color.White,
                modifier = Modifier.size(28.dp)
            )
        }
    }
}
