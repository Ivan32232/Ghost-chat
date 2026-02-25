import SwiftUI

@main
struct GhostChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var biometricAuth = BiometricAuthService()
    @StateObject private var localization = LocalizationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(viewModel: viewModel)

                // Biometric lock overlay
                if biometricAuth.isEnabled && !biometricAuth.isUnlocked {
                    LockScreenView(auth: biometricAuth)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                await viewModel.restoreSession()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    // Don't lock during active call
                    if viewModel.callState == .idle {
                        biometricAuth.lock()
                    }
                }
            }
            .environmentObject(biometricAuth)
            .environmentObject(localization)
            .id(localization.refreshToken)
        }
    }

    /// H3: Deep link — show confirmation before joining
    private func handleIncomingURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        guard let roomId = components?.queryItems?.first(where: { $0.name == "room" })?.value,
              !roomId.isEmpty else { return }

        guard viewModel.screen == .welcome else { return }

        // Show confirmation instead of auto-joining
        viewModel.pendingDeepLinkRoom = roomId
    }
}

/// Root view — маршрутизация экранов
struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.screen {
            case .welcome:
                WelcomeView(viewModel: viewModel)

            case .waiting:
                WaitingView(viewModel: viewModel)

            case .connecting:
                ConnectingView(viewModel: viewModel)

            case .chat:
                ChatView(viewModel: viewModel)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.screen)
        // H3: Deep link confirmation dialog
        .alert(
            String(localized: "deeplink.title"),
            isPresented: Binding(
                get: { viewModel.pendingDeepLinkRoom != nil },
                set: { if !$0 { viewModel.pendingDeepLinkRoom = nil } }
            )
        ) {
            Button(String(localized: "deeplink.join")) {
                if let roomId = viewModel.pendingDeepLinkRoom {
                    viewModel.pendingDeepLinkRoom = nil
                    Task { await viewModel.joinRoom(roomId) }
                }
            }
            Button(String(localized: "deeplink.cancel"), role: .cancel) {
                viewModel.pendingDeepLinkRoom = nil
            }
        } message: {
            if let roomId = viewModel.pendingDeepLinkRoom {
                Text(String(format: String(localized: "deeplink.message"), String(roomId.prefix(8))))
            }
        }
    }
}

// MARK: - Waiting Screen

struct WaitingView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var recentContacts: [Contact] = []
    @State private var selectedContact: Contact?
    @State private var showInviteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Верхняя часть — статус + invite
            VStack(spacing: 20) {
                Spacer().frame(height: 24)

                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)

                Text("waiting.title")
                    .font(.title3)
                    .foregroundStyle(.white)

                // Room ID + actions
                if let roomId = viewModel.roomId {
                    VStack(spacing: 12) {
                        Text(roomId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.gray)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        HStack(spacing: 12) {
                            // Copy link (M5: auto-expire clipboard after 60s)
                            Button {
                                if let link = viewModel.getInviteLink() {
                                    UIPasteboard.general.setItems(
                                        [["public.utf8-plain-text": link]],
                                        options: [.expirationDate: Date().addingTimeInterval(60)]
                                    )
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.title3)
                                    Text("waiting.copy")
                                        .font(.caption)
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                            }

                            // Share
                            ShareLink(
                                item: viewModel.getInviteLink() ?? "",
                                subject: Text("Ghost Chat"),
                                message: Text("waiting.shareMessage")
                            ) {
                                VStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.title3)
                                    Text("waiting.share")
                                        .font(.caption)
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }

            // Контакты — всегда показываем секцию
            VStack(alignment: .leading, spacing: 8) {
                Text("waiting.recentContacts")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .textCase(.uppercase)
                    .padding(.horizontal, 24)

                if recentContacts.isEmpty {
                    // Пустое состояние
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.slash")
                            .font(.title2)
                            .foregroundStyle(.gray.opacity(0.4))
                        Text("contacts.empty")
                            .font(.caption)
                            .foregroundStyle(.gray.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(recentContacts) { contact in
                                WaitingContactRow(contact: contact) {
                                    selectedContact = contact
                                    showInviteConfirm = true
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            .padding(.top, 24)

            Spacer()

            Button {
                viewModel.leave()
            } label: {
                Text("waiting.cancel")
                    .foregroundStyle(.red)
            }
            .padding(.bottom, 24)
        }
        .background(Color.black)
        .task {
            loadRecentContacts()
        }
        .alert(
            String(localized: "waiting.inviteConfirm.title"),
            isPresented: $showInviteConfirm
        ) {
            Button(String(localized: "waiting.inviteConfirm.send")) {
                if selectedContact != nil, let link = viewModel.getInviteLink() {
                    UIPasteboard.general.setItems(
                        [["public.utf8-plain-text": link]],
                        options: [.expirationDate: Date().addingTimeInterval(60)]
                    )
                }
                selectedContact = nil
            }
            Button(String(localized: "settings.cancel"), role: .cancel) {
                selectedContact = nil
            }
        } message: {
            if let contact = selectedContact {
                Text(String(format: String(localized: "waiting.inviteConfirm.message"), contact.label))
            }
        }
    }

    private func loadRecentContacts() {
        let store = ContactStore()
        recentContacts = (try? store.fetchAll()) ?? []
    }
}

/// Строка контакта в списке ожидания — тап вызывает действие
struct WaitingContactRow: View {
    let contact: Contact
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text(String(contact.label.prefix(1)).uppercased())
                            .font(.headline)
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.label)
                        .foregroundStyle(.white)
                        .font(.subheadline)

                    if let lastSession = contact.lastSessionAt {
                        Text(lastSession, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }

                Spacer()

                Text("waiting.invite")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Connecting Screen

struct ConnectingView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)

            Text("connecting.title")
                .font(.title3)
                .foregroundStyle(.white)

            Text("connecting.subtitle")
                .font(.caption)
                .foregroundStyle(.gray)

            Spacer()

            Button {
                viewModel.leave()
            } label: {
                Text("connecting.cancel")
                    .foregroundStyle(.red)
            }
            .padding(.bottom, 24)
        }
        .background(Color.black)
    }
}
