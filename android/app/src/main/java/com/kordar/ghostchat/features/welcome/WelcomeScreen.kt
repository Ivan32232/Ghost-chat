package com.kordar.ghostchat.features.welcome

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
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
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.R

@Composable
fun WelcomeScreen(
    onOpenWaiting: (roomId: String) -> Unit,
    onOpenConnecting: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenContacts: () -> Unit,
    viewModel: WelcomeViewModel = hiltViewModel()
) {
    val error by viewModel.error.collectAsState()
    val target by viewModel.target.collectAsState()
    val contactsList by viewModel.contacts.contacts.collectAsState()
    val isBusy by viewModel.isBusy.collectAsState()
    val pendingDeepLink by viewModel.deepLink.pendingRoomId.collectAsState()
    var joinInput by remember { mutableStateOf("") }

    LaunchedEffect(target) {
        when (val t = target) {
            is WelcomeViewModel.Target.Waiting -> {
                viewModel.clearTarget()
                onOpenWaiting(t.roomId)
            }
            is WelcomeViewModel.Target.Connecting -> {
                viewModel.clearTarget()
                onOpenConnecting()
            }
            null -> Unit
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(24.dp)
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.app_name),
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onOpenSettings) {
                    Icon(Icons.Outlined.Settings, contentDescription = null, tint = Color.White)
                }
            }

            Spacer(Modifier.weight(1f))

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = stringResource(R.string.app_name),
                    color = Color.White,
                    fontSize = 40.sp,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = "End-to-end encrypted. Zero-identity.",
                    color = Color.Gray,
                    fontSize = 13.sp
                )
            }

            Button(
                onClick = { viewModel.createRoom() },
                enabled = !isBusy,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.White,
                    contentColor = Color.Black,
                    disabledContainerColor = Color.White.copy(alpha = 0.6f),
                    disabledContentColor = Color.Black
                ),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp)
            ) {
                if (isBusy) {
                    CircularProgressIndicator(
                        color = Color.Black,
                        strokeWidth = 2.dp,
                        modifier = Modifier
                            .padding(vertical = 6.dp)
                            .size(20.dp)
                    )
                } else {
                    Text(
                        text = stringResource(R.string.welcome_create),
                        modifier = Modifier.padding(vertical = 6.dp)
                    )
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = joinInput,
                    onValueChange = { joinInput = it },
                    placeholder = { Text(stringResource(R.string.welcome_join_placeholder), color = Color.Gray) },
                    singleLine = true,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.White.copy(alpha = 0.06f),
                        unfocusedContainerColor = Color.White.copy(alpha = 0.06f),
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent
                    ),
                    modifier = Modifier
                        .weight(1f)
                        .padding(end = 8.dp)
                )
                Button(
                    onClick = { viewModel.joinRoom(joinInput) },
                    enabled = !isBusy,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color.White.copy(alpha = 0.2f),
                        contentColor = Color.White,
                        disabledContainerColor = Color.White.copy(alpha = 0.1f),
                        disabledContentColor = Color.White.copy(alpha = 0.5f)
                    )
                ) {
                    Text(stringResource(R.string.welcome_join))
                }
            }

            Spacer(Modifier.weight(1f))

            Button(
                onClick = onOpenContacts,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.White.copy(alpha = 0.04f),
                    contentColor = Color.White
                ),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(
                    Icons.Outlined.Group,
                    contentDescription = null,
                    modifier = Modifier
                        .padding(end = 8.dp)
                        .size(20.dp)
                )
                Text(stringResource(R.string.welcome_contacts))
                Spacer(Modifier.weight(1f))
                Text(contactsList.size.toString(), color = Color.Gray)
            }
        }
    }

    error?.let { message ->
        AlertDialog(
            onDismissRequest = { viewModel.clearError() },
            confirmButton = {
                TextButton(onClick = { viewModel.clearError() }) {
                    Text(stringResource(R.string.action_done))
                }
            },
            title = { Text("Error") },
            text = { Text(message) }
        )
    }

    pendingDeepLink?.let { id ->
        AlertDialog(
            onDismissRequest = { viewModel.cancelDeepLink() },
            title = { Text(stringResource(R.string.deep_link_prompt_title)) },
            text = { Text(stringResource(R.string.deep_link_prompt_message)) },
            confirmButton = {
                TextButton(onClick = { viewModel.confirmDeepLink(id) }) {
                    Text(stringResource(R.string.deep_link_prompt_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.cancelDeepLink() }) {
                    Text(stringResource(R.string.deep_link_prompt_cancel))
                }
            }
        )
    }
}
