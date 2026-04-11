package com.ghost.chat.core.filetransfer

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import android.webkit.MimeTypeMap
import com.ghost.chat.models.ControlMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/// Manages chunked file transfer over encrypted DataChannel
/// Splits files into 16KB chunks, tracks progress, reassembles on receive
class FileTransferService(private val context: Context) {

    companion object {
        const val CHUNK_SIZE = 2 * 1024  // 2KB per chunk — after encrypt+base64+JSON stays under ~6KB (safe for DataChannel)
        const val MAX_FILE_SIZE = 100L * 1024 * 1024  // 100MB

        /// Sanitize file name to prevent path traversal attacks
        fun sanitizeFileName(name: String): String {
            return name
                .replace(Regex("[/\\\\]"), "_")
                .replace("..", "_")
                .replace("\u0000", "")
        }

        fun mimeTypeFromName(name: String): String {
            val ext = name.substringAfterLast('.', "").lowercase()
            return when (ext) {
                "jpg", "jpeg" -> "image/jpeg"
                "png" -> "image/png"
                "gif" -> "image/gif"
                "webp" -> "image/webp"
                "heic", "heif" -> "image/heic"
                "mp4", "m4v" -> "video/mp4"
                "mov" -> "video/quicktime"
                "mp3" -> "audio/mpeg"
                "m4a" -> "audio/mp4"
                "wav" -> "audio/wav"
                "pdf" -> "application/pdf"
                "doc", "docx" -> "application/msword"
                "zip" -> "application/zip"
                "txt" -> "text/plain"
                else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
            }
        }

        fun isImage(mimeType: String) = mimeType.startsWith("image/")
        fun isVideo(mimeType: String) = mimeType.startsWith("video/")

        fun formatSize(bytes: Long): String {
            if (bytes < 1024) return "$bytes B"
            if (bytes < 1024 * 1024) return String.format("%.1f KB", bytes / 1024.0)
            if (bytes < 1024 * 1024 * 1024) return String.format("%.1f MB", bytes / (1024.0 * 1024))
            return String.format("%.1f GB", bytes / (1024.0 * 1024 * 1024))
        }
    }

    data class OutgoingTransfer(
        val fileId: String,
        val fileName: String,
        val fileSize: Long,
        val mimeType: String,
        val totalChunks: Int,
        var sentChunks: Int = 0,
        var cachedData: ByteArray? = null  // Retained for retransmit
    )

    data class IncomingTransfer(
        val fileId: String,
        val fileName: String,
        val fileSize: Long,
        val mimeType: String,
        val totalChunks: Int,
        val receivedChunks: ConcurrentHashMap<Int, ByteArray> = ConcurrentHashMap()
    ) {
        val isComplete: Boolean get() = receivedChunks.size == totalChunks
        val progress: Double get() = if (totalChunks > 0) receivedChunks.size.toDouble() / totalChunks else 0.0
    }

    private val outgoing = ConcurrentHashMap<String, OutgoingTransfer>()
    private val incoming = ConcurrentHashMap<String, IncomingTransfer>()
    private val retryCounters = ConcurrentHashMap<String, Int>()

    /// Dedicated coroutine scope for outbound chunk sends. Using IO dispatcher
    /// prevents blocking Main while encrypt+send runs; SupervisorJob keeps
    /// individual transfers independent so one failure doesn't cancel others.
    private val sendScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val activeSendJobs = ConcurrentHashMap<String, Job>()

    /// Callback: send a control message (will be encrypted by ChatViewModel).
    /// Legacy sync hook — used for non-file control messages.
    var onSendControl: ((ControlMessage) -> Unit)? = null

    /// Suspend callback for file chunks. CRITICAL: must suspend until
    /// encrypt+DataChannel send actually completes, otherwise chunks queue
    /// up on the dispatcher without real backpressure.
    var onSendControlAsync: (suspend (ControlMessage) -> Unit)? = null

    /// Provider: returns DataChannel bufferedAmount for backpressure
    /// Set by ChatViewModel to allow checking SCTP buffer fill level
    var bufferedAmountProvider: (() -> Long)? = null

    /// Callback: progress update for outgoing file (fileId, progress 0-1)
    var onSendProgress: ((String, Double) -> Unit)? = null

    /// Callback: progress update for incoming file (fileId, progress 0-1)
    var onReceiveProgress: ((String, Double) -> Unit)? = null

