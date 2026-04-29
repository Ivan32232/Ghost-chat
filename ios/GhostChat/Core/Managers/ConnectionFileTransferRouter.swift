import Foundation

/// File-transfer control-message routing for `ConnectionManager`. Extracted so the
/// manager itself stays under the 400-LOC cap — this handler owns no state (the
/// `fileTransfer` service and the timeout tracker live on the manager), it just
/// pattern-matches `ControlMessage` variants and calls back into the caller.
@MainActor
extension ConnectionManager {

    func routeFileControl(_ ctrl: ControlMessage) async {
        switch ctrl {
        case .fileStart(let fileId, let name, let size, let mimeType, let totalChunks):
            _ = fileTransfer.handleStart(
                fileId: fileId, name: name, size: size,
                mimeType: mimeType, totalChunks: totalChunks
            )
            chunkTimeout.arm(fileId: fileId)

        case .fileChunk(let fileId, let index, let data):
            _ = fileTransfer.handleChunk(fileId: fileId, index: index, base64Data: data)
            chunkTimeout.progressed(fileId: fileId)

        case .fileComplete(let fileId, let sha256):
            let event = fileTransfer.handleComplete(fileId: fileId, expectedSha256Hex: sha256)
            switch event {
            case .completed(let file):
                chunkTimeout.cancel(fileId: fileId)
                fileContinuation?.yield(file)
            case .missing(_, let indices):
                try? await sendControl(.fileRetransmit(fileId: fileId, indices: indices))
            case .integrityFailure:
                chunkTimeout.cancel(fileId: fileId)
                abortContinuation?.yield(fileId)
            default:
                break
            }

        case .fileRetransmit(let fileId, let indices):
            let messages = fileTransfer.retransmitMessages(fileId: fileId, indices: indices)
            for msg in messages {
                try? await awaitSendSlotForRoute()
                try? await sendControl(msg)
            }

        case .pushToken, .notifyToken:
            // Peer-supplied push tokens — surface to subscribers so save-contact
            // flows can persist them. P0 #1 wiring.
            handlePeerToken(ctrl)

        case .renegotiate, .callRequest, .callResponse, .callEnd,
             .securityAlert, .messageAck, .messageRead, .ready,
             .typing, .capabilities,
             .messageDelete, .messageEdit, .messagePin:
            // Other control types are handled in their own phases — ignore here so they
            // don't get mistaken for text messages.
            break
        }
    }
}
