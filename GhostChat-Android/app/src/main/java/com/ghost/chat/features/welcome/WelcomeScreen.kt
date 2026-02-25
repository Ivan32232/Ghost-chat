package com.ghost.chat.features.welcome

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.ui.theme.*

@Composable
fun WelcomeScreen(
    privacyMode: Boolean,
    onPrivacyModeChange: (Boolean) -> Unit,
    onCreateRoom: () -> Unit,
    onJoinRoom: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenContacts: () -> Unit
) {
    var roomInput by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Top bar: Contacts + Settings
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            IconButton(onClick = onOpenContacts) {
                Icon(Icons.Default.People, contentDescription = "Contacts", tint = GhostBlue)
            }
            IconButton(onClick = onOpenSettings) {
                Icon(Icons.Default.Settings, contentDescription = "Settings", tint = GhostGray)
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        // Logo "G"
        Box(
            modifier = Modifier
                .size(80.dp)
                .clip(CircleShape)
                .background(GhostSurface),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "G",
                fontSize = 36.sp,
                fontWeight = FontWeight.Bold,
                color = GhostBlue
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Title
        Text(
            text = "Ghost",
            fontSize = 32.sp,
            fontWeight = FontWeight.Bold,
            color = GhostWhite
        )

        Spacer(modifier = Modifier.height(8.dp))

        // Subtitle
        Text(
            text = stringResource(R.string.welcome_subtitle),
            fontSize = 14.sp,
            color = GhostGray,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(40.dp))

        // New Chat button
        Button(
            onClick = onCreateRoom,
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = GhostBlue)
        ) {
            Text(
                text = stringResource(R.string.welcome_new_chat),
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Join room input
        OutlinedTextField(
            value = roomInput,
            onValueChange = { roomInput = it },
            placeholder = { Text(stringResource(R.string.welcome_enter_code), color = GhostGray) },
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = GhostBlue,
                unfocusedBorderColor = GhostGrayLight,
                focusedTextColor = GhostWhite,
                unfocusedTextColor = GhostWhite,
                cursorColor = GhostBlue
            ),
            singleLine = true
        )

        Spacer(modifier = Modifier.height(12.dp))

        // Join button
        Button(
            onClick = { onJoinRoom(roomInput) },
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = GhostSurface),
            enabled = roomInput.isNotBlank()
        ) {
            Text(
                text = stringResource(R.string.welcome_join),
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Privacy mode toggle
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Icon(
                Icons.Default.Shield,
                contentDescription = null,
                tint = if (privacyMode) GhostGreen else GhostGray,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = stringResource(R.string.welcome_privacy_mode),
                fontSize = 14.sp,
                color = if (privacyMode) GhostGreen else GhostGray
            )
            Spacer(modifier = Modifier.width(8.dp))
            Switch(
                checked = privacyMode,
                onCheckedChange = onPrivacyModeChange,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = GhostGreen,
                    checkedTrackColor = GhostGreen.copy(alpha = 0.3f),
                    uncheckedThumbColor = GhostGray,
                    uncheckedTrackColor = GhostGrayLight
                )
            )
        }

        Spacer(modifier = Modifier.weight(1f))
    }
}