    /// Callback: file fully received (fileId, localPath, fileName, fileSize, mimeType)
    var onFileReceived: ((String, String, String, Long, String) -> Unit)? = null

    /// Callback: file fully sent
    var onFileSent: ((String) -> Unit)? = null

    /// Callback: file transfer error (fileId, error description)
    var onFileError: ((String, String) -> Unit)? = null

    // MARK: - Send

    /// Start sending a file from a content URI. Returns metadata for creating the chat message.
    fun sendFile(uri: Uri): SendResult? {
        val resolver = context.contentResolver
        val data = resolver.openInputStream(uri)?.use { it.readBytes() } ?: run {
            Log.e("GhostChat", "[FileTransfer] sendFile: FAILED to read data from URI: $uri")
            return null
        }

        // Reject files exceeding size limit
        if (data.size.toLong() > MAX_FILE_SIZE) {
            Log.e("GhostChat", "[FileTransfer] sendFile: REJECTED — size ${data.size} exceeds $MAX_FILE_SIZE")
            return null
        }

        val fileId = UUID.randomUUID().toString()
        val fileName = getFileName(uri) ?: "file"
        val fileSize = data.size.toLong()
        val mimeType = resolver.getType(uri) ?: mimeTypeFromName(fileName)
        val totalChunks = maxOf(1, (data.size + CHUNK_SIZE - 1) / CHUNK_SIZE)

        // Save file locally first
        val localPath = saveToFilesDir(data, "${fileId}_${fileName}") ?: return null

        val transfer = OutgoingTransfer(fileId, fileName, fileSize, mimeType, totalChunks, cachedData = data)
        outgoing[fileId] = transfer

        // Send file-start via async callback so it's ordered before first chunk
        Log.d("GhostChat", "[FileTransfer] sendFile: sending fileStart — fileId=$fileId, name=$fileName, size=$fileSize, chunks=$totalChunks, hasAsync=${onSendControlAsync != null}")

        // Launch a SINGLE coroutine that awaits each send in order.
        // Chunks are sent one-at-a-time with suspend — this is the REAL backpressure
        // (previous thread() + fire-and-forget viewModelScope.launch pattern queued
        // all chunks onto Main dispatcher without ever blocking on DataChannel).
        val job = sendScope.launch {
            val asyncSend = onSendControlAsync
            if (asyncSend == null) {
                Log.e("GhostChat", "[FileTransfer] sendFile: NO async send callback — aborting")
                onFileError?.invoke(fileId, "Internal error: no async send callback")
                outgoing.remove(fileId)
                return@launch
            }

            // file-start first
            asyncSend(ControlMessage.FileStart(fileId, fileName, fileSize, mimeType, totalChunks))

            val backpressureThreshold = 16384L  // 16KB SCTP buffer ceiling
            for (i in 0 until totalChunks) {
                // Backpressure: wait if DataChannel buffer is filling up. This is now
                // accurate because the previous iteration already flushed through.
                val getBuffered = bufferedAmountProvider
                if (getBuffered != null) {
                    var waitCount = 0
                    val timeoutCount = 600 // 600 * 50ms = 30 seconds
                    while (getBuffered() > backpressureThreshold && waitCount < timeoutCount) {
                        delay(50)
                        waitCount++
                    }
                    if (waitCount >= timeoutCount) {
                        Log.e("GhostChat", "[FileTransfer] ABORT: backpressure timeout after 30s at chunk $i/$totalChunks, buffered=${getBuffered()}")
                        onFileError?.invoke(fileId, "Transfer stalled — backpressure timeout at chunk $i/$totalChunks")
                        outgoing[fileId]?.cachedData = null
                        outgoing.remove(fileId)
                        activeSendJobs.remove(fileId)
                        return@launch
                    }
                }

                val start = i * CHUNK_SIZE
                val end = minOf(start + CHUNK_SIZE, data.size)
                val chunk = data.copyOfRange(start, end)
                val base64 = Base64.encodeToString(chunk, Base64.NO_WRAP)

                // AWAIT actual encrypt + DataChannel send — suspend until done
                asyncSend(ControlMessage.FileChunk(fileId, i, base64))
                outgoing[fileId]?.sentChunks = i + 1

                val progress = (i + 1).toDouble() / totalChunks
                onSendProgress?.invoke(fileId, progress)

                // Log every 10th chunk for large transfers
                if ((i + 1) % 10 == 0 || i == totalChunks - 1) {
                    val buffered = getBuffered?.invoke() ?: 0L
                    Log.d("GhostChat", "[FileTransfer] Sent chunk ${i + 1}/$totalChunks, buffered=$buffered")
                }
            }

            asyncSend(ControlMessage.FileComplete(fileId))
            // Clear cached data to prevent memory leak (retransmit can re-read from disk)
            outgoing[fileId]?.cachedData = null
            activeSendJobs.remove(fileId)
            onFileSent?.invoke(fileId)
        }
        activeSendJobs[fileId] = job

        return SendResult(fileId, localPath, fileName, fileSize, mimeType)
    }

