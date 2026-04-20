import AVFoundation
import Foundation
import WebRTC

/// Audio routing + track management for a live call.
///
/// CRITICAL: `configureAudioSession()` / `releaseAudioSession()` must only be called from
/// inside `CXProviderDelegate.didActivate` / `didDeactivate` — iOS blocks `setActive(true)`
/// outside of that window.
final class GhostVoice {

    enum Error: Swift.Error, Equatable {
        case noPeerConnection
    }

    private let factory: RTCPeerConnectionFactory
    private(set) var audioTrack: RTCAudioTrack?
    private var audioSender: RTCRtpSender?

    init(factory: RTCPeerConnectionFactory = GhostRTCFactory.shared) {
        self.factory = factory
    }

    // MARK: - Track

    /// Adds a microphone track to the given peer connection. Returns the sender so the
    /// caller can toggle `track.isEnabled` for mute (preserves the transceiver).
    func attachMicrophone(to peerConnection: RTCPeerConnection) throws -> RTCRtpSender {
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true"
            ],
            optionalConstraints: nil
        )
        let source = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: source, trackId: "ghost-audio-0")
        guard let sender = peerConnection.add(track, streamIds: ["ghost-audio-stream"]) else {
            throw Error.noPeerConnection
        }
        self.audioTrack = track
        self.audioSender = sender
        return sender
    }

    func detachMicrophone(from peerConnection: RTCPeerConnection) {
        if let sender = audioSender {
            peerConnection.removeTrack(sender)
        }
        audioTrack = nil
        audioSender = nil
    }

    // MARK: - Mute (transceiver-preserving)

    func setMuted(_ muted: Bool) {
        audioTrack?.isEnabled = !muted
    }

    var isMuted: Bool { audioTrack?.isEnabled == false }

    // MARK: - AVAudioSession

    func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.010)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func releaseAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setSpeaker(_ speakerOn: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
    }
}
