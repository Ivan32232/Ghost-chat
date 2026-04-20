import SwiftUI

/// Full-screen overlay shown when biometrics are required. Tries Face ID on appear,
/// falls back to PIN keypad. 10 failed attempts triggers `panicWipe` via `BiometricAuthService`.
struct LockScreenView: View {
    @EnvironmentObject var localization: LocalizationManager
    let service: BiometricAuthService
    let onUnlocked: () -> Void
    let onDecoy: () -> Void

    @State private var pin: String = ""
    @State private var errorMessage: String?
    @State private var attempting = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                Text(localization.localized("lock.unlock_biometric"))
                    .foregroundStyle(.white)
                    .font(.headline)
                if let err = errorMessage {
                    Text(err).foregroundStyle(.red).font(.footnote)
                }
                pinKeypad
                Spacer()
            }
            .padding()
        }
        .task {
            await tryBiometrics()
        }
    }

    private var pinKeypad: some View {
        VStack(spacing: 12) {
            Text(String(repeating: "●", count: pin.count) + String(repeating: "○", count: max(0, 4 - pin.count)))
                .font(.title2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.bottom, 8)
            ForEach(0..<3) { row in
                HStack(spacing: 16) {
                    ForEach(0..<3) { col in
                        let digit = row * 3 + col + 1
                        pinButton(title: "\(digit)")
                    }
                }
            }
            HStack(spacing: 16) {
                pinButton(title: "", isDisabled: true)
                pinButton(title: "0")
                Button {
                    if !pin.isEmpty { pin.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.white.opacity(0.05), in: Circle())
                }
            }
        }
    }

    private func pinButton(title: String, isDisabled: Bool = false) -> some View {
        Button {
            guard pin.count < 6 else { return }
            pin += title
            if pin.count >= 4 {
                Task { await submitPIN() }
            }
        } label: {
            Text(title)
                .font(.title).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.05), in: Circle())
        }
        .disabled(isDisabled || title.isEmpty)
        .opacity(isDisabled || title.isEmpty ? 0 : 1)
    }

    private func tryBiometrics() async {
        guard service.biometricEnabled else { return }
        if await service.authenticateBiometric(reason: localization.localized("lock.unlock_biometric")) {
            onUnlocked()
        }
    }

    private func submitPIN() async {
        guard !attempting else { return }
        attempting = true
        defer { attempting = false }
        let currentPIN = pin
        pin = ""
        do {
            switch try service.authenticate(pin: currentPIN) {
            case .authenticated:
                onUnlocked()
            case .authenticatedAsDecoy:
                onDecoy()
            case .invalid:
                errorMessage = localization.localized("lock.invalid_pin")
            case .wiped:
                errorMessage = "All data wiped."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
