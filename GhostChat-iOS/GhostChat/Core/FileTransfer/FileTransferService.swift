import Foundation

/// Manages chunked file transfer over encrypted DataChannel
/// Splits files into 16KB chunks, tracks progress, reassembles on receive
final class FileTransferService {

    static let chunkSize = 2 * 1024  // 2KB per chunk — after encrypt+base64+JSON wrapper stays under ~6KB (safe for DataChannel)
    static let maxFileSize: Int64 = 100 * 1024 * 1024  // 100MB

    /// Sanitize file name to prevent path traversal attacks
    private static func sanitizeFileName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "\0", with: "")
    }

    // MARK: - Outgoing transfer state

    struct OutgoingTransfer {
        let fileId: String
        let fileURL: URL
        let fileName: String
        let fileSize: Int64
        let mimeType: String
        let totalChunks: Int
        var sentChunks: Int = 0
        var cachedData: Data?  // Retained for retransmit
    }

    // MARK: - Incoming transfer state

    struct IncomingTransfer {
        let fileId: String
        let fileName: String
        let fileSize: Int64
        let mimeType: String
        let totalChunks: Int
        var receivedChunks: [Int: Data]  // index -> chunk data
        var isComplete: Bool { receivedChunks.count == totalChunks }
        var progress: Double { totalChunks > 0 ? Double(receivedChunks.count) / Double(totalChunks) : 0 }
    }

    private var outgoing: [String: OutgoingTransfer] = [:]
    private var incoming: [String: IncomingTransfer] = [:]
    private var retryCounters: [String: Int] = [:]

    /// Callback: send a control message (will be encrypted by ChatViewModel)
    var onSendControl: ((ControlMessage) -> Void)?
    /// Async version — waits for encrypt+send to complete before returning
    var onSendControlAsync: ((ControlMessage) async -> Void)?

    /// Provider: returns DataChannel bufferedAmount for backpressure
    /// Set by ChatViewModel to allow checking SCTP buffer fill level
    var bufferedAmountProvider: (() -> UInt64)?

    /// Callback: progress update for outgoing file (fileId, progress 0-1)
    var onSendProgress: ((String, Double) -> Void)?

    /// Callback: progress update for incoming file (fileId, progress 0-1)
    var onReceiveProgress: ((String, Double) -> Void)?

    /// Callback: file fully received (fileId, localPath, fileName, fileSize, mimeType)
    var onFileReceived: ((String, String, String, Int64, String) -> Void)?

    /// Callback: file fully sent
    var onFileSent: ((String) -> Void)?

    /// Callback: file transfer failed (fileId, error description)
    var onFileError: ((String, String) -> Void)?

    // MARK: - Send

    /// Start sending a file. Returns the fileId and metadata for creating the chat message.
    func sendFile(url: URL) -> (fileId: String, fileName: String, fileSize: Int64, mimeType: String)? {
        guard let data = try? Data(contentsOf: url) else {
            ghostLog("[FileTransfer] sendFile: FAILED to read data from URL: \(url.lastPathComponent)")
            return nil
        }

        // Reject files exceeding size limit
        if Int64(data.count) > Self.maxFileSize {
            ghostLog("[FileTransfer] sendFile: REJECTED — size \(data.count) exceeds \(Self.maxFileSize)")
            return nil
        }

        let fileId = UUID().uuidString
        let fileName = url.lastPathComponent
        let fileSize = Int64(data.count)
        let mimeType = Self.mimeType(for: url)
        let totalChunks = max(1, Int(ceil(Double(data.count) / Double(Self.chunkSize))))

        // Save file locally first
        let localPath = saveToFilesDir(data: data, fileName: "\(fileId)_\(fileName)")
        guard localPath != nil else { return nil }

        let transfer = OutgoingTransfer(
            fileId: fileId,
            fileURL: url,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            totalChunks: totalChunks
        )
        outgoing[fileId] = transfer

        // Send file-start
        ghostLog("[FileTransfer] sendFile: sending fileStart — fileId=\(fileId), name=\(fileName), size=\(fileSize), chunks=\(totalChunks), onSendControl=\(onSendControl != nil), onSendControlAsync=\(onSendControlAsync != nil)")
        onSendControl?(.fileStart(
            fileId: fileId,
            name: fileName,
            size: fileSize,
            mimeType: mimeType,
            totalChunks: totalChunks
        ))

        // Cache data for retransmit
        outgoing[fileId]?.cachedData = data

        // Send chunks sequentially — AWAIT each send to ensure encrypt+DataChannel completes
        // Uses bufferedAmount-based backpressure to prevent SCTP buffer overflow
        Task { @MainActor [weak self] in
            guard let self else { return }
            let backpressureThreshold: UInt64 = 16384  // 16KB — conservative threshold to prevent SCTP overflow

            for i in 0..<totalChunks {
                // Backpressure: wait if DataChannel SCTP buffer is too full
                if let getBuffered = self.bufferedAmountProvider {
                    var waitCount = 0
                    let timeoutCount = 600 // 600 * 50ms = 30 seconds
                    while getBuffered() > backpressureThreshold && waitCount < timeoutCount {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                        waitCount += 1
                    }
                    if waitCount >= timeoutCount {
                        ghostLog("[FileTransfer] ABORT: backpressure timeout after 30s at chunk \(i)/\(totalChunks), buffered=\(getBuffered())")
                        self.onFileError?(fileId, "Transfer stalled — backpressure timeout at chunk \(i)/\(totalChunks)")
                        self.outgoing[fileId]?.cachedData = nil
                        self.outgoing.removeValue(forKey: fileId)
                        return
                    }
                }

                let start = i * Self.chunkSize
                let end = min(start + Self.chunkSize, data.count)
                let chunk = data[start..<end]
                let base64 = chunk.base64EncodedString()

                // Use async version to wait for encrypt+send
                if let asyncSend = self.onSendControlAsync {
                    await asyncSend(.fileChunk(fileId: fileId, index: i, data: base64))
                } else {
                    self.onSendControl?(.fileChunk(fileId: fileId, index: i, data: base64))
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms fallback
                }
                self.outgoing[fileId]?.sentChunks = i + 1

                let progress = Double(i + 1) / Double(totalChunks)
                self.onSendProgress?(fileId, progress)

                // Log every 10th chunk for debugging large transfers
                if (i + 1) % 10 == 0 || i == totalChunks - 1 {
                    let buffered = self.bufferedAmountProvider?() ?? 0
                    ghostLog("[FileTransfer] Sent chunk \(i + 1)/\(totalChunks), buffered=\(buffered)")
                }
            }

            // Send file-complete
            self.onSendControl?(.fileComplete(fileId: fileId))

            // Clear cached data to free memory (keep outgoing entry for retransmit metadata)
            self.outgoing[fileId]?.cachedData = nil
            self.onFileSent?(fileId)

            // Delayed full cleanup — remove outgoing entry after 60s (retransmit window)
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            self.outgoing.removeValue(forKey: fileId)
        }

        return (fileId, fileName, fileSize, mimeType)
    }

    /// Send file from local data (for saved messages mode — no P2P, just save)
    func saveFileLocally(data: Data, fileName: String) -> (fileId: String, localPath: String, mimeType: String)? {
        let fileId = UUID().uuidString
        let storedName = "\(fileId)_\(fileName)"
        guard let localPath = saveToFilesDir(data: data, fileName: storedName) else { return nil }
        let mimeType = Self.mimeTypeFromName(fileName)
        return (fileId, localPath, mimeType)
    }

    // MARK: - Receive

    /// Handle incoming file-start
    func handleFileStart(fileId: String, name: String, size: Int64, mimeType: String, totalChunks: Int) {
        ghostLog("[FileTransfer] handleFileStart: fileId=\(fileId), name=\(name), size=\(size), mimeType=\(mimeType), totalChunks=\(totalChunks)")
        // Reject files exceeding size limit
        if size > Self.maxFileSize {
            ghostLog("[FileTransfer] handleFileStart: REJECTED — size \(size) exceeds \(Self.maxFileSize)")
            return
        }

        let safeName = Self.sanitizeFileName(name)
        incoming[fileId] = IncomingTransfer(
            fileId: fileId,
            fileName: safeName,
            fileSize: size,
            mimeType: mimeType,
            totalChunks: totalChunks,
            receivedChunks: [:]
        )
    }

    /// Handle incoming file-chunk
    func handleFileChunk(fileId: String, index: Int, base64Data: String) {
        guard var transfer = incoming[fileId],
              let chunkData = Data(base64Encoded: base64Data) else {
            ghostLog("[FileTransfer] handleFileChunk IGNORED: fileId=\(fileId), idx=\(index), hasTransfer=\(incoming[fileId] != nil), b64Size=\(base64Data.count)")
            return
        }

        // Bounds check: reject out-of-range indices (malicious peer or wire corruption).
        // Without this a rogue chunk at idx 9999 would be stored and inflate receivedChunks.count.
        guard index >= 0 && index < transfer.totalChunks else {
            ghostLog("[FileTransfer] handleFileChunk REJECTED: out-of-bounds index=\(index), totalChunks=\(transfer.totalChunks)")
            return
        }

        transfer.receivedChunks[index] = chunkData
        incoming[fileId] = transfer

        onReceiveProgress?(fileId, transfer.progress)

        // Log every 10th chunk received for debugging large transfers
        if transfer.receivedChunks.count % 10 == 0 || transfer.receivedChunks.count == transfer.totalChunks {
            ghostLog("[FileTransfer] Received chunk \(transfer.receivedChunks.count)/\(transfer.totalChunks) for \(fileId)")
        }
    }

    /// Handle incoming file-retransmit request — resend missing chunks
    func handleRetransmitRequest(fileId: String, indices: [Int]) {
        ghostLog("[FileTransfer] handleRetransmitRequest ENTER, fileId=\(fileId), count=\(indices.count)")
        guard let transfer = outgoing[fileId] else {
            ghostLog("[FileTransfer] handleRetransmitRequest IGNORED: no outgoing transfer for \(fileId)")
            return
        }
        guard let data = transfer.cachedData ?? (try? Data(contentsOf: transfer.fileURL)) else {
            ghostLog("[FileTransfer] handleRetransmitRequest FAILED: no data for \(fileId)")
            return
        }

        var resent = 0
        for i in indices {
            // Validate index bounds to prevent out-of-range access
            guard i >= 0 && i < transfer.totalChunks else { continue }
            let start = i * Self.chunkSize
            let end = min(start + Self.chunkSize, data.count)
            guard start < data.count else { continue }
            let chunk = data[start..<end]
            let base64 = chunk.base64EncodedString()
            onSendControl?(.fileChunk(fileId: fileId, index: i, data: base64))
            resent += 1
        }
        // Re-send file-complete after retransmit
        onSendControl?(.fileComplete(fileId: fileId))
        ghostLog("[FileTransfer] handleRetransmitRequest EXIT: resent=\(resent)/\(indices.count)")
    }

    /// Handle incoming file-complete — assemble and save, request retransmit if chunks missing
    func handleFileComplete(fileId: String) {
        ghostLog("[FileTransfer] handleFileComplete ENTER, fileId=\(fileId)")
        guard let transfer = incoming[fileId] else {
            ghostLog("[FileTransfer] handleFileComplete IGNORED: no incoming transfer for \(fileId)")
            return
        }

        // Check for missing chunks → request retransmit (up to 2 attempts)
        let missingIndices = (0..<transfer.totalChunks).filter { transfer.receivedChunks[$0] == nil }
        if !missingIndices.isEmpty {
            let retryKey = "retry_\(fileId)"
            let retryCount = retryCounters[retryKey, default: 0]
            ghostLog("[FileTransfer] handleFileComplete: missing=\(missingIndices.count), retryCount=\(retryCount)")
            if retryCount < 2 {
                retryCounters[retryKey] = retryCount + 1
                ghostLog("[FileTransfer] handleFileComplete: requesting retransmit for \(missingIndices.count) chunks (attempt \(retryCount + 1))")
                onSendControl?(.fileRetransmit(fileId: fileId, indices: missingIndices))
                return  // Wait for retransmitted chunks + another file-complete
            }
            // Max retries exceeded — fail
            ghostLog("[FileTransfer] handleFileComplete FAILED: max retries exceeded, missing=\(missingIndices.count)")
            onFileError?(fileId, "Missing \(missingIndices.count) chunks after retransmit")
            incoming.removeValue(forKey: fileId)
            retryCounters.removeValue(forKey: retryKey)
            return
        }

        retryCounters.removeValue(forKey: "retry_\(fileId)")

        // Assemble chunks in order
        var assembled = Data()
        for i in 0..<transfer.totalChunks {
            guard let chunk = transfer.receivedChunks[i] else {
                onFileError?(fileId, "Missing chunk \(i)/\(transfer.totalChunks)")
                incoming.removeValue(forKey: fileId)
                return
            }
            assembled.append(chunk)
        }

        // Save to files directory
        let storedName = "\(fileId)_\(transfer.fileName)"
        guard let localPath = saveToFilesDir(data: assembled, fileName: storedName) else {
            ghostLog("[FileTransfer] handleFileComplete FAILED: saveToFilesDir failed")
            incoming.removeValue(forKey: fileId)
            return
        }

        incoming.removeValue(forKey: fileId)
        ghostLog("[FileTransfer] handleFileComplete EXIT: file assembled \(assembled.count)b, saved=\(localPath)")
        onFileReceived?(fileId, localPath, transfer.fileName, transfer.fileSize, transfer.mimeType)
    }

    // MARK: - Cleanup

    func cancelAll() {
        outgoing.removeAll()
        incoming.removeAll()
    }

    // MARK: - File Storage

    private static var filesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func saveToFilesDir(data: Data, fileName: String) -> String? {
        let safeName = Self.sanitizeFileName(fileName)
        let url = Self.filesDirectory.appendingPathComponent(safeName)

        // Verify resolved path is within files directory (defense in depth)
        let resolvedPath = url.standardizedFileURL.path
        let basePath = Self.filesDirectory.standardizedFileURL.path
        guard resolvedPath.hasPrefix(basePath) else {
            #if DEBUG
            print("[FileTransfer] Path traversal blocked: \(resolvedPath)")
            #endif
            return nil
        }

        do {
            try data.write(to: url)
            return safeName  // relative path
        } catch {
            #if DEBUG
            print("[FileTransfer] Failed to save file: \(error)")
            #endif
            return nil
        }
    }

    /// Get full URL from relative path
    static func localURL(for relativePath: String) -> URL {
        let safePath = sanitizeFileName(relativePath)
        return filesDirectory.appendingPathComponent(safePath)
    }

    /// Delete file from local storage
    static func deleteFile(at relativePath: String) {
        let safePath = sanitizeFileName(relativePath)
        let url = filesDirectory.appendingPathComponent(safePath)

        // Verify path is within files directory
        let resolvedPath = url.standardizedFileURL.path
        let basePath = filesDirectory.standardizedFileURL.path
        guard resolvedPath.hasPrefix(basePath) else { return }

        try? FileManager.default.removeItem(at: url)
    }

    /// Delete all transferred files
    static func deleteAllFiles() {
        try? FileManager.default.removeItem(at: filesDirectory)
    }

    // MARK: - MIME Type

    static func mimeType(for url: URL) -> String {
        mimeTypeFromName(url.lastPathComponent)
    }

    static func mimeTypeFromName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        case "doc", "docx": return "application/msword"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    static func isImage(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("image/")
    }

    static func isVideo(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("video/")
    }

    /// Human-readable file size
    static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
