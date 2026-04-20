import XCTest
import UIKit
@testable import GhostChat

final class SecurityMonitorTests: XCTestCase {

    func test_screenshotNotification_yieldsScreenshotEvent() async {
        let center = NotificationCenter()
        let monitor = SecurityMonitor(notificationCenter: center)
        defer { monitor.stop() }

        let expectation = expectation(description: "event")
        Task {
            for await event in monitor.events {
                if case .screenshot = event {
                    expectation.fulfill()
                    break
                }
            }
        }

        // Run on main queue because the observer registration uses queue: .main
        await MainActor.run {
            center.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_screenRecording_objectNotScreen_yieldsInactive() async {
        let center = NotificationCenter()
        let monitor = SecurityMonitor(notificationCenter: center)
        defer { monitor.stop() }

        let expectation = expectation(description: "event")
        Task {
            for await event in monitor.events {
                if case .screenRecording(let active) = event {
                    XCTAssertFalse(active)
                    expectation.fulfill()
                    break
                }
            }
        }

        await MainActor.run {
            center.post(name: UIScreen.capturedDidChangeNotification, object: NSObject())
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }
}
