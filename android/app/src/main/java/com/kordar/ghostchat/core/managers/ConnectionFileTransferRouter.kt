package com.kordar.ghostchat.core.managers

import com.kordar.ghostchat.core.files.ChunkTimeoutTracker
import com.kordar.ghostchat.core.files.FileTransferService
import com.kordar.ghostchat.models.ControlMessage
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * File-transfer control-message routing for [ConnectionManager]. Extracted so the
 * manager itself stays under the 400-LOC cap — this handler owns no state; the
 * [FileTransferService], timeout tracker, and outbound flows all live on the manager.
 */
internal class ConnectionFileTransferRouter(
    private val fileTransfer: () -> FileTransferService,
    private val chunkTimeout: ChunkTimeoutTracker,
    private val incomingFile: MutableSharedFlow<FileTransferService.IncomingFile>,
    private val fileTransferAborted: MutableSharedFlow<String>,
    private val sendControl: suspend (ControlMessage) -> Unit,
    private val awaitSendSlot: suspend () -> Unit
) {

    suspend fun route(ctrl: ControlMessage) {
        val ft = fileTransfer()
        when (ctrl) {
            is ControlMessage.FileStart -> {
                ft.handleStart(
                    fileId = ctrl.fileId, name = ctrl.name, size = ctrl.size,
                    mimeType = ctrl.mimeType, totalChunks = ctrl.totalChunks
                )
                chunkTimeout.arm(ctrl.fileId)
            }

            is ControlMessage.FileChunk -> {
                ft.handleChunk(
                    fileId = ctrl.fileId, index = ctrl.index, base64Data = ctrl.data
                )
                chunkTimeout.progressed(ctrl.fileId)
            }

            is ControlMessage.FileComplete -> {
                val ev = ft.handleComplete(ctrl.fileId, ctrl.sha256)
                when (ev) {
                    is FileTransferService.Event.Completed -> {
                        chunkTimeout.cancel(ctrl.fileId)
                        incomingFile.tryEmit(ev.file)
                    }
                    is FileTransferService.Event.Missing ->
                        runCatching { sendControl(ControlMessage.FileRetransmit(ctrl.fileId, ev.indices)) }
                    is FileTransferService.Event.IntegrityFailure -> {
                        chunkTimeout.cancel(ctrl.fileId)
                        fileTransferAborted.tryEmit(ctrl.fileId)
                    }
                    else -> Unit
                }
            }

            is ControlMessage.FileRetransmit -> {
                val msgs = ft.retransmitMessages(ctrl.fileId, ctrl.indices)
                for (m in msgs) { awaitSendSlot(); runCatching { sendControl(m) } }
            }

            else -> Unit
        }
    }
}
