package com.kordar.ghostchat.core.crypto

import java.nio.ByteBuffer
import java.nio.ByteOrder

object WireFormat {

    const val HEADER_SIZE = 73

    data class ParsedHeader(
        val version: Byte,
        val dhPublicKeyRaw: ByteArray,  // 64 bytes
        val pn: Int,
        val n: Int
    )

    /** Build header: version(1) + dhPubKeyRaw(64) + PN(4 BE) + N(4 BE) = 73 bytes */
    fun buildHeader(dhPublicKeyRaw: ByteArray, pn: Int, n: Int): ByteArray {
        val buf = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
        buf.put(0x00.toByte()) // version
        buf.put(dhPublicKeyRaw) // 64 bytes
        buf.putInt(pn)
        buf.putInt(n)
        return buf.array()
    }

    fun parseHeader(data: ByteArray): ParsedHeader {
        require(data.size >= HEADER_SIZE) { "Header too short" }
        val buf = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        val version = buf.get()
        require(version == 0x00.toByte()) { "Invalid header version" }
        val dhPubRaw = ByteArray(64)
        buf.get(dhPubRaw)
        val pn = buf.int
        val n = buf.int
        return ParsedHeader(version, dhPubRaw, pn, n)
    }

    data class ParsedMessage(
        val header: ByteArray,
        val nonce: ByteArray,       // 12 bytes
        val ciphertext: ByteArray,
        val tag: ByteArray          // 16 bytes
    )

    /** Build wire message: headerLen(4 BE) + header + nonce(12) + ciphertext + tag(16) */
    fun buildMessage(header: ByteArray, nonce: ByteArray, ciphertext: ByteArray, tag: ByteArray): ByteArray {
        val buf = ByteBuffer.allocate(4 + header.size + nonce.size + ciphertext.size + tag.size)
            .order(ByteOrder.BIG_ENDIAN)
        buf.putInt(header.size)
        buf.put(header)
        buf.put(nonce)
        buf.put(ciphertext)
        buf.put(tag)
        return buf.array()
    }

    fun parseMessage(data: ByteArray): ParsedMessage {
        require(data.size >= 4) { "Message too short" }
        val buf = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        val headerLen = buf.int
        require(data.size >= 4 + headerLen + 12 + 16) { "Message too short for content" }

        val header = ByteArray(headerLen)
        buf.get(header)
        val nonce = ByteArray(12)
        buf.get(nonce)

        // Remaining = ciphertext + tag(16)
        val remaining = data.size - buf.position()
        val ctLen = remaining - 16
        val ciphertext = ByteArray(ctLen)
        buf.get(ciphertext)
        val tag = ByteArray(16)
        buf.get(tag)

        return ParsedMessage(header, nonce, ciphertext, tag)
    }
}
