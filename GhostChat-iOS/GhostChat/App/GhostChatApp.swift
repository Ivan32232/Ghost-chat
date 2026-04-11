import SwiftUI
import AVFoundation

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

                // Lock overlay (PIN and/or biometric)
                if (biometricAuth.isPinSet || biometricAuth.isEnabled) && !biometricAuth.isUnlocked {
                    LockScreenView(auth: biometricAuth)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .screenshotProtected()
            .preferredColorScheme(.dark)
            .environment(\.layoutDirection, localization.layoutDirection)
            .task {
                // Detect fresh install — UserDefaults are cleared on reinstall, Keychain is not
                let hasLaunched = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
                if !hasLaunched {
                    // Clear Keychain data from previous installation
                    KeychainService.delete(forKey: "biometric_enabled")
                    KeychainService.delete(forKey: "app_pin_hash")
                    KeychainService.delete(forKey: "app_pin_length")
                    KeychainService.delete(forKey: "app_autolock_seconds")
                    KeychainService.delete(forKey: "db_encryption_key")
                    // Destroy database files
                    DatabaseService.destroy()
                    // Mark as launched
                    UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                    // Re-init biometric state
                    biometricAuth.refreshState()
                }

                // Request microphone permission on first launch
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    #if DEBUG
                    print("[GhostChatApp] Microphone permission: \(granted)")
                    #endif
                }

                viewModel.setupPushCallbacks()
                await viewModel.restoreSession()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onChange(of: scenePhase) { newPhase in
                guard viewModel.callState == .idle else { return }
                switch newPhase {
                case .background:
                    biometricAuth.didEnterBackground()
                case .inactive:
                    // On Mac Catalyst, .background may never fire — save timestamp on .inactive too.
                    // On iOS, .inactive fires briefly before .background, so .background will overwrite.
                    biometricAuth.saveBackgroundTimestamp()
                case .active:
                    biometricAuth.didEnterForeground()
                @unknown default:
                    break
                }
            }
            .environmentObject(biometricAuth)
            .environmentObject(localization)
            .id(localization.refreshToken)
        }
    }

    /// H3: Deep link — show confirmation before joining
    private func handleIncomingURL(_ url: URL) {
        var roomId: String?

        // Format 1: https://ghostchat.one/?room=ROOM_ID
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        if let queryRoom = components?.queryItems?.first(where: { $0.name == "room" })?.value {
            roomId = queryRoom
        }
        // Format 2: ghostchat://room/ROOM_ID (host="room", path="/ROOM_ID")
        else if url.scheme == "ghostchat", url.host == "room" {
            roomId = url.pathComponents.dropFirst().first
        }

        guard let roomId, !roomId.isEmpty, isValidRoomId(roomId) else { return }

        // If in active chat, ignore deep link
        guard viewModel.screen != .chat else { return }

        // If in waiting/connecting (e.g. from restoreSession), leave first
        if viewModel.screen != .welcome {
            viewModel.leave()
        }

        // Show confirmation instead of auto-joining
        viewModel.pendingDeepLinkRoom = roomId
    }

    /// Validate room ID format — base64url, 64 chars (48 random bytes encoded)
    private func isValidRoomId(_ id: String) -> Bool {
        let pattern = "^[A-Za-z0-9_-]{64}$"
        return id.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Root view — маршрутизация экранов
struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

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
        // Chat invite banner + dialog
        .overlay(alignment: .top) {
            if viewModel.pendingInviteRoom != nil {
                InviteBannerView(viewModel: viewModel)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.pendingInviteRoom != nil)
                    .zIndex(50)
            }
        }
    }
}

// MARK: - Invite Banner

