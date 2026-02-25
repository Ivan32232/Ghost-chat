import SwiftUI

/// Blur overlay shown when the app is locked
/// Displays biometric prompt button and ghost icon
struct LockScreenView: View {
    @ObservedObject var auth: BiometricAuthService

    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            // Full-screen opaque background to hide content
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Ghost icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.6))

                Text("biometric.locked")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                // Unlock button
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

                Spacer()
                    .frame(height: 60)
            }
        }
        .task {
            // Auto-prompt on appear
            isAuthenticating = true
            _ = await auth.authenticate()
            isAuthenticating = false
        }
    }

    private var biometricIcon: String {
        switch BiometricAuthService.biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .none: return "lock.open"
        }
    }
}