    data class SendResult(
        val fileId: String,
        val localPath: String,
        val fileName: String,
        val fileSize: Long,
        val mimeType: String
    )

    /// Save file from raw bytes (for saved messages mode)
    fun saveFileLocally(data: ByteArray, fileName: String): LocalSaveResult? {
        val fileId = UUID.randomUUID().toString()
        val storedName = "${fileId}_${fileName}"
        val localPath = saveToFilesDir(data, storedName) ?: return null
        val mimeType = mimeTypeFromName(fileName)
        return LocalSaveResult(fileId, localPath, mimeType)
    }

    data class LocalSaveResult(val fileId: String, val localPath: String, val mimeType: String)

    // MARK: - Retransmit

    /// Handle incoming file-retransmit request — resend missing chunks
    fun handleRetransmitRequest(fileId: String, indices: List<Int>) {
        val transfer = outgoing[fileId] ?: run {
            Log.e("GhostChat", "[FileTransfer] handleRetransmitRequest — no outgoing transfer for fileId=$fileId")
            return
        }
        // Try cached data first, fall back to disk
        val data = transfer.cachedData ?: try {
            val localFile = File(getFilesDir(), "${fileId}_${transfer.fileName}")
            if (localFile.exists()) localFile.readBytes() else null
        } catch (e: Exception) {
            Log.e("GhostChat", "[FileTransfer] handleRetransmitRequest — failed to read file: ${e.message}")
            null
        }
        if (data == null) {
            Log.e("GhostChat", "[FileTransfer] handleRetransmitRequest — no data available for fileId=$fileId")
            return
        }

        for (i in indices) {
            // Bounds check: validate index is within valid range
            if (i < 0 || i >= transfer.totalChunks) {
                Log.w("GhostChat", "[FileTransfer] handleRetransmitRequest — index $i out of bounds (totalChunks=${transfer.totalChunks}), skipping")
                continue
            }
            val start = i * CHUNK_SIZE
            if (start >= data.size) {
                Log.w("GhostChat", "[FileTransfer] handleRetransmitRequest — start offset $start >= data size ${data.size}, skipping")
                continue
            }
            val end = minOf(start + CHUNK_SIZE, data.size)
            val chunk = data.copyOfRange(start, end)
            val base64 = Base64.encodeToString(chunk, Base64.NO_WRAP)
            onSendControl?.invoke(ControlMessage.FileChunk(fileId, i, base64))
        }
        // Re-send file-complete after retransmit
        onSendControl?.invoke(ControlMessage.FileComplete(fileId))
    }

    // MARK: - Receive

    fun handleFileStart(fileId: String, name: String, size: Long, mimeType: String, totalChunks: Int) {
        Log.d("GhostChat", "[FileTransfer] handleFileStart: fileId=$fileId, name=$name, size=$size, mimeType=$mimeType, totalChunks=$totalChunks")
        // Reject files exceeding size limit
        if (size > MAX_FILE_SIZE) {
            Log.e("GhostChat", "[FileTransfer] handleFileStart: REJECTED — size $size exceeds $MAX_FILE_SIZE")
            return
        }

        val safeName = sanitizeFileName(name)
        incoming[fileId] = IncomingTransfer(fileId, safeName, size, mimeType, totalChunks)
    }

