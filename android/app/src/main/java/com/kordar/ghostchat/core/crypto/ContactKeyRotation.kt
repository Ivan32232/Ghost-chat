package com.kordar.ghostchat.core.crypto

/**
 * Output of one rotation step. Both peers derive identical keys from the same
 * `sessionSecret`, so there's no wire exchange — each side just runs
 * [ContactKeyRotation.rotate] after the session they shared.
 *
 * Mirror of iOS `RotatedKeyMaterial` in `ContactKeyRotation.swift`.
 */
data class RotatedKeyMaterial(
    /** 32-byte raw scalar for the new P-256 ratchet keypair. */
    val newPrivate: ByteArray,
    /** 65-byte x963 uncompressed public (with the leading 0x04). */
    val newPublicX963: ByteArray,
    /** Prior current-public — slides into the `previousKey` column. */
    val previousPublicX963: ByteArray,
    /** Prior previous-public — slides into `fallbackKey`. `null` on first rotation. */
    val fallbackPublicX963: ByteArray?,
    /** Bumped generation counter (caller's `counter` + 1). */
    val counter: Int
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RotatedKeyMaterial) return false
        if (!newPrivate.contentEquals(other.newPrivate)) return false
        if (!newPublicX963.contentEquals(other.newPublicX963)) return false
        if (!previousPublicX963.contentEquals(other.previousPublicX963)) return false
        if ((fallbackPublicX963 == null) != (other.fallbackPublicX963 == null)) return false
        if (fallbackPublicX963 != null && other.fallbackPublicX963 != null &&
            !fallbackPublicX963.contentEquals(other.fallbackPublicX963)) return false
        if (counter != other.counter) return false
        return true
    }
    override fun hashCode(): Int {
        var r = newPrivate.contentHashCode()
        r = 31 * r + newPublicX963.contentHashCode()
        r = 31 * r + previousPublicX963.contentHashCode()
        r = 31 * r + (fallbackPublicX963?.contentHashCode() ?: 0)
        r = 31 * r + counter
        return r
    }
}

/**
 * Deterministic per-contact key rotation.
 *
 * After every saved-contact session, both parties call [rotate] on the session's
 * shared secret (the final ratchet root key). The function derives a new P-256
 * private key via HKDF-SHA256 with salt `ghost-rot-v1` and info `ghost-rot-seed`
 * — so both sides compute the SAME seed and arrive at the SAME keypair without
 * a wire exchange.
 *
 * The rotated public key is stored on each side's contact record; the prior
 * `publicKey` slides into `previousKey`, and `previousKey` slides into `fallbackKey`.
 * On the next connect, if current → fails → previous → fails → fallback gives
 * us 3 generations of forward continuity across occasional state desync.
 *
 * Byte-identical to iOS `ContactKeyRotation` for any given input.
 */
object ContactKeyRotation {

    /** HKDF-SHA256 with salt `ghost-rot-v1`, info `ghost-rot-seed`, 32 bytes out. */
    fun deriveNextSeed(sessionSecret: ByteArray): ByteArray =
        CryptoUtils.hkdf(
            ikm = sessionSecret,
            salt = "ghost-rot-v1".toByteArray(Charsets.UTF_8),
            info = "ghost-rot-seed".toByteArray(Charsets.UTF_8),
            length = 32
        )

    fun rotate(
        sessionSecret: ByteArray,
        currentPrivate: ByteArray,
        previousPublic: ByteArray,
        fallbackPublic: ByteArray?,
        counter: Int
    ): RotatedKeyMaterial {
        @Suppress("UNUSED_VARIABLE") val _preserved = currentPrivate
        val seed = deriveNextSeed(sessionSecret)
        val safeSeed = clampToP256Range(seed)
        val newKp = CryptoUtils.keyPairFromPrivateBytes(safeSeed)
        return RotatedKeyMaterial(
            newPrivate = safeSeed,
            newPublicX963 = newKp.publicKeyBytes,
            previousPublicX963 = previousPublic,
            fallbackPublicX963 = fallbackPublic,
            counter = counter + 1
        )
    }

    /**
     * Clamp the HKDF-derived 32-byte scalar into `[1, n-1]` for P-256.
     * Clearing the top bit keeps us strictly below the curve order, and a zero
     * scalar is bumped to 1. Byte-identical to iOS `clampToP256Range`.
     */
    private fun clampToP256Range(seed: ByteArray): ByteArray {
        val out = seed.copyOf()
        out[0] = (out[0].toInt() and 0x7F).toByte()
        if (out.all { it == 0.toByte() }) out[31] = 0x01
        return out
    }
}
