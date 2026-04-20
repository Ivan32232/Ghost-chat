import SwiftUI

struct CallView: View {
    @EnvironmentObject var calls: CallManager
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var contacts: ContactManager
    @EnvironmentObject var localization: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                peerAvatar
                Text(peerName)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                Text(stateLabel)
                    .foregroundStyle(.gray)
                if calls.state == .active {
                    Text(formatDuration(calls.duration))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white)
                }
                Spacer()
                controls
                Spacer(minLength: 20)
            }
            .padding()
        }
        .onChange(of: calls.state) { newState in
            if newState == .ended || newState == .idle {
                dismiss()
            }
        }
    }

    // MARK: - Subviews

    private var peerAvatar: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08)).frame(width: 120, height: 120)
            Text(String(peerName.prefix(1)).uppercased())
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            circleButton(icon: calls.isMuted ? "mic.slash.fill" : "mic.fill",
                         label: calls.isMuted ? "call.unmute" : "call.mute",
                         tint: calls.isMuted ? .red : .white.opacity(0.2)) {
                calls.setMuted(!calls.isMuted)
            }
            circleButton(icon: "phone.down.fill", label: "call.end", tint: .red, size: 72) {
                Task { try? await calls.end() }
            }
            circleButton(icon: calls.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                         label: calls.isSpeakerOn ? "call.earpiece" : "call.speaker",
                         tint: .white.opacity(0.2)) {
                calls.setSpeaker(!calls.isSpeakerOn)
            }
        }
    }

    private func circleButton(icon: String, label: String, tint: Color, size: CGFloat = 56, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint, in: Circle())
        }
        .accessibilityLabel(localization.localized(label))
    }

    // MARK: - Derived

    private var peerName: String {
        if let peer = connection.peerIdentity,
           let contact = contacts.contacts.first(where: { $0.identityKey == peer }) {
            return contact.label
        }
        return "Ghost Chat"
    }

    private var stateLabel: String {
        switch calls.state {
        case .outgoingPending:  return localization.localized("chat.connecting")
        case .outgoingRinging:  return "Calling…"
        case .incoming:         return localization.localized("call.incoming")
        case .active:           return localization.localized("chat.connected")
        case .ended, .idle:     return ""
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct IncomingCallView: View {
    @EnvironmentObject var calls: CallManager
    @EnvironmentObject var localization: LocalizationManager
    var peerName: String
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Circle().fill(Color.white.opacity(0.08)).frame(width: 120, height: 120)
                    .overlay(Text(String(peerName.prefix(1)).uppercased()).font(.largeTitle.bold()).foregroundStyle(.white))
                Text(peerName).font(.title).foregroundStyle(.white)
                Text(localization.localized("call.incoming")).foregroundStyle(.gray)
                Spacer()
                HStack(spacing: 48) {
                    action(icon: "phone.down.fill", tint: .red, label: "call.decline", action: onDecline)
                    action(icon: "phone.fill", tint: .green, label: "call.accept", action: onAccept)
                }
                Spacer(minLength: 20)
            }
            .padding()
        }
    }

    private func action(icon: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(tint, in: Circle())
        }
        .accessibilityLabel(localization.localized(label))
    }
}
