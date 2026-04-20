import Combine
import Foundation

/// Thin orchestrator that wires ConnectionManager + MessageManager + CallManager + ContactManager
/// into what `ChatView` needs. No business logic lives here — it all delegates.
@MainActor
final class ChatViewModel: ObservableObject {

    @Published var draft: String = ""

    let connection: ConnectionManager
    let messages: MessageManager
    let calls: CallManager
    let contacts: ContactManager

    private var incomingTask: Task<Void, Never>?
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
        guard incomingTask == nil else { return }
        incomingTask = Task { [weak self] in
            guard let self else { return }
            for await text in self.connection.incomingText {
                _ = await self.messages.received(text: text)
            }
        }
    }

    func stop() {
        incomingTask?.cancel()
        incomingTask = nil
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