    fun handleFileChunk(fileId: String, index: Int, base64Data: String) {
        val transfer = incoming[fileId] ?: return
        // Bounds check: reject out-of-range indices (malicious peer or wire corruption).
        if (index < 0 || index >= transfer.totalChunks) {
            Log.w("GhostChat", "[FileTransfer] handleFileChunk REJECTED: out-of-bounds index=$index, totalChunks=${transfer.totalChunks}")
            return
        }
        val chunkData = Base64.decode(base64Data, Base64.NO_WRAP)
        transfer.receivedChunks[index] = chunkData
        onReceiveProgress?.invoke(fileId, transfer.progress)

        // Log every 10th chunk received for debugging large transfers
        if (transfer.receivedChunks.size % 10 == 0 || transfer.receivedChunks.size == transfer.totalChunks) {
            Log.d("GhostChat", "[FileTransfer] Received chunk ${transfer.receivedChunks.size}/${transfer.totalChunks} for $fileId")
        }
    }

    fun handleFileComplete(fileId: String) {
        val transfer = incoming[fileId] ?: return

        // Check for missing chunks → request retransmit (up to 2 attempts)
        val missingChunks = (0 until transfer.totalChunks).filter { transfer.receivedChunks[it] == null }
        if (missingChunks.isNotEmpty()) {
            val retryKey = "retry_$fileId"
            val retryCount = retryCounters[retryKey] ?: 0
            if (retryCount < 2) {
                retryCounters[retryKey] = retryCount + 1
                Log.d("GhostChat", "[FileTransfer] handleFileComplete — missing ${missingChunks.size} chunks, requesting retransmit (attempt ${retryCount + 1})")
                onSendControl?.invoke(ControlMessage.FileRetransmit(fileId, missingChunks))
                return  // Wait for retransmitted chunks + another file-complete
            }
            // Max retries exceeded — fail
            val errorMsg = "Missing ${missingChunks.size} chunks after retransmit"
            Log.e("GhostChat", "[FileTransfer] handleFileComplete — $errorMsg for fileId=$fileId")
            incoming.remove(fileId)
            retryCounters.remove(retryKey)
            onFileError?.invoke(fileId, errorMsg)
            return
        }

        retryCounters.remove("retry_$fileId")
        incoming.remove(fileId)

        // Assemble chunks in order
        val assembled = ByteArray(transfer.receivedChunks.values.sumOf { it.size })
        var offset = 0
        for (i in 0 until transfer.totalChunks) {
            val chunk = transfer.receivedChunks[i]
            if (chunk == null) {
                onFileError?.invoke(fileId, "Missing chunk $i during assembly")
                return
            }
            System.arraycopy(chunk, 0, assembled, offset, chunk.size)
            offset += chunk.size
        }

        // Save to files directory
        val storedName = "${fileId}_${transfer.fileName}"
        val localPath = saveToFilesDir(assembled, storedName) ?: return
        onFileReceived?.invoke(fileId, localPath, transfer.fileName, transfer.fileSize, transfer.mimeType)
    }

    // MARK: - Cleanup

    fun cancelAll() {
        activeSendJobs.values.forEach { runCatching { it.cancel() } }
        activeSendJobs.clear()
        outgoing.clear()
        incoming.clear()
        retryCounters.clear()
    }

    /// Call from ChatViewModel.onCleared() to release the supervisor scope
    fun shutdown() {
        cancelAll()
        runCatching { sendScope.cancel() }
    }

    // MARK: - File Storage

    private fun getFilesDir(): File {
        val dir = File(context.filesDir, "transferred_files")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun saveToFilesDir(data: ByteArray, fileName: String): String? {
        val safeName = sanitizeFileName(fileName)
        return try {
            val file = File(getFilesDir(), safeName)

            // Verify resolved path is within files directory (defense in depth)
            val basePath = getFilesDir().canonicalPath
            if (!file.canonicalPath.startsWith(basePath)) return null

            file.writeBytes(data)
            safeName  // relative path
        } catch (e: Exception) {
            null
        }
    }

    fun localFile(relativePath: String): File {
        val safePath = sanitizeFileName(relativePath)
        return File(getFilesDir(), safePath)
    }

    fun deleteFile(relativePath: String) {
        val safePath = sanitizeFileName(relativePath)
        val file = File(getFilesDir(), safePath)

        // Verify path is within files directory
        val basePath = getFilesDir().canonicalPath
        if (!file.canonicalPath.startsWith(basePath)) return

        file.delete()
    }

    fun deleteAllFiles() {
        getFilesDir().deleteRecursively()
    }

    // MARK: - Helpers

    private fun getFileName(uri: Uri): String? {
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) return cursor.getString(idx)
            }
        }
        return uri.lastPathSegment
    }

}
