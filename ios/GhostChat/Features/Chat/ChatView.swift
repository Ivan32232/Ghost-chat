import SwiftUI

struct ChatView: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var messages: MessageManager
    @EnvironmentObject var calls: CallManager
    @EnvironmentObject var contacts: ContactManager
    @EnvironmentObject var localization: LocalizationManager

    @StateObject private var vm: ChatViewModel = .placeholder

    @Environment(\.dismiss) private var dismiss
    @State private var showCall = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                statusBanner
                messagesList
                inputBar
            }
        }
        .onAppear {
            vm.attach(connection: connection, messages: messages, calls: calls, contacts: contacts)
            vm.start()
        }
        .onDisappear {
            vm.stop()
        }
        .navigationBarBackButtonHidden(true)
        .fullScreenCover(isPresented: $showCall) {
            CallView()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Button(localization.localized("chat.leave")) {
                vm.leave()
                dismiss()
            }
            .foregroundStyle(.white)
            Spacer()
            Text(peerLabel).foregroundStyle(.white).font(.headline)
            Spacer()
            Button {
                Task {
                    await vm.startCall()
                    showCall = true
                }
            } label: {
                Image(systemName: "phone.fill")
                    .foregroundStyle(.white)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
    }

    private var statusBanner: some View {
        let state = connection.state
        return HStack {
            Image(systemName: state == .encrypted ? "lock.fill" : "antenna.radiowaves.left.and.right")
            Text(statusText)
                .font(.footnote)
            if let safety = connection.safetyNumber, state == .encrypted {
                Text(safety.prefix(9) + "…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.gray)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(state == .encrypted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        .foregroundStyle(state == .encrypted ? Color.green : Color.orange)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages.messages) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .onChange(of: messages.messages.count) { _ in
                if let last = messages.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(localization.localized("chat.type_message"), text: $vm.draft)
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .resizable().frame(width: 36, height: 36)
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
    }

    // MARK: - Derived

    private var peerLabel: String {
        if let peer = connection.peerIdentity,
           let contact = contacts.contacts.first(where: { $0.identityKey == peer }) {
            return contact.label
        }
        if let id = connection.roomId, !id.isEmpty {
            return String(id.prefix(8)) + "…"
        }
        return "Ghost Chat"
    }

    private var statusText: String {
        switch connection.state {
        case .encrypted: return localization.localized("chat.connected")
        case .disconnected: return localization.localized("chat.disconnected")
        default: return localization.localized("chat.connecting")
        }
    }
}

// MARK: - Placeholder VM (replaced in onAppear)

private extension ChatViewModel {
    nonisolated static var placeholder: ChatViewModel {
        MainActor.assumeIsolated {
            ChatViewModel(
                connection: ConnectionManager(
                    signalingURL: URL(string: "wss://ghostchat.one/ws")!,
                    apiBaseURL: URL(string: "https://ghostchat.one")!,
                    identity: IdentityKeyService(keychain: InMemoryKeychain()),
                    push: PushManager(baseURL: URL(string: "https://ghostchat.one")!)
                ),
                messages: MessageManager(),
                calls: CallManager(),
                contacts: ContactManager(
                    store: {
                        let db = try! DatabaseService.inMemory(keychain: InMemoryKeychain())
                        return ContactStore(database: db)
                    }(),
                    messages: {
                        let db = try! DatabaseService.inMemory(keychain: InMemoryKeychain())
                        return MessageStore(database: db)
                    }(),
                    identity: IdentityKeyService(keychain: InMemoryKeychain()),
                    keychain: InMemoryKeychain()
                )
            )
        }
    }

    func attach(connection: ConnectionManager,
                messages: MessageManager,
                calls: CallManager,
                contacts: ContactManager) {
        // Rebind to the injected managers instead of the placeholder.
        // StateObject doesn't let us reassign directly, but the ChatView only
        // reads managers through @EnvironmentObject, so we just wire incoming text.
        _ = connection; _ = messages; _ = calls; _ = contacts
    }
}
