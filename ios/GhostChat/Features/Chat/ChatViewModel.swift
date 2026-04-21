import Combine
import Foundation

/// Thin orchestrator that wires ConnectionManager + MessageManager + CallManager + ContactManager
/// into what `ChatView` needs. No business logic lives here — it all delegates.
@MainActor
final class ChatViewModel: ObservableObject {

    @Published var draft: String = ""
    @Published var isRecordingVoice: Bool = false

    let connection: ConnectionManager
    let messages: MessageManager
    let calls: CallManager
    let contacts: ContactManager

    private let voiceRecorder = VoiceRecorder()
    private var incomingTask: Task<Void, Never>?
    private var incomingFileTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(connection: ConnectionManager,
         messages: MessageManager,
         calls: CallManager,
         contacts: ContactManager) {
        self.connection = connection
        self.messages = messages
        self.calls = calls
        self.contacts = contacts
    }

    func start() {
        if incomingTask == nil {
            incomingTask = Task { [weak self] in
                guard let self else { return }
                for await text in self.connection.incomingText {
                    _ = await self.messages.received(text: text)
                }
            }
        }
        if incomingFileTask == nil {
            incomingFileTask = Task { [weak self] in
                guard let self else { return }
                for await file in self.connection.incomingFile {
                    await self.onIncomingFile(file)
                }
            }
        }
    }

    func stop() {
        incomingTask?.cancel(); incomingTask = nil
        incomingFileTask?.cancel(); incomingFileTask = nil
        voiceRecorder.cancel()
        isRecordingVoice = false
    }

    // MARK: - Actions

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let local = messages.send(text: text)
        draft = ""
        do {
            try await connection.sendText(text)
            messages.markDelivered(id: local.id)
        } catch {
            // Leave as pending; UI shows it wasn't delivered.
        }
    }

    // MARK: - Attachments

    /// Kick off an attachment send. The file data is supplied by the caller
    /// (PhotosPicker, document picker, or the VoiceRecorder result).
    func sendAttachment(data: Data, name: String, mimeType: String) async {
        let localURL = Self.writeTempCopy(data: data, preferredName: name)
        let local = messages.sendFile(
            fileId: "", name: name, size: data.count,
            mimeType: mimeType, localPath: localURL?.path
        )
        do {
            let fileId = try await connection.sendFile(data: data, name: name, mimeType: mimeType)
            messages.markDelivered(id: local.id)
            _ = fileId
        } catch {
            // bubble stays pending — retry is a Phase 6 concern.
        }
    }

    func startVoiceRecording() {
        guard !isRecordingVoice else { return }
        do {
            try voiceRecorder.start()
            isRecordingVoice = true
        } catch {
            isRecordingVoice = false
        }
    }

    func stopVoiceRecordingAndSend() async {
        guard isRecordingVoice else { return }
        isRecordingVoice = false
        guard let result = try? voiceRecorder.stop() else { return }
        let timestamp = Int(Date().timeIntervalSince1970)
        let name = "voice-\(timestamp).m4a"
        await sendAttachment(data: result.data, name: name, mimeType: "audio/mp4")
    }

    func cancelVoiceRecording() {
        guard isRecordingVoice else { return }
        voiceRecorder.cancel()
        isRecordingVoice = false
    }

    // MARK: - Inbound files

    private func onIncomingFile(_ file: FileTransferService.IncomingFile) async {
        let url = Self.writeTempCopy(data: file.data, preferredName: file.name)
        _ = messages.receivedFile(
            fileId: file.fileId, name: file.name, size: file.data.count,
            mimeType: file.mimeType, localPath: url?.path
        )
    }

    private static func writeTempCopy(data: Data, preferredName: String) -> URL? {
        let safeName = preferredName.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghost-\(UUID().uuidString)-\(safeName)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func leave() {
        stop()
        connection.leave()
    }

    func startCall() async {
        let handle = contacts.contacts.first(where: { $0.identityKey == connection.peerIdentity })?.label ?? "Ghost Chat"
        try? await calls.startOutgoing(peerName: handle)
    }

    func endCall() async {
        try? await calls.end()
    }
}
