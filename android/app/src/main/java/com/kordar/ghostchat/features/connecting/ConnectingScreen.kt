package com.kordar.ghostchat.features.connecting

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kordar.ghostchat.R
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.models.ConnectionState

/**
 * Handshake progress. Shown between [WaitingScreen] (or [WelcomeScreen] for
 * join-by-link) and [ChatScreen]. Pops back to Welcome on terminal failure.
 */
@Composable
fun ConnectingScreen(
    connection: ConnectionManager,
    onAdvance: () -> Unit,
    onCancel: (errorKeyId: Int?) -> Unit
) {
    val state by connection.state.collectAsState()
    val hasRemotePeer by connection.hasRemotePeer.collectAsState()
    val peerIdentity by connection.peerIdentity.collectAsState()
    var hadConnection by remember { mutableStateOf(state != ConnectionState.DISCONNECTED) }

    // Re-evaluate the advance gate on every change to any of the three signals
    // that compose the invariant. Compose's [LaunchedEffect] keys ensure each
    // change re-runs the predicate.
    LaunchedEffect(state, hasRemotePeer, peerIdentity) {
        if (state != ConnectionState.DISCONNECTED) hadConnection = true
        if (ConnectingViewModel.shouldAdvanceToChat(
                state = state, hasRemotePeer = hasRemotePeer, peerIdentity = peerIdentity)) {
            onAdvance()
            return@LaunchedEffect
        }
        if (ConnectingViewModel.isTerminalFailure(state, hadConnection)) {
            onCancel(R.string.connecting_error)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(24.dp)
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterVertically),
            modifier = Modifier.fillMaxSize()
        ) {
            Spacer(Modifier.weight(1f))

            CircularProgressIndicator(color = Color.White)

            Text(
                text = stringResource(R.string.connecting_title),
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold
            )

            val active = ConnectingViewModel.phase(state)
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            ) {
                ConnectingViewModel.Phase.values().forEach { phase ->
                    PhaseRow(phase = phase, activePhase = active)
                }
            }

            Spacer(Modifier.weight(1f))

            TextButton(onClick = {
                connection.leave()
                onCancel(null)
            }) {
                Text(stringResource(R.string.connecting_cancel), color = Color.Gray)
            }
        }
    }
}

@Composable
private fun PhaseRow(phase: ConnectingViewModel.Phase, activePhase: ConnectingViewModel.Phase) {
    val isDone    = phase.ordinal < activePhase.ordinal
    val isCurrent = phase == activePhase

    val (icon, tint) = when {
        isDone    -> Icons.Filled.CheckCircle to Color(0xFF30D158)
        isCurrent -> Icons.Outlined.Circle to Color.White
        else      -> Icons.Outlined.RadioButtonUnchecked to Color.Gray.copy(alpha = 0.5f)
    }

    val label = when (phase) {
        ConnectingViewModel.Phase.SIGNALING    -> stringResource(R.string.connecting_step_signaling)
        ConnectingViewModel.Phase.WEB_RTC      -> stringResource(R.string.connecting_step_webrtc)
        ConnectingViewModel.Phase.KEY_EXCHANGE -> stringResource(R.string.connecting_step_key_exchange)
        ConnectingViewModel.Phase.ENCRYPTED    -> stringResource(R.string.connecting_step_encrypted)
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(12.dp))
        Text(
            text = label,
            color = if (isCurrent || isDone) Color.White else Color.Gray,
            fontSize = 14.sp
        )
    }
}
