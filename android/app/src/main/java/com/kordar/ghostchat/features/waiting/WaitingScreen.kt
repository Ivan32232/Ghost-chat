package com.kordar.ghostchat.features.waiting

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.models.ConnectionState

/**
 * Shown right after [ConnectionManager.createRoom] succeeds. Surfaces the room
 * id + share/copy CTAs. When the peer joins (state → WEB_RTC or ENCRYPTED)
 * we auto-advance; when the user cancels, we pop back to Welcome.
 */
@Composable
fun WaitingScreen(
    roomId: String,
    connection: ConnectionManager,
    onAdvance: () -> Unit,
    onCancel: () -> Unit,
    vm: WaitingViewModel = hiltViewModel()
) {
    val context = LocalContext.current
    val state by connection.state.collectAsState()
    val hasRemotePeer by connection.hasRemotePeer.collectAsState()
    val copied by vm.copiedFeedbackVisible.collectAsState()

    // Authoritative advance: stay on Waiting until the signaling server confirms
    // the other side is actually in the room. Local DataChannel events are
    // insufficient (the host's local DC fires OPEN even when alone — the
    // regression we're fixing). Watch hasRemotePeer + state separately so this
    // re-fires on either change.
    LaunchedEffect(hasRemotePeer, state) {
        if (hasRemotePeer) {
            onAdvance()
            return@LaunchedEffect
        }
        if (state == ConnectionState.DISCONNECTED) onCancel()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(24.dp)
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxSize()
        ) {
            Spacer(Modifier.weight(1f))

            Box(
                modifier = Modifier
                    .size(96.dp)
                    .background(Color.White.copy(alpha = 0.06f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.Outlined.HourglassEmpty,
                    contentDescription = null,
                    tint = Color.White.copy(alpha = 0.7f),
                    modifier = Modifier.size(42.dp)
                )
            }

            Text(
                text = stringResource(R.string.waiting_title),
                color = Color.White,
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold
            )

            Text(
                text = vm.displayId(roomId),
                color = Color.Gray,
                fontFamily = FontFamily.Monospace,
                fontSize = 15.sp,
                modifier = Modifier
                    .background(Color.White.copy(alpha = 0.04f), RoundedCornerShape(50))
                    .padding(horizontal = 14.dp, vertical = 10.dp)
            )

            Button(
                onClick = {
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, vm.shareUrl(roomId))
                    }
                    context.startActivity(Intent.createChooser(intent, null))
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.White,
                    contentColor = Color.Black
                ),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp)
            ) {
                Icon(Icons.Outlined.Share, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.size(10.dp))
                Text(stringResource(R.string.waiting_share), fontWeight = FontWeight.SemiBold)
            }

            Button(
                onClick = { vm.copy(roomId) },
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.White.copy(alpha = 0.08f),
                    contentColor = Color.White
                ),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp)
            ) {
                Icon(
                    if (copied) Icons.Filled.Check else Icons.Outlined.ContentCopy,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(Modifier.size(10.dp))
                Text(
                    if (copied) stringResource(R.string.waiting_copied)
                    else stringResource(R.string.waiting_copy)
                )
            }

            Text(
                text = stringResource(R.string.waiting_hint),
                color = Color.Gray,
                fontSize = 13.sp,
                modifier = Modifier.padding(horizontal = 8.dp)
            )

            Spacer(Modifier.weight(1f))

            TextButton(onClick = {
                connection.leave()
                onCancel()
            }) {
                Text(stringResource(R.string.waiting_cancel), color = Color.Gray)
            }
        }
    }
}
