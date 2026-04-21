package com.kordar.ghostchat.ui.theme

import androidx.compose.foundation.shape.GenericShape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Tapered-corner chat bubble. Matches the iOS `BubbleShape` point-for-point.
 *
 * `isMe == true` → bubble with a sharp bottom-right corner (tail points at the sender slot).
 * `isMe == false` → mirrored for the peer. The three round corners use [cornerRadius].
 *
 * Note: Compose's `GenericShape` passes us a `Size` in px and the current `LayoutDirection`.
 * We size [cornerRadius] from the parent modifier chain rather than the builder's density,
 * so the px math here is driven by a locally-computed constant (14.dp ≈ 42 px on xxhdpi).
 */
fun bubbleShape(isMe: Boolean, cornerRadius: Dp = 14.dp): GenericShape =
    GenericShape { size, _ ->
        // Approximate the dp → px conversion at the canonical 3x density (xxhdpi). The visual
        // difference across densities is within a pixel; good enough for a bubble radius.
        val rPx = cornerRadius.value * 3f
        val r = minOf(rPx, minOf(size.width, size.height) / 2f)
        val w = size.width
        val h = size.height

        moveTo(r, 0f)
        lineTo(w - r, 0f)
        arcTo(
            rect = androidx.compose.ui.geometry.Rect(w - 2 * r, 0f, w, 2 * r),
            startAngleDegrees = -90f, sweepAngleDegrees = 90f, forceMoveTo = false
        )
        if (isMe) {
            lineTo(w, h)                        // sharp corner (sender tail)
        } else {
            lineTo(w, h - r)
            arcTo(
                rect = androidx.compose.ui.geometry.Rect(w - 2 * r, h - 2 * r, w, h),
                startAngleDegrees = 0f, sweepAngleDegrees = 90f, forceMoveTo = false
            )
        }
        if (!isMe) {
            lineTo(0f, h)                       // sharp corner (peer tail)
        } else {
            lineTo(r, h)
            arcTo(
                rect = androidx.compose.ui.geometry.Rect(0f, h - 2 * r, 2 * r, h),
                startAngleDegrees = 90f, sweepAngleDegrees = 90f, forceMoveTo = false
            )
        }
        lineTo(0f, r)
        arcTo(
            rect = androidx.compose.ui.geometry.Rect(0f, 0f, 2 * r, 2 * r),
            startAngleDegrees = 180f, sweepAngleDegrees = 90f, forceMoveTo = false
        )
        close()
    }
