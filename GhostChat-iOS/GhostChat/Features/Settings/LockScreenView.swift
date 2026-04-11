import SwiftUI

/// Lock screen with PIN entry pad + optional biometric button
/// Telegram-style numeric PIN pad with dot indicators
struct LockScreenView: View {
    @ObservedObject var auth: BiometricAuthService

    @State private var enteredPin = ""
    @State private var isAuthenticating = false
    @State private var showError = false
    @State private var shakeOffset: CGFloat = 0
    @State private var attempts = 0

    private var pinDigits: Int { auth.pinLength }

    var body: some View {
        ZStack {
            // Full-screen opaque background
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Ghost icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 12)

                Text("biometric.locked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)

                if auth.isPinSet {
                    if auth.pinLockoutRemaining > 0 {
                        // Lockout — показываем таймер
                        Text("🔒 \(auth.pinLockoutRemaining)s")
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding(.bottom, 8)
                        Text("pin.tooManyAttempts")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            .padding(.bottom, 24)
                    } else {
                        Text("pin.enterCode")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            .padding(.bottom, 24)
                    }

                    // PIN dot indicators
                    pinDots
                        .offset(x: shakeOffset)
                        .padding(.bottom, 32)

                    // Numeric keypad (disabled during lockout)
                    numericPad
                        .padding(.horizontal, 40)
                        .disabled(auth.pinLockoutRemaining > 0)
                        .opacity(auth.pinLockoutRemaining > 0 ? 0.3 : 1)
                }

                Spacer()

                // Face ID / Touch ID button (only if biometric enabled AND PIN is set)
                if auth.isPinSet && auth.isEnabled && BiometricAuthService.isAvailable {
                    Button {
                        Task {
                            isAuthenticating = true
                            _ = await auth.authenticate()
                            isAuthenticating = false
                        }
                    } label: {
                        VStack(spacing: 6) {
                            if isAuthenticating {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: biometricIcon)
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            Text(auth.biometricName)
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                    }
                    .disabled(isAuthenticating)
                    .padding(.bottom, 40)
                } else if !auth.isPinSet {
                    // No PIN set — only biometric unlock button (legacy fallback, shouldn't normally happen)
                    Button {
                        Task {
                            isAuthenticating = true
                            _ = await auth.authenticate()
                            isAuthenticating = false
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isAuthenticating {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: biometricIcon)
                                    .font(.title3)
                            }
                            Text("biometric.unlock")
                                .font(.headline)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 40)
                    }
                    .disabled(isAuthenticating)
                    .padding(.bottom, 40)
                }
            }
        }
        .task {
            // Auto-prompt biometric on appear (if enabled and PIN set)
            if auth.isEnabled && auth.isPinSet && BiometricAuthService.isAvailable {
                isAuthenticating = true
                _ = await auth.authenticate()
                isAuthenticating = false
            }
        }
    }

    // MARK: - PIN Dots

    private var pinDots: some View {
        HStack(spacing: 14) {
            ForEach(0..<pinDigits, id: \.self) { index in
                Circle()
                    .fill(index < enteredPin.count ? Color.white : Color.white.opacity(0.2))
                    .frame(width: 14, height: 14)
                    .overlay {
                        if index < enteredPin.count {
                            Circle()
                                .fill(showError ? Color.red : Color.white)
                        }
                    }
                    .scaleEffect(index < enteredPin.count ? 1.15 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: enteredPin.count)
            }
        }
    }

    // MARK: - Numeric Pad

    private var numericPad: some View {
        VStack(spacing: 16) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(0..<3, id: \.self) { col in
                        let key = keyForPosition(row: row, col: col)
                        if let key {
                            numericKey(key)
                        } else {
                            // Empty placeholder
                            Color.clear
                                .frame(width: 72, height: 72)
                        }
                    }
                }
            }
        }
    }

    private func keyForPosition(row: Int, col: Int) -> PinKey? {
        switch (row, col) {
        case (0, 0): return .digit("1")
        case (0, 1): return .digit("2")
        case (0, 2): return .digit("3")
        case (1, 0): return .digit("4")
        case (1, 1): return .digit("5")
        case (1, 2): return .digit("6")
        case (2, 0): return .digit("7")
        case (2, 1): return .digit("8")
        case (2, 2): return .digit("9")
        case (3, 0): return nil
        case (3, 1): return .digit("0")
        case (3, 2): return .delete
        default: return nil
        }
    }

    @ViewBuilder
    private func numericKey(_ key: PinKey) -> some View {
        Button {
            handleKey(key)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(key == .delete ? 0 : 0.08))
                    .frame(width: 72, height: 72)

                switch key {
                case .digit(let d):
                    Text(d)
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .foregroundStyle(.white)
                case .delete:
                    Image(systemName: "delete.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .buttonStyle(PinButtonStyle())
    }

    // MARK: - Key Handling

    private func handleKey(_ key: PinKey) {
        guard !showError else { return }

        switch key {
        case .digit(let d):
            guard enteredPin.count < pinDigits else { return }
            enteredPin += d
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            // Auto-submit when reaching exact PIN length
            if enteredPin.count == pinDigits {
                // Small delay to show the last dot
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    tryVerify()
                }
            }

        case .delete:
            if !enteredPin.isEmpty {
                enteredPin.removeLast()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private func tryVerify() {
        if auth.verifyPin(enteredPin) {
            // Success — isUnlocked is set by verifyPin
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            // Wrong PIN — shake and clear
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showError = true
            attempts += 1

            // Shake animation
            withAnimation(.default) {
                shakeOffset = 12
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.default) { shakeOffset = -12 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.default) { shakeOffset = 8 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.default) { shakeOffset = -8 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                withAnimation(.default) { shakeOffset = 0 }
            }

            // Clear after delay (longer delay after multiple attempts)
            let delay = min(Double(attempts) * 0.3, 2.0) + 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                enteredPin = ""
                showError = false
            }
        }
    }

    // MARK: - Helpers

    private var biometricIcon: String {
        switch BiometricAuthService.biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .none: return "lock.open"
        }
    }

    private enum PinKey: Equatable {
        case digit(String)
        case delete
    }
}

// MARK: - Pin Button Style (press feedback)

private struct PinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Set PIN View (for Settings)

struct SetPinView: View {
    @ObservedObject var auth: BiometricAuthService
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case create
        case change
    }

    let mode: Mode

    @State private var step: Step = .enterNew
    @State private var firstPin = ""
    @State private var secondPin = ""
    @State private var currentPin = ""
    @State private var enteredPin = ""
    @State private var showError = false
    @State private var shakeOffset: CGFloat = 0
    @State private var errorMessage = ""
    @State private var selectedLength: Int

    init(auth: BiometricAuthService, mode: Mode) {
        self.auth = auth
        self.mode = mode
        self._selectedLength = State(initialValue: auth.pinLength)
    }

    private var pinDigits: Int { selectedLength }

    private enum Step {
        case verifyOld   // For change mode: verify current PIN
        case enterNew    // Enter new PIN
        case confirmNew  // Confirm new PIN
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // PIN length picker (only during enterNew step)
            if step == .enterNew {
                Picker("", selection: $selectedLength) {
                    Text("4 " + String(localized: "pin.digits")).tag(4)
                    Text("6 " + String(localized: "pin.digits")).tag(6)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 80)
                .padding(.bottom, 20)
                .onChange(of: selectedLength) { _ in
                    enteredPin = ""
                    firstPin = ""
                }
            }

            // Title
            Text(stepTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            Text(stepSubtitle)
                .font(.subheadline)
                .foregroundStyle(.gray)
                .padding(.bottom, 24)

            // PIN dots
            HStack(spacing: 14) {
                ForEach(0..<pinDigits, id: \.self) { index in
                    Circle()
                        .fill(index < enteredPin.count ? (showError ? Color.red : Color.white) : Color.white.opacity(0.2))
                        .frame(width: 14, height: 14)
                        .scaleEffect(index < enteredPin.count ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: enteredPin.count)
                }
            }
            .offset(x: shakeOffset)
            .padding(.bottom, 8)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
            }

            Spacer()
                .frame(height: 24)

            // Numeric keypad
            numericPad
                .padding(.horizontal, 40)

            Spacer()
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .navigationTitle(mode == .create ? String(localized: "pin.set") : String(localized: "pin.change"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if mode == .change {
                step = .verifyOld
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .verifyOld: return String(localized: "pin.enterCurrent")
        case .enterNew: return String(localized: "pin.enterNew")
        case .confirmNew: return String(localized: "pin.confirmNew")
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .verifyOld: return String(localized: "pin.enterCurrentHint")
        case .enterNew: return "\(selectedLength) " + String(localized: "pin.digits")
        case .confirmNew: return String(localized: "pin.confirmHint")
        }
    }

    // MARK: - Numeric Pad

    private var numericPad: some View {
        VStack(spacing: 16) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(0..<3, id: \.self) { col in
                        let key = keyForPosition(row: row, col: col)
                        if let key {
                            numericKey(key)
                        } else {
                            Color.clear.frame(width: 72, height: 72)
                        }
                    }
                }
            }
        }
    }

    private func keyForPosition(row: Int, col: Int) -> PinKey? {
        switch (row, col) {
        case (0, 0): return .digit("1")
        case (0, 1): return .digit("2")
        case (0, 2): return .digit("3")
        case (1, 0): return .digit("4")
        case (1, 1): return .digit("5")
        case (1, 2): return .digit("6")
        case (2, 0): return .digit("7")
        case (2, 1): return .digit("8")
        case (2, 2): return .digit("9")
        case (3, 0): return nil
        case (3, 1): return .digit("0")
        case (3, 2): return .delete
        default: return nil
        }
    }

    @ViewBuilder
    private func numericKey(_ key: PinKey) -> some View {
        Button {
            handleKey(key)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(key == .delete ? 0 : 0.08))
                    .frame(width: 72, height: 72)

                switch key {
                case .digit(let d):
                    Text(d)
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .foregroundStyle(.white)
                case .delete:
                    Image(systemName: "delete.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .buttonStyle(SetPinButtonStyle())
    }

    // MARK: - Key Handling

    private func handleKey(_ key: PinKey) {
        guard !showError else { return }

        switch key {
        case .digit(let d):
            guard enteredPin.count < pinDigits else { return }
            enteredPin += d
            errorMessage = ""
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            if enteredPin.count == pinDigits {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    processStep()
                }
            }

        case .delete:
            if !enteredPin.isEmpty {
                enteredPin.removeLast()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private func processStep() {
        switch step {
        case .verifyOld:
            if auth.verifyPin(enteredPin) {
                // Re-lock since verifyPin unlocks
                auth.isUnlocked = true // keep unlocked (we're in settings)
                currentPin = enteredPin
                enteredPin = ""
                step = .enterNew
            } else {
                shakeAndClear()
            }

        case .enterNew:
            firstPin = enteredPin
            enteredPin = ""
            step = .confirmNew

        case .confirmNew:
            if enteredPin == firstPin {
                // PINs match — save PIN and chosen length
                auth.pinLength = selectedLength
                auth.setPin(enteredPin)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } else {
                // Mismatch — go back to enterNew
                errorMessage = String(localized: "pin.mismatch")
                shakeAndClear()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    step = .enterNew
                    firstPin = ""
                    errorMessage = ""
                }
            }
        }
    }

    private func shakeAndClear() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        showError = true

        withAnimation(.default) { shakeOffset = 12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = -12 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = 8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.default) { shakeOffset = -8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.default) { shakeOffset = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            enteredPin = ""
            showError = false
        }
    }

    private enum PinKey: Equatable {
        case digit(String)
        case delete
    }
}

private struct SetPinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
