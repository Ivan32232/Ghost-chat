package com.kordar.ghostchat.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Phase 7 typography system — mirror of iOS `GhostType`. Material3 text styles are
 * remapped to our chat-native aesthetic: sans-rounded headings, default-weight message
 * bodies, monospace digits for timers + safety numbers.
 */
val GhostTypography: Typography = Typography().run {
    copy(
        titleLarge = TextStyle(
            fontSize = 28.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.SansSerif
        ),
        titleMedium = TextStyle(
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.SansSerif
        ),
        bodyLarge = TextStyle(
            fontSize = 15.sp,
            fontWeight = FontWeight.Normal,
            fontFamily = FontFamily.Default
        ),
        bodyMedium = TextStyle(
            fontSize = 14.sp,
            fontWeight = FontWeight.Normal,
            fontFamily = FontFamily.Default
        ),
        labelLarge = TextStyle(
            fontSize = 16.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace
        ),
        labelMedium = TextStyle(
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Default
        ),
        labelSmall = TextStyle(
            fontSize = 12.sp,
            fontWeight = FontWeight.Normal,
            fontFamily = FontFamily.Default
        )
    )
}
