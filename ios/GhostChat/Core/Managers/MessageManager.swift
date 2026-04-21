import Combine
import Foundation

/// Sole owner of the in-memory `messages` array. Delivers auto-delete per-message TTL
/// and optionally persists to `MessageStore` when a `contactId` is set (saved contact).
@MainActor
final class MessageManager: ObservableObject {

    @Published private(set) var messages: [ChatMessage] = []

    private let store: MessageStore?
    private var deleteTimers: [String: Timer] = [:]
    private var defaultTTL: TimeInterval
    /// Optional sound cue. Wired through AppServices; nil in headless test fixtures.
    weak var sounds: SoundLibrary?

    var activeContactId: String? {
        didSet { reloadForActiveContact() }
    }

    init(store: MessageStore? = nil, defaultTTL: TimeInterval = MessageTTL.fiveMinutes.rawValue.double) {
        self.store = store
        self.defaultTTL = defaultTTL
    }

    // MARK: - Public API

    func send(text: String) -> ChatMessage {
        var message = ChatMessage(
            contactId: activeContactId ?? "",
            sender: .me,
            text: text,
            isDelivered: false,
            isPending: true
        )
        message = finalize(message, ttl: defaultTTL)
        sounds?.play(.sent)
        return message
    }

    func received(text: String, senderMessageId: String? = nil) -> ChatMessage {
        var message = ChatMessage(
            contactId: activeContactId ?? "",
            sender: .peer,
            text: text,
            isDelivered: true,
            isPending: false,
            senderMessageId: senderMessageId
        )
        message = finalize(message, ttl: defaultTTL)
        sounds?.play(.incomingMessage)
        return message
    }

    /// Create a local "sending…" bubble for an outgoing attachment. The caller
    /// is expected to call `markDelivered(id:)` once `ConnectionManager.sendFile`
    /// resolves.
    func sendFile(fileId: String, name: String, size: Int, mimeType: String, localPath: String?) -> ChatMessage {
        let type: MessageType = (mimeType == "audio/mp4" && name.hasPrefix("voice-")) ? .voice : .file
        var message = ChatMessage(
            contactId: activeContactId ?? "",
            sender: .me,
            text: "",
            type: type,
            isDelivered: false,
            isPending: true,
            fileName: name,
            fileSize: size,
            fileMimeType: mimeType,
            fileLocalPath: localPath,
            fileId: fileId
        )
        message = finalize(message, ttl: defaultTTL)
        return message
    }

    /// Record an incoming attachment once the chunked transfer is assembled.
    func receivedFile(fileId: String, name: String, size: Int, mimeType: String, localPath: String?) -> ChatMessage {
        let type: MessageType = (mimeType == "audio/mp4" && name.hasPrefix("voice-")) ? .voice : .file
        var message = ChatMessage(
            contactId: activeContactId ?? "",
            sender: .peer,
            text: "",
            type: type,
            isDelivered: true,
            isPending: false,
            fileName: name,
            fileSize: size,
            fileMimeType: mimeType,
            fileLocalPath: localPath,
            fileId: fileId
        )
        message = finalize(message, ttl: defaultTTL)
        return message
    }

    func system(_ text: String) {
        let m = ChatMessage(
            contactId: activeContactId ?? "",
            sender: .system,
            text: text,
            type: .system
        )
        _ = finalize(m, ttl: defaultTTL)
    }

    func markDelivered(id: String) {
        update(id: id) { $0.isDelivered = true; $0.isPending = false }
    }

    func markPinned(id: String, pinned: Bool) {
        update(id: id) { $0.isPinned = pinned }
    }

    func remove(id: String) {
        deleteTimers[id]?.invalidate()
        deleteTimers.removeValue(forKey: id)
        messages.removeAll { $0.id == id }
        if let contactId = activeContactId, !contactId.isEmpty {
            try? store?.deleteMessage(id: id)
        }
    }

    func setTTL(_ ttl: MessageTTL) {
        defaultTTL = TimeInterval(ttl.rawValue)
    }

    // MARK: - Private

    private func finalize(_ message: ChatMessage, ttl: TimeInterval) -> ChatMessage {
        messages.append(message)
        if let contactId = activeContactId, !contactId.isEmpty {
            message.contactId == contactId ? (try? store?.append(message)) : nil
        }
        scheduleDelete(for: message.id, after: ttl)
        return message
    }

    private func scheduleDelete(for id: String, after seconds: TimeInterval) {
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.remove(id: id) }
        }
        deleteTimers[id] = t
    }

    private func update(id: String, _ mutator: (inout ChatMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        mutator(&messages[idx])
    }

    private func reloadForActiveContact() {
        deleteTimers.values.forEach { $0.invalidate() }
        deleteTimers.removeAll()
        guard let contactId = activeContactId, !contactId.isEmpty else {
            messages = []
            return
        }
        messages = (try? store?.fetch(contactId: contactId)) ?? []
    }
}

private extension Int {
    var double: TimeInterval { TimeInterval(self) }
}