struct InviteBannerView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.title3)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("invite.banner.title")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)

                    if let name = viewModel.pendingInviterName {
                        Text(String(format: String(localized: "invite.banner.message"), name))
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }

                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    if let roomId = viewModel.pendingInviteRoom {
                        viewModel.pendingInviteRoom = nil
                        viewModel.pendingInviterName = nil
                        Task { await viewModel.joinRoom(roomId) }
                    }
                } label: {
                    Text("invite.join")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    viewModel.pendingInviteRoom = nil
                    viewModel.pendingInviterName = nil
                } label: {
                    Text("invite.decline")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .background(Color(white: 0.1).opacity(0.95))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Waiting Screen

struct WaitingView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var recentContacts: [Contact] = []
    @State private var selectedContact: Contact?
    @State private var showInviteConfirm = false

    var body: some View {
        ZStack {
            // Animated shield background
            ConnectionAnimation(step: viewModel.connectionStep)

            VStack(spacing: 24) {
                Spacer()

                Text("waiting.title")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                // Room ID + Copy/Share
                if let roomId = viewModel.roomId {
                    Text(roomId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    HStack(spacing: 12) {
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
                            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                        }

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
                            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()

                Button {
                    viewModel.leave()
                } label: {
                    Text("waiting.cancel")
                        .foregroundStyle(.red)
                }
                .padding(.bottom, 24)
            }
        }
        .task {
            loadRecentContacts()
        }
        .alert(
            String(localized: "waiting.inviteConfirm.title"),
            isPresented: $showInviteConfirm
        ) {
            Button(String(localized: "waiting.inviteConfirm.send")) {
                if let contact = selectedContact {
                    Task { await viewModel.inviteContactToChat(contact) }
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

// MARK: - Screenshot Prevention

/// Prevent screenshots and screen recording by hiding content when screen is captured
/// Uses UIScreen.isCaptured to detect mirroring/recording and shows opaque overlay
private struct ScreenshotProtectionModifier: ViewModifier {
    @State private var isCaptured = UIScreen.main.isCaptured

    func body(content: Content) -> some View {
        content
            .overlay {
                if isCaptured {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("Screen recording blocked")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .zIndex(999)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                isCaptured = UIScreen.main.isCaptured
            }
    }
}

extension View {
    func screenshotProtected() -> some View {
        modifier(ScreenshotProtectionModifier())
    }
}

// MARK: - Connecting Screen

struct ConnectingView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ZStack {
            // Animated shield background
            ConnectionAnimation(step: viewModel.connectionStep)

            // Progress overlay
            VStack(spacing: 0) {
                Spacer()

                // Connection steps — animate with viewModel.connectionStep
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionStepRow(
                        icon: "link",
                        text: String(localized: "connecting.step.server"),
                        state: stepState(for: .connectingToServer)
                    )
                    ConnectionStepRow(
                        icon: "person.2",
                        text: String(localized: "connecting.step.peer"),
                        state: stepState(for: .waitingForPeer)
                    )
                    ConnectionStepRow(
                        icon: "lock.shield",
                        text: String(localized: "connecting.step.keys"),
                        state: stepState(for: .exchangingKeys)
                    )
                    ConnectionStepRow(
                        icon: "checkmark.shield.fill",
                        text: String(localized: "connecting.step.secured"),
                        state: stepState(for: .secured)
                    )
                }
                .animation(.easeInOut(duration: 0.4), value: viewModel.connectionStep)
                .padding(20)
                .background(.ultraThinMaterial.opacity(0.6))
                .cornerRadius(16)
                .padding(.horizontal, 32)

                Spacer()

                Button {
                    viewModel.leave()
                } label: {
                    Text("connecting.cancel")
                        .foregroundStyle(.red)
                }
                .padding(.bottom, 24)
            }
        }
    }

    /// Map connection step to row state (done/active/pending)
    private func stepState(for target: ChatViewModel.ConnectionStep) -> ConnectionStepRow.StepState {
        let current = viewModel.connectionStep.rawValue
        let t = target.rawValue
        if t < current { return .done }
        if t == current { return .active }
        return .pending
    }
}

// MARK: - Connection Step Row

private struct ConnectionStepRow: View {
    let icon: String
    let text: String
    let state: StepState

    enum StepState { case pending, active, done }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            Text(text)
                .font(.system(size: 14, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(textColor)

            Spacer()

            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .active:
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.gray.opacity(0.3))
                }
            }
            .font(.system(size: 16))
        }
    }

    private var iconColor: Color {
        switch state {
        case .done: return .green
        case .active: return .white
        case .pending: return .gray.opacity(0.4)
        }
    }

    private var textColor: Color {
        switch state {
        case .done: return .green.opacity(0.9)
        case .active: return .white
        case .pending: return .gray.opacity(0.4)
        }
    }
}
