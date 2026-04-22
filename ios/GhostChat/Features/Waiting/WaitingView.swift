import SwiftUI

/// Shown after `Create Room` succeeds. Displays the room id, a primary
/// ShareLink and a secondary Copy button. The view auto-advances when the
/// peer joins — the caller (WelcomeView) observes the same state and pushes
/// `ConnectingView` onto the navigation path.
///
/// The view is deliberately dumb about navigation: it signals "advance" and
/// "cancel" via closures injected by the caller. Keeps navigation logic in
/// one place (WelcomeView) and the view itself trivial to preview / test.
struct WaitingView: View {
    let roomId: String
    let onAdvance: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var localization: LocalizationManager
    @StateObject private var vm = WaitingViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                icon
                titleLabel
                roomIdCapsule
                shareButton
                copyButton
                hintLabel
                Spacer()
                cancelButton
            }
            .padding(24)
            .preferredColorScheme(.dark)
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: connection.state) { newState in
            // Host path: peer joined → DC opening → key exchange.
            // Guest path: after joinRoom, once DC is up we also leave waiting.
            if newState == .webRTC || newState == .encrypted {
                onAdvance()
            } else if newState == .disconnected {
                onCancel()
            }
        }
    }

    // MARK: - Subviews

    private var icon: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 96, height: 96)
            Image(systemName: "hourglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var titleLabel: some View {
        Text(localization.localized("waiting.title"))
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }

    private var roomIdCapsule: some View {
        Text(vm.displayID(roomId))
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(.gray)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(0.04), in: Capsule())
            .accessibilityLabel(roomId)
    }

    private var shareButton: some View {
        ShareLink(item: vm.shareURL(roomId: roomId)) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                Text(localization.localized("waiting.share"))
            }
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel(localization.localized("waiting.share"))
    }

    private var copyButton: some View {
        Button {
            vm.copy(roomId: roomId)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: vm.copiedFeedbackVisible ? "checkmark" : "doc.on.doc")
                Text(vm.copiedFeedbackVisible
                     ? localization.localized("waiting.copied")
                     : localization.localized("waiting.copy"))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .animation(.easeOut(duration: 0.15), value: vm.copiedFeedbackVisible)
    }

    private var hintLabel: some View {
        Text(localization.localized("waiting.hint"))
            .font(.footnote)
            .foregroundStyle(.gray)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private var cancelButton: some View {
        Button {
            connection.leave()
            onCancel()
        } label: {
            Text(localization.localized("waiting.cancel"))
                .font(.subheadline)
                .foregroundStyle(.gray)
                .padding(.vertical, 8)
        }
    }
}
