package com.kordar.ghostchat.features.connecting

import com.kordar.ghostchat.models.ConnectionState

/**
 * Pure state-machine helpers for [ConnectingScreen]. Mirrors iOS
 * `ConnectingViewModel` semantics so both platforms show the same 4-phase
 * progress (Signaling → WebRTC → Key exchange → Encrypted).
 *
 * Not a Hilt view model — nothing to inject, nothing to scope. Static
 * helpers keep the tests trivial and identical to iOS `static` methods.
 */
object ConnectingViewModel {

    /**
     * One visual step on the progress list. Order of declaration matters —
     * Kotlin's built-in [Enum.ordinal] feeds the progress comparison in
     * `PhaseRow`.
     */
    enum class Phase(val localizedKey: String) {
        SIGNALING("connecting_step_signaling"),
        WEB_RTC("connecting_step_webrtc"),
        KEY_EXCHANGE("connecting_step_key_exchange"),
        ENCRYPTED("connecting_step_encrypted");
    }

    /**
     * Map a transport state to the "currently active" progress step.
     * `.connecting` / `.signaling` → step 0; `.webRTC` → step 2 (past WebRTC,
     * now crunching keys); `.encrypted` → step 3.
     */
    fun phase(state: ConnectionState): Phase = when (state) {
        ConnectionState.DISCONNECTED,
        ConnectionState.CONNECTING,
        ConnectionState.CONNECTED,
        ConnectionState.SIGNALING -> Phase.SIGNALING
        ConnectionState.WEB_RTC   -> Phase.KEY_EXCHANGE
        ConnectionState.ENCRYPTED -> Phase.ENCRYPTED
    }

    fun shouldAdvanceToChat(state: ConnectionState): Boolean =
        state == ConnectionState.ENCRYPTED

    /**
     * `.disconnected` only means failure if the transport actually got going
     * at some point — initial disconnected on view appear is just the
     * pre-start position and must not bounce the user away.
     */
    fun isTerminalFailure(state: ConnectionState, hadConnection: Boolean): Boolean =
        hadConnection && state == ConnectionState.DISCONNECTED
}
