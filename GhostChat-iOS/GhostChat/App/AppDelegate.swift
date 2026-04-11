import UIKit
import AVFoundation
import CallKit
import PushKit
import UserNotifications
import FirebaseCore
import FirebaseCrashlytics
import WebRTC
import os.log

private let _appDelegateLogger = Logger(subsystem: "com.ivanpokhvalitov.ghostchat", category: "AppDelegate")

/// AppDelegate для CallKit (входящие звонки), PushKit (VoIP push) и UNNotifications (chat invites)
class AppDelegate: NSObject, UIApplicationDelegate {

    /// Global reference — UIApplication.shared.delegate may be nil in some SwiftUI contexts
    static weak var shared: AppDelegate?

    var callProvider: CXProvider?
    var callController: CXCallController?
    private var pushRegistry: PKPushRegistry?  // H2: retain to prevent ARC deallocation

    // VoIP push token — для звонков
    var voipToken: Data?

    // Regular APNs token — для приглашений в чат
    var regularPushToken: Data?

    // Callbacks от ChatViewModel для CallKit actions
    var onCallAnswer: (() -> Void)?
    var onCallEnd: (() -> Void)?
    var onCallMute: (() -> Void)?

    // Push callbacks
    var onVoIPTokenReceived: ((Data) -> Void)?
    var onRegularTokenReceived: ((Data) -> Void)?
    var onPushReceived: ((String?, UUID, String) -> Void)? {
        didSet {
            // Flush pending VoIP push that arrived before ChatViewModel wired the callback
            if let pending = pendingVoIPPush, let cb = onPushReceived {
                _appDelegateLogger.fault("[PushKit] Flushing buffered VoIP push to late-wired callback")
                pendingVoIPPush = nil
                cb(pending.roomId, pending.uuid, pending.callerName)
            }
        }
    }
    var onInviteReceived: ((String, String) -> Void)?  // roomId, inviterName
    var onMessagePushReceived: ((String, String) -> Void)?  // type (new-message/missed-call), senderName

    /// Buffered VoIP push info when push arrives before ChatViewModel wires onPushReceived (cold start race)
    private var pendingVoIPPush: (roomId: String?, uuid: UUID, callerName: String)?

