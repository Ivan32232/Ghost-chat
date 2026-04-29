import CallKit
import Foundation
import PushKit
import Sentry
import UIKit
import UserNotifications

/// Bridges iOS system callbacks (PushKit, UNUserNotificationCenter) to Managers.
/// Keeps logic tiny — Managers own the business rules.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var pushManager: PushManager?
    var callManager: CallManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        configureSentry()
        // Pending: pushManager wired by GhostChatApp.onAppear; register VoIP
        // there once the Manager is available.
        return true
    }

    /// Called from `GhostChatApp.onAppear` once the AppServices' `pushManager`
    /// has been bound to this delegate. VoIP registration is silent (no system
    /// prompt) so it's safe to do at every launch — needed for CallKit to
    /// surface incoming calls when the app is in the background or killed.
    func bootstrapVoIPIfNeeded() {
        guard let push = pushManager else { return }
        push.registerForVoIP()
    }

    /// Called from the Settings notifications toggle when the user opts in.
    /// Triggers the iOS APNs permission prompt and, on grant, registers for
    /// remote notifications so APNs delivers a device token to
    /// `didRegisterForRemoteNotificationsWithDeviceToken`.
    @MainActor
    func requestNotificationsAuthorization() async -> Bool {
        guard let push = pushManager else { return false }
        let granted = await push.requestAPNsAuthorization()
        if granted {
            await UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }

    /// Boot Sentry only when a DSN is actually configured. PII is aggressively scrubbed
    /// in `beforeSend` — the app collects no user-identifying telemetry, the DSN is the
    /// *only* network egress from the crash pipeline.
    private func configureSentry() {
        guard let dsn = Bundle.main.infoDictionary?["SentryDSN"] as? String,
              !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.tracesSampleRate = 0.0
            options.enableAutoSessionTracking = false
            options.sendDefaultPii = false
            options.enableAutoPerformanceTracing = false
            options.beforeSend = { event in
                event.user = nil
                event.request = nil
                event.context?.removeValue(forKey: "device")
                event.context?.removeValue(forKey: "app")
                return event
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushManager?.didReceiveAPNsToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Ignored — app still works without remote notifications.
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
