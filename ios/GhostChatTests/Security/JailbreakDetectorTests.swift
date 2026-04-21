import XCTest
@testable import GhostChat

final class JailbreakDetectorTests: XCTestCase {

    func test_simulator_reportsSafe() {
        // On CI / dev sim the detector must always say .safe so normal
        // development flows never light up the dashboard.
        let r = JailbreakDetector.detect()
        XCTAssertEqual(r.status, .safe)
        XCTAssertTrue(r.markers.isEmpty)
    }

    func test_injectedPath_triggersSuspiciousOnDevice() throws {
        // Force `simulator=false` so the filesystem paths get checked.
        // Create a unique temp marker so we don't collide with any real file.
        let tmp = NSTemporaryDirectory() + "fake-jb-\(UUID().uuidString).marker"
        FileManager.default.createFile(atPath: tmp, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = JailbreakDetector.detect(extraPaths: [tmp], simulator: false)
        XCTAssertEqual(r.status, .suspicious)
        XCTAssertTrue(r.markers.contains("path:\(tmp)"))
    }

    func test_emptyExtraPaths_inSimulatorMode_stillSafe() {
        let r = JailbreakDetector.detect(extraPaths: [], simulator: true)
        XCTAssertEqual(r.status, .safe)
    }

    func test_multipleMarkersAreCollected() throws {
        let a = NSTemporaryDirectory() + "marker-a-\(UUID().uuidString)"
        let b = NSTemporaryDirectory() + "marker-b-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: a, contents: Data())
        FileManager.default.createFile(atPath: b, contents: Data())
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }
        let r = JailbreakDetector.detect(extraPaths: [a, b], simulator: false)
        XCTAssertEqual(r.status, .suspicious)
        XCTAssertTrue(r.markers.contains("path:\(a)"))
        XCTAssertTrue(r.markers.contains("path:\(b)"))
    }

    func test_knownPathsListIncludesSpecCandidates() {
        // Spec: "iOS: Cydia, /etc/apt, fork() success, MobileSubstrate"
        XCTAssertTrue(JailbreakDetector.knownPaths.contains("/Applications/Cydia.app"))
        XCTAssertTrue(JailbreakDetector.knownPaths.contains("/etc/apt"))
        XCTAssertTrue(JailbreakDetector.knownPaths.contains(
            "/Library/MobileSubstrate/MobileSubstrate.dylib"))
    }
}
