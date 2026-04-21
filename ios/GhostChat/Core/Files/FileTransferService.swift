import CryptoKit
import Foundation

/// Errors raised by `FileTransferService.prepareOutbound(...)`.
enum FileTransferError: Error, Equatable {
    case emptyName
}

/// Pure state machine for chunked file transfer over the encrypted DataChannel.
/// Produces `ControlMessage` payloads for sending; reassembles them on the
/// receive side, verifying SHA-256 integrity.
///
/// Does NOT encrypt or touch the network — `ConnectionManager` wraps each
/// produced `ControlMessage` with `GhostChatCrypto.encrypt` and sends it
/// through the WebRTC data channel, applying backpressure.
///
/// Mirror of Android `core/files/FileTransferService.kt` — both platforms must
/// produce byte-identical chunks + hash for identical inputs.
final class FileTransferService {

    /// Raw bytes per chunk. Base64 overhead (~33%) + Double Ratchet header keeps
    /// each encrypted frame well under 4 KiB on the wire.
    static let chunkSize = 2048

    struct Outbound: Equatable {
        let fileId: String
        let name: String
        let size: Int
        let mimeType: String
        let sha256Hex: String
        let totalChunks: Int
        let startMessage: ControlMessage
        let chunkMessages: [ControlMessage]
        let completeMessage: ControlMessage
    }

    struct IncomingFile: Equatable {
        let fileId: String
        let name: String
        let mimeType: String
        let data: Data
    }

    enum Event: Equatable {
        case started(fileId: String)
        case progressed(fileId: String, received: Int, total: Int)
        case completed(IncomingFile)
        case integrityFailure(fileId: String)
        case missing(fileId: String, indices: [Int])
        case unknown(fileId: String)
    }

    private struct Inbound {
        let name: String
        let size: Int
        let mimeType: String
        let totalChunks: Int
        var chunks: [Int: Data] = [:]
        var startedAt: Date
        var lastChunkAt: Date
    }

    private struct OutboundState {
        let totalChunks: Int
        let chunkMessages: [ControlMessage]
    }

    private var inbound: [String: Inbound] = [:]
    private var outbound: [String: OutboundState] = [:]

    // MARK: - Outbound

    func prepareOutbound(data: Data, name: String, mimeType: String) throws -> Outbound {
        guard !name.isEmpty else { throw FileTransferError.emptyName }

        let fileId = UUID().uuidString
        let sha256Hex = Self.sha256Hex(data)
        let chunks = Self.chunked(data: data, size: Self.chunkSize)
        let start: ControlMessage = .fileStart(
            fileId: fileId,
            name: name,
            size: data.count,
            mimeType: mimeType,
            totalChunks: chunks.count
        )
        let chunkMessages: [ControlMessage] = chunks.enumerated().map { index, raw in
            .fileChunk(fileId: fileId, index: index, data: raw.base64EncodedString())
        }
        let complete: ControlMessage = .fileComplete(fileId: fileId, sha256: sha256Hex)
        outbound[fileId] = OutboundState(totalChunks: chunks.count, chunkMessages: chunkMessages)

        return Outbound(
            fileId: fileId,
            name: name,
            size: data.count,
            mimeType: mimeType,
            sha256Hex: sha256Hex,
            totalChunks: chunks.count,
            startMessage: start,
            chunkMessages: chunkMessages,
            completeMessage: complete
        )
    }

    // MARK: - Inbound

    @discardableResult
    func handleStart(fileId: String, name: String, size: Int, mimeType: String, totalChunks: Int) -> Event {
        let now = Date()
        inbound[fileId] = Inbound(
            name: name, size: size, mimeType: mimeType,
            totalChunks: totalChunks,
            startedAt: now, lastChunkAt: now
        )
        return .started(fileId: fileId)
    }

    @discardableResult
    func handleChunk(fileId: String, index: Int, base64Data: String) -> Event {
        guard var entry = inbound[fileId] else { return .unknown(fileId: fileId) }
        guard index >= 0, index < entry.totalChunks else { return .unknown(fileId: fileId) }
        guard let bytes = Data(base64Encoded: base64Data) else { return .unknown(fileId: fileId) }

        entry.chunks[index] = bytes
        entry.lastChunkAt = Date()
        inbound[fileId] = entry
        return .progressed(fileId: fileId, received: entry.chunks.count, total: entry.totalChunks)
    }

    @discardableResult
    func handleComplete(fileId: String, expectedSha256Hex: String) -> Event {
        guard let entry = inbound[fileId] else { return .unknown(fileId: fileId) }

        let missing = (0..<entry.totalChunks).filter { entry.chunks[$0] == nil }
        if !missing.isEmpty {
            return .missing(fileId: fileId, indices: missing)
        }

        var data = Data()
        data.reserveCapacity(entry.size)
        for i in 0..<entry.totalChunks {
            if let chunk = entry.chunks[i] { data.append(chunk) }
        }

        let actual = Self.sha256Hex(data)
        if actual.lowercased() != expectedSha256Hex.lowercased() {
            inbound.removeValue(forKey: fileId)
            return .integrityFailure(fileId: fileId)
        }

        inbound.removeValue(forKey: fileId)
        return .completed(IncomingFile(
            fileId: fileId,
            name: entry.name,
            mimeType: entry.mimeType,
            data: data
        ))
    }

    func missingChunks(fileId: String) -> [Int]? {
        guard let entry = inbound[fileId] else { return nil }
        return (0..<entry.totalChunks).filter { entry.chunks[$0] == nil }
    }

    func cancelInbound(fileId: String) {
        inbound.removeValue(forKey: fileId)
    }

    func hasInbound(fileId: String) -> Bool {
        inbound[fileId] != nil
    }

    /// Re-emit previously-built `fileChunk` messages for a retransmit request.
    /// Returns an empty array if the outbound file has already been forgotten.
    func retransmitMessages(fileId: String, indices: [Int]) -> [ControlMessage] {
        guard let state = outbound[fileId] else { return [] }
        return indices.compactMap { i in
            (i >= 0 && i < state.chunkMessages.count) ? state.chunkMessages[i] : nil
        }
    }

    /// Drop the retained outbound chunks; called by `ConnectionManager`
    /// after the transfer has completed on both sides.
    func forgetOutbound(fileId: String) {
        outbound.removeValue(forKey: fileId)
    }

    func hasOutbound(fileId: String) -> Bool {
        outbound[fileId] != nil
    }

    // MARK: - Helpers

    private static func chunked(data: Data, size: Int) -> [Data] {
        guard !data.isEmpty else { return [] }
        var result: [Data] = []
        result.reserveCapacity((data.count + size - 1) / size)
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            result.append(data.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
