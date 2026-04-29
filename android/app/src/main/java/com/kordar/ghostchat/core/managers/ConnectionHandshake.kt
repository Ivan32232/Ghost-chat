package com.kordar.ghostchat.core.managers

import com.kordar.ghostchat.core.crypto.GhostChatCrypto
import com.kordar.ghostchat.core.crypto.KeyExchangePacket
import com.kordar.ghostchat.core.crypto.PqExchangePacket
import com.kordar.ghostchat.core.crypto.RatchetRole
import com.kordar.ghostchat.core.webrtc.GhostRTC
import com.kordar.ghostchat.models.ConnectionState
import com.kordar.ghostchat.models.Role
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Handshake-coordination helper for [ConnectionManager]. Owns the KeyExchange /
 * PqExchange lifecycle so the manager itself stays under the 400-LOC cap.
 */
internal class ConnectionHandshake(
    private val cryptoProvider: () -> GhostChatCrypto?,
    private val rtcProvider: () -> GhostRTC?,
    private val roleProvider: () -> Role?,
    private val stateFlow: MutableStateFlow<ConnectionState>,
    private val safetyNumberFlow: MutableStateFlow<String?>,
    private val peerIdentityFlow: MutableStateFlow<ByteArray?>,
    private val onEncrypted: suspend () -> Unit = {}
) {
    suspend fun startKeyExchangeOverDataChannel() {
        val crypto = cryptoProvider() ?: return
        val rtc = rtcProvider() ?: return
        val role = roleProvider() ?: return
        runCatching {
            val ratchetRole = if (role == Role.HOST) RatchetRole.HOST else RatchetRole.GUEST
            val pkt = crypto.beginHandshake(ratchetRole)
            rtc.send(KeyExchangePacket.encode(pkt).toByteArray(Charsets.UTF_8))
        }.onFailure { stateFlow.value = ConnectionState.DISCONNECTED }
    }

    suspend fun completeHandshake(pkt: KeyExchangePacket?) {
        val role = roleProvider() ?: return
        val crypto = cryptoProvider() ?: return
        val rtc = rtcProvider() ?: return
        pkt ?: return
        var becameEncrypted = false
        runCatching {
            if (role == Role.HOST) {
                val ready = crypto.completeAsHost(pkt)
                peerIdentityFlow.value = java.util.Base64.getDecoder().decode(pkt.identityKey)
                if (ready) {
                    stateFlow.value = ConnectionState.ENCRYPTED
                    safetyNumberFlow.value = runCatching { crypto.safetyNumber() }.getOrNull()
                    becameEncrypted = true
                }
            } else {
                val pqOut = crypto.completeAsGuest(pkt)
                peerIdentityFlow.value = java.util.Base64.getDecoder().decode(pkt.identityKey)
                stateFlow.value = ConnectionState.ENCRYPTED
                safetyNumberFlow.value = runCatching { crypto.safetyNumber() }.getOrNull()
                if (pqOut != null) {
                    rtc.send(PqExchangePacket.encode(pqOut).toByteArray(Charsets.UTF_8))
                }
                becameEncrypted = true
            }
        }
        if (becameEncrypted) onEncrypted()
    }

    suspend fun completePq(pkt: PqExchangePacket) {
        val crypto = cryptoProvider() ?: return
        runCatching {
            crypto.completePQ(java.util.Base64.getDecoder().decode(pkt.pqCiphertext))
            stateFlow.value = ConnectionState.ENCRYPTED
            safetyNumberFlow.value = runCatching { crypto.safetyNumber() }.getOrNull()
        }
        onEncrypted()
    }
}
