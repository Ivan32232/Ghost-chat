import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var contacts: ContactManager
    @EnvironmentObject var localization: LocalizationManager
    @EnvironmentObject var deepLink: DeepLinkRouter

    @State private var joinInput: String = ""
    @State private var showContacts = false
    @State private var showSettings = false
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var isJoining = false

    /// Navigation stack managed via `NavigationPath` so we can push Waiting
    /// → Connecting → Chat without juggling multiple `@State Bool` flags.
    @State private var path: [WelcomeRoute] = []

    /// Routes we can push from this screen.
    enum WelcomeRoute: Hashable {
        case waiting(roomId: String)
        case connecting
        case chat
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 32) {
                    header
                    Spacer(minLength: 0)
                    title
                    createButton
                    joinField
                    Spacer()
                    contactsEntry
                }
                .padding(24)
            }
            .preferredColorScheme(.dark)
            .navigationDestination(for: WelcomeRoute.self) { route in
                switch route {
                case .waiting(let id):
                    WaitingView(
                        roomId: id,
                        onAdvance: { path = [.connecting] },
                        onCancel: { path.removeAll() }
                    )
                case .connecting:
                    ConnectingView(
                        onAdvance: { path = [.chat] },
                        onCancel: { error in
                            path.removeAll()
                            if let error { errorMessage = error }
                        }
                    )
                case .chat:
                    ChatView()
                }
            }
            .navigationDestination(isPresented: $showContacts) {
                ContactsView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Error", isPresented: errorBinding) {
                Button(localization.localized("action.done")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                localization.localized("deep_link.prompt.title"),
                isPresented: deepLinkAlertBinding
            ) {
                Button(localization.localized("deep_link.prompt.cancel"), role: .cancel) {
                    deepLink.clear()
                }
                Button(localization.localized("deep_link.prompt.confirm")) {
                    let id = deepLink.pendingRoomId
                    deepLink.clear()
                    if let id { startJoin(id) }
                }
            } message: {
                Text(localization.localized("deep_link.prompt.message"))
            }
        }
        .onChange(of: path) { newPath in
            // If ConnectingView popped back to root with an error, leave the
            // ConnectionManager in a clean state.
            if newPath.isEmpty && isCreating == false && isJoining == false {
                connection.leave()
            }
        }
    }

    // MARK: - Components

    private var header: some View {
        HStack {
            Text(localization.localized("app.name"))
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(localization.localized("welcome.settings"))
        }
    }

    private var title: some View {
        VStack(spacing: 8) {
            Text(localization.localized("app.name"))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("End-to-end encrypted. Zero-identity.")
                .font(.footnote)
                .foregroundStyle(.gray)
        }
    }

    private var createButton: some View {
        Button {
            guard !isCreating, !isJoining else { return }
            isCreating = true
            Task {
                do {
                    try await connection.createRoom()
                    // Wait for the server to mint us a room id (roomCreated event).
                    let id = try await waitForRoomId()
                    isCreating = false
                    path = [.waiting(roomId: id)]
                } catch {
                    isCreating = false
                    connection.leave()
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            Group {
                if isCreating {
                    ProgressView().tint(.black)
                } else {
                    Text(localization.localized("welcome.create"))
                        .font(.headline)
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.white.opacity(isCreating ? 0.6 : 1.0),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isCreating || isJoining)
    }

    private var joinField: some View {
        HStack(spacing: 12) {
            TextField(localization.localized("welcome.join_placeholder"), text: $joinInput)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            Button(localization.localized("welcome.join")) {
                Task { await join() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
            .foregroundStyle(.white)
        }
    }

    private var contactsEntry: some View {
        Button {
            showContacts = true
        } label: {
            HStack {
                Image(systemName: "person.2.fill")
                Text(localization.localized("welcome.contacts"))
                Spacer()
                Text("\(contacts.contacts.count)")
                    .foregroundStyle(.gray)
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    /// Poll `connection.roomId` for up to 10 seconds waiting for the server
    /// to respond with a `roomCreated` event after `createRoom()`.
    private func waitForRoomId(timeout: TimeInterval = 10) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let id = connection.roomId, !id.isEmpty { return id }
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        throw ConnectionManager.Error.unexpectedState
    }

    private func join() async {
        guard !isCreating, !isJoining else { return }
        let id = extractRoomID(from: joinInput)
        guard Room.isValidID(id) else {
            errorMessage = localization.localized("error.invalid_room")
            return
        }
        isJoining = true
        startJoin(id)
        isJoining = false
    }

    /// Kicks off `joinRoom(id)` and immediately pushes ConnectingView.
    /// Used both by the manual join flow and the deep-link confirmation.
    private func startJoin(_ id: String) {
        path = [.connecting]
        Task {
            do {
                try await connection.joinRoom(id)
            } catch {
                path.removeAll()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func extractRoomID(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let parsed = DeepLinkRouter.parse(url) {
            return parsed
        }
        if trimmed.hasPrefix("ghostchat://room/") {
            return String(trimmed.dropFirst("ghostchat://room/".count))
        }
        return trimmed
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var deepLinkAlertBinding: Binding<Bool> {
        Binding(get: { deepLink.pendingRoomId != nil }, set: { if !$0 { deepLink.clear() } })
    }
}