    /// ID контакта, чей чат сейчас открыт (для подавления push если пользователь в этом чате)
    var activeContactChatId: String?
    var activeContactName: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppDelegate.shared = self
        _appDelegateLogger.fault("[AppDelegate] didFinishLaunchingWithOptions — starting setup")
        FirebaseApp.configure()
        setupCallKit()
        #if !targetEnvironment(simulator)
        setupPushKit()
        setupRemoteNotifications()
        #else
        _appDelegateLogger.fault("[AppDelegate] SIMULATOR — skipping PushKit/APNs registration")
        #endif
        _appDelegateLogger.fault("[AppDelegate] didFinishLaunchingWithOptions — setup complete")
        return true
    }

    // MARK: - CallKit

    private func setupCallKit() {
        // CRITICAL: Configure WebRTC audio for CallKit coordination
        // useManualAudio tells WebRTC we control when audio flows
        // isAudioEnabled = false until CallKit's didActivate fires
        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.useManualAudio = true
        rtcAudio.isAudioEnabled = false

        let config = CXProviderConfiguration()
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
        update.localizedCallerName = handle
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false

        callProvider?.reportNewIncomingCall(with: uuid, update: update, completion: completion)
    }

    /// Показать системный UI исходящего звонка
    func reportOutgoingCall(uuid: UUID, handle: String) {
        let startAction = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        startAction.isVideo = false
        let transaction = CXTransaction(action: startAction)
        callController?.request(transaction) { [weak self] error in
            if error == nil {
                // Обновить информацию о звонке (имя контакта)
                let update = CXCallUpdate()
                update.localizedCallerName = handle
                update.hasVideo = false
                self?.callProvider?.reportCall(with: uuid, updated: update)
            }
        }
    }

    /// Пометить исходящий звонок как подключённый
    func reportOutgoingCallConnected(uuid: UUID) {
        callProvider?.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// Пометить входящий звонок как подключённый (принят в приложении)
    /// Убирает Dynamic Island / системный UI входящего звонка
    func reportIncomingCallConnected(uuid: UUID) {
        let answerAction = CXAnswerCallAction(call: uuid)
        let transaction = CXTransaction(action: answerAction)
        callController?.request(transaction) { error in
            if let error {
                #if DEBUG
                print("[CallKit] reportIncomingCallConnected failed: \(error)")
                #endif
            }
        }
    }

    /// Завершить звонок в системе
    func endSystemCall(uuid: UUID) {
        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)
        callController?.request(transaction, completion: { _ in })
    }

    // MARK: - PushKit (VoIP)

    private func setupPushKit() {
        _appDelegateLogger.fault("[PushKit] setupPushKit — registering for VoIP push")
        pushRegistry = PKPushRegistry(queue: .main)
        pushRegistry?.delegate = self
        pushRegistry?.desiredPushTypes = [.voIP]
        // Check if token is already cached from previous registration
        if let cachedToken = pushRegistry?.pushToken(for: .voIP) {
            _appDelegateLogger.fault("[PushKit] setupPushKit — cached VoIP token found, len=\(cachedToken.count, privacy: .public)")
            voipToken = cachedToken
        } else {
            _appDelegateLogger.fault("[PushKit] setupPushKit — no cached VoIP token, waiting for delegate callback")
        }
    }

    // MARK: - Remote Notifications (Chat Invites)

    private func setupRemoteNotifications() {
        _appDelegateLogger.fault("[APNs] setupRemoteNotifications — registering immediately (token works regardless of permission grant)")
        UNUserNotificationCenter.current().delegate = self

        // Apple docs: call registerForRemoteNotifications UNCONDITIONALLY.
        // APNs token is delivered regardless of notification permission grant —
        // user may enable notifications in Settings later without losing the token,
        // and we still need the token for VoIP push + server-side offline delivery.
        DispatchQueue.main.async {
            _appDelegateLogger.fault("[APNs] registerForRemoteNotifications called (unconditional)")
            UIApplication.shared.registerForRemoteNotifications()
        }

        // Request user-facing permission in parallel — non-blocking for token registration.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            _appDelegateLogger.fault("[APNs] requestAuthorization result: granted=\(granted, privacy: .public), error=\(error?.localizedDescription ?? "nil", privacy: .public)")
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        regularPushToken = deviceToken

        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        _appDelegateLogger.fault("[APNs] Regular push token received: \(tokenHex.prefix(16), privacy: .public)... len=\(deviceToken.count, privacy: .public)")

        onRegularTokenReceived?(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        _appDelegateLogger.fault("[APNs] Failed to register: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - CXProviderDelegate

extension AppDelegate: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        _appDelegateLogger.fault("[CallKit] providerDidReset — ending all active calls")
        // Provider was reset — end all active calls
        onCallEnd?()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        _appDelegateLogger.fault("[CallKit] CXAnswerCallAction received, callUUID=\(action.callUUID, privacy: .public)")
        action.fulfill()
        onCallAnswer?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        _appDelegateLogger.fault("[CallKit] CXEndCallAction received, callUUID=\(action.callUUID, privacy: .public)")
        action.fulfill()
        onCallEnd?()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        _appDelegateLogger.fault("[CallKit] CXSetMutedCallAction received, muted=\(action.isMuted, privacy: .public)")
        action.fulfill()
        onCallMute?()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CRITICAL: Tell WebRTC that CallKit activated the audio session
        // Without this, WebRTC's audio module won't route audio
        _appDelegateLogger.fault("[CallKit] didActivate audioSession called")
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        _appDelegateLogger.fault("[CallKit] didActivate — isAudioEnabled set to true")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        _appDelegateLogger.fault("[CallKit] didDeactivate audioSession — isAudioEnabled=false")
        // Tell WebRTC that CallKit deactivated the audio session
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}

// MARK: - PKPushRegistryDelegate

extension AppDelegate: PKPushRegistryDelegate {

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        // VoIP push token получен — сохраняем и уведомляем
        let tokenData = pushCredentials.token
        voipToken = tokenData

        let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
        _appDelegateLogger.fault("[PushKit] VoIP token received: \(tokenHex.prefix(16), privacy: .public)... len=\(tokenData.count, privacy: .public)")

        onVoIPTokenReceived?(tokenData)
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        _appDelegateLogger.fault("[PushKit] didReceiveIncomingPush type=\(type.rawValue, privacy: .public)")
        guard type == .voIP else {
            _appDelegateLogger.fault("[PushKit] push ignored (non-voIP)")
            completion()
            return
        }

        // IMPORTANT: iOS требует немедленного вызова reportNewIncomingCall
        // после получения VoIP push, иначе приложение будет убито
        let uuid = UUID()
        let callerName = payload.dictionaryPayload["callerName"] as? String ?? "Ghost Chat"
        let roomId = payload.dictionaryPayload["roomId"] as? String
        _appDelegateLogger.fault("[PushKit] VoIP push: callerName=\(callerName, privacy: .public), hasRoomId=\(roomId != nil, privacy: .public)")

        reportIncomingCall(uuid: uuid, handle: callerName) { [weak self] error in
            if let error {
                _appDelegateLogger.fault("[PushKit] reportIncomingCall FAILED: \(error.localizedDescription, privacy: .public)")
            } else {
                _appDelegateLogger.fault("[PushKit] reportIncomingCall OK, invoking onPushReceived")
                // CallKit показал UI — уведомляем ChatViewModel для подключения к комнате.
                // Если callback ещё не привязан (cold start до инициализации ChatViewModel),
                // буферизируем push и flushнём когда callback установится.
                if let cb = self?.onPushReceived {
                    cb(roomId, uuid, callerName)
                } else {
                    _appDelegateLogger.fault("[PushKit] onPushReceived NOT WIRED — buffering push for later flush")
                    self?.pendingVoIPPush = (roomId: roomId, uuid: uuid, callerName: callerName)
                }
            }
            completion()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate (Chat Invite Push)

extension AppDelegate: UNUserNotificationCenterDelegate {

    // Показать уведомление даже когда приложение на переднем плане
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let pushType = userInfo["type"] as? String
        _appDelegateLogger.fault("[UNC] willPresent pushType=\(pushType ?? "nil", privacy: .public)")

        // Chat invite — in-app баннер вместо системного уведомления
        if pushType == "chat-invite",
           let roomId = userInfo["roomId"] as? String,
           let inviterName = userInfo["inviterName"] as? String {
            onInviteReceived?(roomId, inviterName)
            completionHandler([])
            return
        }

        // New message / missed call — подавляем если пользователь уже в чате с этим контактом
        if pushType == "new-message" || pushType == "missed-call" {
            let senderName = userInfo["senderName"] as? String ?? "Ghost Chat"

            // Если пользователь сейчас в чате с отправителем — не показываем push
            if activeContactName != nil && activeContactName == senderName {
                onMessagePushReceived?(pushType!, senderName)
                completionHandler([])
                return
            }

            // Показываем уведомление (banner + sound + notification center)
            completionHandler([.banner, .sound, .list])
            return
        }

        completionHandler([.banner, .sound, .list])
    }

    // Обработка тапа на уведомление
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let pushType = userInfo["type"] as? String
        _appDelegateLogger.fault("[UNC] didReceive response pushType=\(pushType ?? "nil", privacy: .public)")

        if pushType == "chat-invite",
           let roomId = userInfo["roomId"] as? String,
           let inviterName = userInfo["inviterName"] as? String {
            onInviteReceived?(roomId, inviterName)
        }

        // Тап на уведомление о сообщении/пропущенном звонке
        if pushType == "new-message" || pushType == "missed-call" {
            let senderName = userInfo["senderName"] as? String ?? "Ghost Chat"
            onMessagePushReceived?(pushType!, senderName)
        }

        completionHandler()
    }
}
