package com.kordar.ghostchat.core.crypto

/**
 * Abstracted wall-clock. Lets tests shift time forward/backward deterministically
 * when exercising [ReplayGuard]'s ±5-minute timestamp window. Production uses
 * [SystemClock].
 */
fun interface GhostClock {
    fun nowMs(): Long
}

object SystemClock : GhostClock {
    override fun nowMs(): Long = System.currentTimeMillis()
}
