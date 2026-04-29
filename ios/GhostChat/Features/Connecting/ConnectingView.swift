import SwiftUI

/// Shown while the P2P + crypto handshake is in progress. Visualizes the 4
/// phases from `ConnectingViewModel.Phase`. The caller observes state and
/// pushes `ChatView` when `shouldAdvanceToChat` becomes true.
struct ConnectingView: View {
    let onAdvance: () -> Void
    let onCancel: (_ error: String?) -> Void

    @EnvironmentObject private var connection: ConnectionManager
    @EnvironmentObject private var localization: LocalizationManager

    /// Did we ever see a non-disconnected state? Used to distinguish "just
    /// arrived, transport not started yet" from "was connecting and dropped".
    @State private var hadConnection: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()
                spinner
                titleLabel
                phasesList
                Spacer()
                cancelButton
            }
            .padding(24)
            .preferredColorScheme(.dark)
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: connection.state) { newState in
            if newState != .disconnected { hadConnection = true }
            evaluateAdvance()
        }
        .onChange(of: connection.hasRemotePeer) { _ in evaluateAdvance() }
        .onChange(of: connection.peerIdentity) { _ in evaluateAdvance() }
        .onAppear {
            if connection.state != .disconnected { hadConnection = true }
            evaluateAdvance()
        }
    }

    // MARK: - Subviews

    private var spinner: some View {
        ProgressView()
            .scaleEffect(1.6)
            .tint(.white)
    }

    private var titleLabel: some View {
        Text(localization.localized("connecting.title"))
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }

    private var phasesList: some View {
        let active = ConnectingViewModel.phase(for: connection.state)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(ConnectingViewModel.Phase.allCases) { phase in
                phaseRow(phase, activePhase: active)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    /// Re-checks the advance / cancel predicates against the current connection
    /// snapshot. Called from every `.onChange` watcher because a single SwiftUI
    /// modifier can only watch one publisher; the invariant depends on three.
    private func evaluateAdvance() {
        if ConnectingViewModel.shouldAdvanceToChat(
            state: connection.state,
            hasRemotePeer: connection.hasRemotePeer,
            peerIdentity: connection.peerIdentity
        ) {
            onAdvance()
            return
        }
        if ConnectingViewModel.isTerminalFailure(connection.state, hadConnection: hadConnection) {
            onCancel(localization.localized("connecting.error"))
        }
    }

    private func phaseRow(_ phase: ConnectingViewModel.Phase,
                          activePhase: ConnectingViewModel.Phase) -> some View {
        let isDone    = phase.rawValue < activePhase.rawValue
        let isCurrent = phase == activePhase
        let iconName: String
        let iconColor: Color
        if isDone {
            iconName = "checkmark.circle.fill"
            iconColor = .green
        } else if isCurrent {
            iconName = "circle.dotted"
            iconColor = .white
        } else {
            iconName = "circle"
            iconColor = .gray.opacity(0.5)
        }
        return HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 18))
            Text(localization.localized(phase.localizedKey))
                .font(.subheadline)
                .foregroundStyle(isCurrent || isDone ? .white : .gray)
            Spacer()
        }
    }

    private var cancelButton: some View {
        Button {
            connection.leave()
            onCancel(nil)
        } label: {
            Text(localization.localized("connecting.cancel"))
                .font(.subheadline)
                .foregroundStyle(.gray)
                .padding(.vertical, 8)
        }
    }
}
