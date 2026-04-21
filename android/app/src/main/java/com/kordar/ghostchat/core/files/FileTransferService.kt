package com.kordar.ghostchat.core.files

import com.kordar.ghostchat.models.ControlMessage
import java.security.MessageDigest
import java.util.UUID

/**
 * Pure state machine for chunked file transfer over the encrypted DataChannel.
 * Produces [ControlMessage] payloads for sending; reassembles them on the receive
 * side, verifying SHA-256 integrity.
 *
 * Does NOT encrypt or touch the network — `ConnectionManager` wraps each produced
 * [ControlMessage] with `GhostChatCrypto.encrypt` and sends it through the WebRTC
 * data channel, applying backpressure.
 *
 * Mirror of iOS `Core/Files/FileTransferService.swift` — both platforms must
 * produce byte-identical chunks + hash for identical inputs.
 */
class FileTransferService {

    companion object {
        /** Raw bytes per chunk. Must match iOS. */
        const val CHUNK_SIZE: Int = 2048

        /** Android uses `java.util.Base64` (API 26+, our minSdk is 28) to avoid
         *  the URL-safe variant that `android.util.Base64.encodeToString(..., Base64.DEFAULT)`
         *  produces and to stay byte-identical with iOS `Data.base64EncodedString()`. */
        internal val base64Encoder = java.util.Base64.getEncoder()
        internal val base64Decoder = java.util.Base64.getDecoder()
    }

    data class Outbound(
        val fileId: String,
        val name: String,
        val size: Int,
        val mimeType: String,
        val sha256Hex: String,
        val totalChunks: Int,
        val startMessage: ControlMessage,
        val chunkMessages: List<ControlMessage>,
        val completeMessage: ControlMessage
    )

