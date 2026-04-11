import SwiftUI

/// Минималистичная анимация подключения — пульсирующий щит + расходящиеся кольца
/// Адаптируется под этап: connecting → waiting → keys → secured
struct ConnectionAnimation: View {
    var step: ChatViewModel.ConnectionStep

    @State private var pulse = false
    @State private var ring1 = false
    @State private var ring2 = false
    @State private var showCheckmark = false

    var body: some View {
        ZStack {
            // Background
            Color(white: 0.04).ignoresSafeArea()

            // Ripple rings
            Circle()
                .stroke(ringColor.opacity(0.15), lineWidth: 1.5)
                .frame(width: ring1 ? 280 : 80, height: ring1 ? 280 : 80)
                .opacity(ring1 ? 0 : 0.6)

            Circle()
                .stroke(ringColor.opacity(0.1), lineWidth: 1)
                .frame(width: ring2 ? 350 : 80, height: ring2 ? 350 : 80)
                .opacity(ring2 ? 0 : 0.4)

            // Glow behind shield
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor.opacity(pulse ? 0.2 : 0.05), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: pulse ? 100 : 60
                    )
                )
                .frame(width: 200, height: 200)

            // Shield icon
            ZStack {
                // Shield body
                Image(systemName: shieldIcon)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(iconColor)
                    .scaleEffect(pulse ? 1.05 : 0.95)

                // Secured checkmark overlay
                if step == .secured && showCheckmark {
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                        .offset(y: 4)
                }
            }
        }
        .onAppear {
            startAnimations()
        }
        .onChange(of: step) { _ in
            startAnimations()
            if step == .secured {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    showCheckmark = true
                }
            }
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        // Pulse
        withAnimation(.easeInOut(duration: pulseSpeed).repeatForever(autoreverses: true)) {
            pulse = true
        }

        // Ring 1
        ring1 = false
        withAnimation(.easeOut(duration: ringSpeed).repeatForever(autoreverses: false)) {
            ring1 = true
        }

        // Ring 2 (delayed)
        ring2 = false
        DispatchQueue.main.asyncAfter(deadline: .now() + ringSpeed * 0.5) {
            withAnimation(.easeOut(duration: ringSpeed).repeatForever(autoreverses: false)) {
                ring2 = true
            }
        }
    }

    // MARK: - Step-dependent parameters

    private var shieldIcon: String {
        switch step {
        case .connectingToServer: return "shield"
        case .waitingForPeer: return "shield.lefthalf.filled"
        case .exchangingKeys: return "lock.shield"
        case .secured: return "checkmark.shield.fill"
        }
    }

    private var iconColor: Color {
        switch step {
        case .connectingToServer: return .gray
        case .waitingForPeer: return .white.opacity(0.7)
        case .exchangingKeys: return Color(red: 1.0, green: 0.85, blue: 0.35) // gold
        case .secured: return .green
        }
    }

    private var ringColor: Color {
        switch step {
        case .connectingToServer: return .gray
        case .waitingForPeer: return .white
        case .exchangingKeys: return Color(red: 1.0, green: 0.85, blue: 0.35)
        case .secured: return .green
        }
    }

    private var glowColor: Color {
        switch step {
        case .connectingToServer: return .gray
        case .waitingForPeer: return .blue
        case .exchangingKeys: return Color(red: 1.0, green: 0.85, blue: 0.35)
        case .secured: return .green
        }
    }

    private var pulseSpeed: Double {
        switch step {
        case .connectingToServer: return 2.0
        case .waitingForPeer: return 1.5
        case .exchangingKeys: return 0.8
        case .secured: return 3.0 // slow, calm
        }
    }

    private var ringSpeed: Double {
        switch step {
        case .connectingToServer: return 3.0
        case .waitingForPeer: return 2.5
        case .exchangingKeys: return 1.5
        case .secured: return 4.0
        }
    }
}

#Preview("Connecting") {
    ConnectionAnimation(step: .connectingToServer)
}

#Preview("Keys") {
    ConnectionAnimation(step: .exchangingKeys)
}

#Preview("Secured") {
    ConnectionAnimation(step: .secured)
}
