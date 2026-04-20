import AVFoundation
import Foundation

/// Records voice messages as AAC m4a (44.1 kHz mono, 64 kbps).
/// Exposes real-time amplitude samples at 50 ms intervals for waveform visualization.
/// Phase 3 scaffolds the recorder; transport over DataChannel lands in Phase 5.
final class VoiceRecorder: NSObject {

    enum Error: Swift.Error, Equatable {
        case notRecording
        case alreadyRecording
        case tooShort
    }

    struct Result {
        let data: Data
        let duration: TimeInterval
        let amplitudes: [Float]
    }

    static let minimumDuration: TimeInterval = 0.3
    static let sampleRate: Double = 44_100
    static let bitRate: Int = 64_000

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startAt: Date?
    private var meterTimer: Timer?
    private(set) var amplitudes: [Float] = []

    var isRecording: Bool { recorder?.isRecording == true }

    static let settings: [String: Any] = [
        AVFormatIDKey:             kAudioFormatMPEG4AAC,
        AVSampleRateKey:           sampleRate,
        AVNumberOfChannelsKey:     1,
        AVEncoderBitRateKey:       bitRate,
        AVEncoderAudioQualityKey:  AVAudioQuality.medium.rawValue
    ]

    // MARK: - Lifecycle

    func start() throws {
        guard recorder == nil else { throw Error.alreadyRecording }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let rec = try AVAudioRecorder(url: url, settings: Self.settings)
        rec.isMeteringEnabled = true
        rec.prepareToRecord()
        guard rec.record() else {
            throw Error.alreadyRecording
        }
        self.recorder = rec
        self.fileURL = url
        self.amplitudes = []
        self.startAt = Date()
        scheduleMeterTimer()
    }

    func stop() throws -> Result {
        guard let rec = recorder, let started = startAt, let url = fileURL else {
            throw Error.notRecording
        }
        meterTimer?.invalidate()
        meterTimer = nil
        rec.stop()
        let duration = Date().timeIntervalSince(started)
        defer {
            recorder = nil
            fileURL = nil
            startAt = nil
            try? FileManager.default.removeItem(at: url)
        }
        guard duration >= Self.minimumDuration else { throw Error.tooShort }
        let data = try Data(contentsOf: url)
        return Result(data: data, duration: duration, amplitudes: amplitudes)
    }

    func cancel() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        fileURL = nil
        startAt = nil
        amplitudes = []
    }

    // MARK: - Metering

    private func scheduleMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder else { return }
            rec.updateMeters()
            let normalized = max(0, (rec.averagePower(forChannel: 0) + 60) / 60)
            self.amplitudes.append(normalized)
        }
        if let t = meterTimer { RunLoop.main.add(t, forMode: .common) }
    }
}