    data class IncomingFile(
        val fileId: String,
        val name: String,
        val mimeType: String,
        val data: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is IncomingFile) return false
            return fileId == other.fileId && name == other.name &&
                    mimeType == other.mimeType && data.contentEquals(other.data)
        }
        override fun hashCode(): Int {
            var r = fileId.hashCode()
            r = 31 * r + name.hashCode()
            r = 31 * r + mimeType.hashCode()
            r = 31 * r + data.contentHashCode()
            return r
        }
    }

    sealed class Event {
        data class Started(val fileId: String) : Event()
        data class Progressed(val fileId: String, val received: Int, val total: Int) : Event()
        data class Completed(val file: IncomingFile) : Event()
        data class IntegrityFailure(val fileId: String) : Event()
        data class Missing(val fileId: String, val indices: List<Int>) : Event()
        data class Unknown(val fileId: String) : Event()
    }

    private data class Inbound(
        val name: String,
        val size: Int,
        val mimeType: String,
        val totalChunks: Int,
        val chunks: MutableMap<Int, ByteArray> = mutableMapOf(),
        val startedAtMs: Long,
        var lastChunkAtMs: Long
    )

    private data class OutboundState(
        val totalChunks: Int,
        val chunkMessages: List<ControlMessage>
    )

    private val inbound = mutableMapOf<String, Inbound>()
    private val outbound = mutableMapOf<String, OutboundState>()

    // MARK: - Outbound

    fun prepareOutbound(data: ByteArray, name: String, mimeType: String): Outbound {
        require(name.isNotEmpty()) { "file name must not be empty" }

        val fileId = UUID.randomUUID().toString()
        val sha256 = sha256Hex(data)
        val chunks = chunked(data, CHUNK_SIZE)
        val start = ControlMessage.FileStart(
            fileId = fileId,
            name = name,
            size = data.size,
            mimeType = mimeType,
            totalChunks = chunks.size
        )
        val chunkMessages: List<ControlMessage> = chunks.mapIndexed { index, raw ->
            ControlMessage.FileChunk(
                fileId = fileId,
                index = index,
                data = base64Encoder.encodeToString(raw)
            )
        }
        val complete = ControlMessage.FileComplete(fileId = fileId, sha256 = sha256)
        outbound[fileId] = OutboundState(totalChunks = chunks.size, chunkMessages = chunkMessages)
        return Outbound(
            fileId = fileId,
            name = name,
            size = data.size,
            mimeType = mimeType,
            sha256Hex = sha256,
            totalChunks = chunks.size,
            startMessage = start,
            chunkMessages = chunkMessages,
            completeMessage = complete
        )
    }

    // MARK: - Inbound

    fun handleStart(
        fileId: String,
        name: String,
        size: Int,
        mimeType: String,
        totalChunks: Int
    ): Event {
        val now = System.currentTimeMillis()
        inbound[fileId] = Inbound(
            name = name, size = size, mimeType = mimeType,
            totalChunks = totalChunks,
            startedAtMs = now, lastChunkAtMs = now
        )
        return Event.Started(fileId)
    }

    fun handleChunk(fileId: String, index: Int, base64Data: String): Event {
        val entry = inbound[fileId] ?: return Event.Unknown(fileId)
        if (index < 0 || index >= entry.totalChunks) return Event.Unknown(fileId)
        val bytes = try {
            base64Decoder.decode(base64Data)
        } catch (_: IllegalArgumentException) {
            return Event.Unknown(fileId)
        }
        entry.chunks[index] = bytes
        entry.lastChunkAtMs = System.currentTimeMillis()
        return Event.Progressed(fileId, received = entry.chunks.size, total = entry.totalChunks)
    }

    fun handleComplete(fileId: String, expectedSha256Hex: String): Event {
        val entry = inbound[fileId] ?: return Event.Unknown(fileId)

        val missing = (0 until entry.totalChunks).filter { !entry.chunks.containsKey(it) }
        if (missing.isNotEmpty()) {
            return Event.Missing(fileId, missing)
        }

        val assembled = ByteArray(entry.size)
        var offset = 0
        for (i in 0 until entry.totalChunks) {
            val c = entry.chunks[i] ?: continue
            System.arraycopy(c, 0, assembled, offset, c.size)
            offset += c.size
        }

        val actual = sha256Hex(assembled)
        if (!actual.equals(expectedSha256Hex, ignoreCase = true)) {
            inbound.remove(fileId)
            return Event.IntegrityFailure(fileId)
        }

        inbound.remove(fileId)
        return Event.Completed(
            IncomingFile(
                fileId = fileId,
                name = entry.name,
                mimeType = entry.mimeType,
                data = assembled
            )
        )
    }

    fun missingChunks(fileId: String): List<Int>? {
        val entry = inbound[fileId] ?: return null
        return (0 until entry.totalChunks).filter { !entry.chunks.containsKey(it) }
    }

    fun cancelInbound(fileId: String) {
        inbound.remove(fileId)
    }

    fun hasInbound(fileId: String): Boolean = inbound.containsKey(fileId)

    /** Re-emit previously-built fileChunk messages for a retransmit request. */
    fun retransmitMessages(fileId: String, indices: List<Int>): List<ControlMessage> {
        val state = outbound[fileId] ?: return emptyList()
        return indices.mapNotNull { i ->
            if (i in 0 until state.chunkMessages.size) state.chunkMessages[i] else null
        }
    }

    fun forgetOutbound(fileId: String) {
        outbound.remove(fileId)
    }

    fun hasOutbound(fileId: String): Boolean = outbound.containsKey(fileId)

    // MARK: - Helpers

    private fun chunked(data: ByteArray, size: Int): List<ByteArray> {
        if (data.isEmpty()) return emptyList()
        val out = ArrayList<ByteArray>((data.size + size - 1) / size)
        var offset = 0
        while (offset < data.size) {
            val end = (offset + size).coerceAtMost(data.size)
            out += data.copyOfRange(offset, end)
            offset = end
        }
        return out
    }

    private fun sha256Hex(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append("%02x".format(b.toInt() and 0xFF))
        return sb.toString()
    }
}
