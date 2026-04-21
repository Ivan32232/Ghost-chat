package com.kordar.ghostchat.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.hilt.navigation.compose.hiltViewModel
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.core.network.CertificatePinning
import com.kordar.ghostchat.core.security.RootDetector

@Composable
fun SecurityDashboardScreen(
    connection: ConnectionManager,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val state by connection.state.collectAsState()
    val roomId by connection.roomId.collectAsState()
    val safetyNumber by connection.safetyNumber.collectAsState()
    val context = LocalContext.current
    val rootReport = remember(context) { RootDetector().detect(context) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        SectionTitle("Connection")
        StatRow("State", state.name)
        StatRow("Room", roomId ?: "—")
        StatRow("Safety number", safetyNumber ?: "—", monospace = true)

        Spacer(Modifier.padding(top = 12.dp))
        SectionTitle("Certificate pinning")
        StatRow("Host", CertificatePinning.HOST)
        StatRow("Primary", CertificatePinning.PRIMARY_PIN, monospace = true)
        StatRow("Backup",  CertificatePinning.BACKUP_PIN, monospace = true)

        Spacer(Modifier.padding(top = 12.dp))
        SectionTitle("Encryption")
        StatRow("Protocol", "Signal Double Ratchet")
        StatRow("Curve",    "P-256 (BouncyCastle)")
        StatRow("AEAD",     "AES-256-GCM")
        StatRow("PQ", "ECDH only")

        Spacer(Modifier.padding(top = 12.dp))
        SectionTitle("Device integrity")
        StatRow(
            "Root check",
            if (rootReport.status == com.kordar.ghostchat.core.security.RootStatus.SAFE)
                "Safe"
            else
                "Suspicious"
        )
        for (marker in rootReport.markers) {
            StatRow("", marker, monospace = true)
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text = text.uppercase(),
        color = Color.Gray,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(vertical = 6.dp)
    )
}

@Composable
private fun StatRow(label: String, value: String, monospace: Boolean = false) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(modifier = Modifier.padding(vertical = 6.dp)) {
            Text(label, color = Color.Gray, modifier = Modifier.weight(1f))
            Text(
                text = value,
                color = Color.White,
                fontSize = if (monospace) 13.sp else 14.sp
            )
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
    }
}
