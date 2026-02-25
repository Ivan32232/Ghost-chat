import UIKit
import AVFoundation
import CallKit
import PushKit

/// AppDelegate для CallKit (входящие звонки) и PushKit (VoIP push)
class AppDelegate: NSObject, UIApplicationDelegate {

    var callProvider: CXProvider?
    var callController: CXCallController?

    // Callbacks от ChatViewModel для CallKit actions
    var onCallAnswer: (() -> Void)?
    var onCallEnd: (() -> Void)?
    var onCallMute: (() -> Void)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        setupCallKit()
        setupPushKit()
        return true
    }

    // MARK: - CallKit

    private func setupCallKit() {
        let config = CXProviderConfiguration()
        // localizedName is read-only, set via CXProviderConfiguration(localizedName:) or Info.plist
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false // Приватность

        callProvider = CXProvider(configuration: config)
        callProvider?.setDelegate(self, queue: .main)
        callController = CXCallController()
    }

    /// Показать системный UI входящего звонка
    func reportIncomingCall(uuid: UUID, handle: String, completion: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = "Ghost Chat"
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false

        callProvider?.reportNewIncomingCall(with: uuid, update: update, completion: completion)
    }

    /// Завершить звонок в системе
    func endSystemCall(uuid: UUID) {
        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)
        callController?.request(transaction, completion: { _ in })
    }

    // MARK: - PushKit

    private func setupPushKit() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }
}

// MARK: - CXProviderDelegate

extension AppDelegate: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        // Provider was reset
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        onCallAnswer?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        onCallEnd?()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
        onCallMute?()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Audio session активирована — можно начинать аудио
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Audio session деактивирована
    }
}

// MARK: - PKPushRegistryDelegate

extension AppDelegate: PKPushRegistryDelegate {

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        // VoIP push token получен
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        print("[PushKit] VoIP token: \(token)")
        // TODO: отправить token на сервер для push notifications
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        // IMPORTANT: iOS требует немедленного вызова reportNewIncomingCall
        // после получения VoIP push, иначе приложение будет убито
        let uuid = UUID()
        let handle = payload.dictionaryPayload["handle"] as? String ?? "Ghost Chat"

        reportIncomingCall(uuid: uuid, handle: handle) { error in
            if let error {
                print("[PushKit] Failed to report call: \(error)")
            }
            completion()
        }
    }
}
