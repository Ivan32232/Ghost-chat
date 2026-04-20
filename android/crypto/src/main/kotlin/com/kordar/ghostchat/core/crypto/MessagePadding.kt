package com.kordar.ghostchat.core.crypto

import java.security.SecureRandom
import java.util.Base64

object MessagePadding {

    /** Pad: 4-char length prefix + base64(message) + random padding to 256-byte boundary */
    fun pad(message: String, deterministicPadByte: Byte? = null): ByteArray {
        val b64 = Base64.getEncoder().encodeToString(message.toByteArray(Charsets.UTF_8))
        val lenPrefix = "%04d".format(b64.length)
        val content = (lenPrefix + b64).toByteArray(Charsets.UTF_8)
        val padTo = if (content.isEmpty()) 256 else ((content.size + 255) / 256) * 256
        val padLen = padTo - content.size

        val padding = if (deterministicPadByte != null) {
            ByteArray(padLen) { deterministicPadByte }
        } else {
            ByteArray(padLen).also { SecureRandom().nextBytes(it) }
        }
        return content + padding
    }

    /** Unpad: read 4-char length prefix, extract base64, decode */
    fun unpad(padded: ByteArray): String {
        if (padded.size < 4) return ""
        val lenStr = String(padded, 0, 4, Charsets.UTF_8)
        val b64Len = lenStr.toIntOrNull() ?: return ""
        if (padded.size < 4 + b64Len) return ""
        val b64Str = String(padded, 4, b64Len, Charsets.UTF_8)
        return String(Base64.getDecoder().decode(b64Str), Charsets.UTF_8)
    }
}
