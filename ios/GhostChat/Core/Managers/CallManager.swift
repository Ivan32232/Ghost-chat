import AVFoundation
import CallKit
import Foundation

/// State machine + CallKit integration for voice calls.
/// Audio session is configured ONLY inside `CXProviderDelegate.didActivate` — that is the
/// iOS contract; setting it anywhere else fails silently.
@MainActor
final class CallManager: NSObject, ObservableObject {

    @Published private(set) var state: CallState = .idle
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var isSpeakerOn: Bool = false
    @Published private(set) var duration: TimeInterval = 0

    private let provider: CXProvider
    private let controller: CXCallController
    private let voice: GhostVoice
    private var currentUUID: UUID?
    private var timer: Timer?
    private var startAt: Date?

    init(voice: GhostVoice = GhostVoice()) {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.includesCallsInRecents = false
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        self.provider = CXProvider(configuration: cfg)
        self.controller = CXCallController()
        self.voice = voice
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: - Public API

    /// Starts an outgoing call (asks CallKit to report it).
    func startOutgoing(peerName: String) async throws {
        let uuid = UUID()
        currentUUID = uuid
        state = .outgoingPending
        let handle = CXHandle(type: .generic, value: peerName)
        let start = CXStartCallAction(call: uuid, handle: handle)
        let transaction = CXTransaction(action: start)
        try await controller.request(transaction)
    }

    /// Reports an incoming call (e.g., from VoIP push).
    func reportIncoming(uuid: UUID, from peerName: String) async throws {
        currentUUID = uuid
        state = .incoming
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.hasVideo = false
        try await provider.reportNewIncomingCall(with: uuid, update: update)
    }

    func end() async throws {
        // Ask CallKit first if we ever reported the call. Our simulator test flow can
        // leave the call stuck in `outgoingRinging` (no peer accepts → no report-connected
        // call delegate callback), in which case CallKit refuses the EndCall transaction.
        // Always force-terminate the local state as a fallback so the UI's onChange(of:
        // calls.state) fires and dismisses the CallView.
        if let uuid = currentUUID {
            let action = CXEndCallAction(call: uuid)
            let tx = CXTransaction(action: action)
            _ = try? await controller.request(tx)
        }
        forceEndLocal()
    }

    /// Force-cleanup local call state when CallKit can't (or won't) drive the EndCall
    /// action to completion. Safe to call redundantly — idempotent.
    private func forceEndLocal() {
        stopDurationTimer()
        if state != .ended {
            state = .ended
        }
        currentUUID = nil
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        voice.setMuted(muted)
    }

    func setSpeaker(_ on: Bool) {
        isSpeakerOn = on
        try? voice.setSpeaker(on)
    }

    // MARK: - Private

    private func startDurationTimer() {
        startAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startAt else { return }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        timer?.invalidate()
        timer = nil
        startAt = nil
        duration = 0
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            self.stopDurationTimer()
            self.state = .idle
            self.currentUUID = nil
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            self.state = .outgoingRinging
            self.startDurationTimer()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            self.state = .active
            self.startDurationTimer()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.stopDurationTimer()
            self.state = .ended
            self.currentUUID = nil
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            try? self.voice.configureAudioSession()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.voice.releaseAudioSession()
        }
    }
}
