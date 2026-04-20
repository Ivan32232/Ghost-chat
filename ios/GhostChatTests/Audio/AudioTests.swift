import AVFoundation
import XCTest
@testable import GhostChat

final class SoundLibraryTests: XCTestCase {

    func test_mutedInit_doesNotPlay() {
        let lib = SoundLibrary(muted: true)
        XCTAssertTrue(lib.isMuted)
        lib.play(.ringtone)
        lib.stop(.ringtone)
    }

    func test_setMuted_toggles() {
        let lib = SoundLibrary(muted: false)
        XCTAssertFalse(lib.isMuted)
        lib.setMuted(true)
        XCTAssertTrue(lib.isMuted)
    }

    func test_play_missingAsset_doesNotCrash() {
        let lib = SoundLibrary(muted: false)
        lib.play(.failed)
        lib.stopAll()
    }

    func test_soundEnum_fileNames() {
        XCTAssertEqual(SoundLibrary.Sound.ringtone.fileName, "ringtone.caf")
        XCTAssertEqual(SoundLibrary.Sound.incomingMessage.fileName, "message-in.caf")
        XCTAssertEqual(SoundLibrary.Sound.sent.fileName, "message-out.caf")
        XCTAssertEqual(SoundLibrary.Sound.failed.fileName, "failed.caf")
    }
}

final class VoiceRecorderTests: XCTestCase {

    func test_settings_matchSpec() {
        let s = VoiceRecorder.settings
        XCTAssertEqual(s[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(s[AVSampleRateKey] as? Double, 44_100)
        XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(s[AVEncoderBitRateKey] as? Int, 64_000)
    }

    func test_minimumDuration_is300ms() {
        XCTAssertEqual(VoiceRecorder.minimumDuration, 0.3)
    }

    func test_stopWithoutStart_throwsNotRecording() {
        let rec = VoiceRecorder()
        XCTAssertThrowsError(try rec.stop()) { err in
            XCTAssertEqual(err as? VoiceRecorder.Error, .notRecording)
        }
    }

    func test_cancel_isIdempotent() {
        let rec = VoiceRecorder()
        rec.cancel()
        rec.cancel()
    }
}
