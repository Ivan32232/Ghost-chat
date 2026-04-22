import SwiftUI

@main
struct GhostChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    @StateObject private var services = AppServicesBox()
    @StateObject private var deepLink = DeepLinkRouter()

    @Environment(\.scenePhase) private var scenePhase
    @State private var locked: Bool = false

    var body: some Scene {
        WindowGroup {
            root
                .preferredColorScheme(.dark)
                .environmentObject(services.value.connection)
                .environmentObject(services.value.contacts)
                .environmentObject(services.value.messages)
                .environmentObject(services.value.calls)
                .environmentObject(services.value.settings)
                .environmentObject(services.value.localization)
                .environmentObject(deepLink)
                .onAppear {
                    delegate.pushManager = services.value.push
                    delegate.callManager = services.value.calls
                    locked = services.value.auth.biometricEnabled && services.value.auth.hasMainPIN
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .background, services.value.calls.state == .idle {
                        locked = services.value.auth.biometricEnabled && services.value.auth.hasMainPIN
                    }
                }
                .onOpenURL { url in
                    // Never auto-join — DeepLinkRouter only parses + stores; the
                    // confirmation dialog lives in WelcomeView.
                    deepLink.submit(url)
                }
        }
    }

    // MARK: - Root switch

    @ViewBuilder
    private var root: some View {
        if locked {
            LockScreenView(
                service: services.value.auth,
                onUnlocked: { locked = false },
                onDecoy: { locked = false }
            )
        } else {
            WelcomeView()
        }
    }
}

/// Holds `AppServices` as a `@StateObject`-compatible ObservableObject so all Managers
/// survive view reloads.
@MainActor
final class AppServicesBox: ObservableObject {
    let value: AppServices
    init() { self.value = AppServices() }
}
