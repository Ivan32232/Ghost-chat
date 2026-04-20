import AVFoundation
import Foundation

/// Plays short in-app sound effects. Sound files belong in `Resources/Sounds/` (CAF).
/// Missing files are logged-and-ignored rather than crashing — Phase 3 ships without assets.
final class SoundLibrary {

    enum Sound: String, CaseIterable {
        case ringtone
        case incomingMessage
        case sent
        case failed

        var fileName: String {
            switch self {
            case .ringtone:        return "ringtone.caf"
            case .incomingMessage: return "message-in.caf"
            case .sent:            return "message-out.caf"
            case .failed:          return "failed.caf"
            }
        }
    }

    private var players: [Sound: AVAudioPlayer] = [:]
    private var muted: Bool = false

    var isMuted: Bool { muted }

    init(muted: Bool = false) {
        self.muted = muted
    }

    func setMuted(_ value: Bool) {
        muted = value
        if value { stopAll() }
    }

    func play(_ sound: Sound, loop: Bool = false) {
        guard !muted else { return }
        do {
            let player = try makeOrGetPlayer(for: sound)
            player.numberOfLoops = loop ? -1 : 0
            player.currentTime = 0
            player.play()
        } catch {
            // Missing asset in Phase 3 — silent no-op.
        }
    }

    func stop(_ sound: Sound) {
        players[sound]?.stop()
    }

    func stopAll() {
        players.values.forEach { $0.stop() }
    }

    // MARK: - Private

    private func makeOrGetPlayer(for sound: Sound) throws -> AVAudioPlayer {
        if let cached = players[sound] { return cached }
        guard let url = Bundle.main.url(forResource: (sound.fileName as NSString).deletingPathExtension,
                                        withExtension: (sound.fileName as NSString).pathExtension) else {
            throw NSError(domain: "SoundLibrary", code: 404, userInfo: [NSLocalizedDescriptionKey: "missing \(sound.fileName)"])
        }
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        players[sound] = player
        return player
    }
}
