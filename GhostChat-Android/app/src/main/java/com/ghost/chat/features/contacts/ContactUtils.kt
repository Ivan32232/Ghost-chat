package com.ghost.chat.features.contacts

import androidx.compose.ui.graphics.Color
import java.security.MessageDigest

/// Deterministic avatar color from identity key (same palette as iOS)
val avatarColors = listOf(
    Color(0xFF5E5CE6), // Indigo
    Color(0xFFFF375F), // Pink
    Color(0xFFFF9F0A), // Orange
    Color(0xFF30D158), // Green
    Color(0xFF0A84FF), // Blue
    Color(0xFFBF5AF2), // Purple
    Color(0xFFFF453A), // Red
    Color(0xFF64D2FF), // Cyan
    Color(0xFFFFD60A), // Yellow
    Color(0xFFAC8E68), // Brown
)

fun avatarColor(identityKey: ByteArray): Color {
    if (identityKey.isEmpty()) return avatarColors[0]
    val digest = MessageDigest.getInstance("SHA-256")
    val hash = digest.digest(identityKey)
    val index = (hash[0].toInt() and 0xFF) % avatarColors.size
    return avatarColors[index]
}

/// SHA-256 of identity key → first 8 bytes as hex (same as iOS)
fun formatFingerprint(keyData: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val hash = digest.digest(keyData)
    return hash.take(8).joinToString(" ") { "%02X".format(it) }
}
