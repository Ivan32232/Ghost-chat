import Foundation
import PushKit
import UserNotifications

/// Coordinates VoIP + APNs push registration and POSTs to the relay server.
/// HMAC auth: server hands us `pushAuth` (HMAC-SHA256 keyed on TURN_SECRET) inside the TURN
/// credentials response. We echo it back in every push request. Client never sees TURN_SECRET.
final class PushManager: NSObject {

    enum Error: Swift.Error {
        case httpStatus(Int)
    }

    private let baseURL: URL
    private let session: URLSession
    private var registry: PKPushRegistry?

    private(set) var voipToken: Data?
    private(set) var apnsToken: Data?
    var pushAuth: String?

    private var voipTokenContinuation: AsyncStream<Data>.Continuation?
    private var apnsTokenContinuation: AsyncStream<Data>.Continuation?

    let voipTokens: AsyncStream<Data>
    let apnsTokens: AsyncStream<Data>

    init(baseURL: URL, pinning: CertificatePinning = CertificatePinning()) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: pinning, delegateQueue: nil)

        var voipCont: AsyncStream<Data>.Continuation!
        self.voipTokens = AsyncStream { voipCont = $0 }
        var apnsCont: AsyncStream<Data>.Continuation!
        self.apnsTokens = AsyncStream { apnsCont = $0 }

        super.init()
        self.voipTokenContinuation = voipCont
        self.apnsTokenContinuation = apnsCont
    }

    // MARK: - Registration

    func registerForVoIP() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func requestAPNsAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func didReceiveAPNsToken(_ token: Data) {
        apnsToken = token
        apnsTokenContinuation?.yield(token)
    }

    // MARK: - Send

    struct CallPayload: Codable {
        let roomId: String
        let callerName: String
    }

    struct InvitePayload: Codable {
        let roomId: String
        let inviterName: String
    }

    func sendVoIPCall(to token: String, roomId: String, callerName: String) async throws {
        try await post(path: "api/send-push", body: [
            "token": token,
            "payload": ["roomId": roomId, "callerName": callerName],
            "auth": pushAuth as Any
        ])
    }

    func sendFCMCall(to token: String, roomId: String, callerName: String) async throws {
        try await post(path: "api/send-push-android", body: [
            "token": token,
            "payload": ["roomId": roomId, "callerName": callerName],
            "auth": pushAuth as Any
        ])
    }

    func sendInvite(to token: String, platform: String, roomId: String, inviterName: String) async throws {
        try await post(path: "api/send-invite", body: [
            "token": token,
            "platform": platform,
            "payload": ["roomId": roomId, "inviterName": inviterName],
            "auth": pushAuth as Any
        ])
    }

    func sendNotify(to token: String, platform: String, senderName: String, type: String) async throws {
        try await post(path: "api/push/notify", body: [
            "token": token,
            "platform": platform,
            "senderName": senderName,
            "type": type,
            "auth": pushAuth as Any
        ])
    }

    // MARK: - Private

    private func post(path: String, body: [String: Any]) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.httpStatus(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.httpStatus(http.statusCode)
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension PushManager: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        voipToken = pushCredentials.token
        voipTokenContinuation?.yield(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        voipToken = nil
    }

    /// CallKit handoff — AppDelegate re-implements this separately to call `reportNewIncomingCall`
    /// synchronously. PushManager just logs receipt so the registry delegate is always set.
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        completion()
    }
}
