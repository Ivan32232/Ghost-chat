package com.ghost.chat.ui.theme

import androidx.compose.ui.graphics.Color

// Ghost Chat dark theme colors — matching web (ghostchat.one) design tokens
val GhostBlack = Color(0xFF0A0A0A)       // --bg
val GhostSurface = Color(0xFF161616)      // --surface
val GhostSurfaceLight = Color(0xFF222222) // --surface-2
val GhostGray = Color(0xFF777777)         // --text-dim
val GhostGrayLight = Color(0xFF2E2E2E)    // --border
val GhostWhite = Color(0xFFF0F0F0)        // --text
val GhostTextSecondary = Color(0xFFD4D4D4) // --text-secondary
val GhostAccent = Color(0xFFE0E0E0)       // --accent (buttons, send)
val GhostGreen = Color(0xFF30D158)        // --green
val GhostBlue = Color(0xFF0A84FF)         // legacy — used sparingly
val GhostRed = Color(0xFFFF453A)          // --red
val GhostYellow = Color(0xFFFFD60A)
val GhostOrange = Color(0xFFFF9F0A)       // --orange
val GhostPurple = Color(0xFFBF5AF2)
val GhostCyan = Color(0xFF5AC8FA)

// Message bubble colors (matching web style)
val GhostSentBubble = Color(0xFFD0D0D0)     // light gray sent bubble
val GhostSentText = Color(0xFF0A0A0A)        // dark text on sent bubble
val GhostReceivedBubble = Color(0xFF222222)  // --surface-2 received bubble

// Accent color options (matching iOS)
val AccentColors = mapOf(
    "blue" to Color(0xFF0A84FF),
    "green" to Color(0xFF34C759),
    "purple" to Color(0xFFBF5AF2),
    "red" to Color(0xFFFF3B30),
    "orange" to Color(0xFFFF9500),
    "yellow" to Color(0xFFFFD60A),
    "pink" to Color(0xFFFF2D55),
    "teal" to Color(0xFF5AC8FA)
)
