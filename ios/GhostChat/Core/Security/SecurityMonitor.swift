import AVFoundation
import Foundation
import UIKit

enum SecurityEvent: Equatable {
    case screenshot
    case screenRecording(active: Bool)
    case audioRouteChanged(output: String)
}

final class SecurityMonitor {

    private(set) var events: AsyncStream<SecurityEvent>!
    private var continuation: AsyncStream<SecurityEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.events = AsyncStream { [weak self] cont in
            self?.continuation = cont
            cont.onTermination = { [weak self] _ in
                self?.unsubscribe(from: notificationCenter)
            }
        }
        subscribe(to: notificationCenter)
    }

    deinit {
        continuation?.finish()
    }

    func stop() {
        continuation?.finish()
    }

    private func subscribe(to center: NotificationCenter) {
        observers.append(
            center.addObserver(
                forName: UIApplication.userDidTakeScreenshotNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.continuation?.yield(.screenshot)
            }
        )
        observers.append(
            center.addObserver(
                forName: UIScreen.capturedDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let screen = note.object as? UIScreen else {
                    self?.continuation?.yield(.screenRecording(active: false))
                    return
                }
                self?.continuation?.yield(.screenRecording(active: screen.isCaptured))
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                let out = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "unknown"
                self?.continuation?.yield(.audioRouteChanged(output: out))
            }
        )
    }

    private func unsubscribe(from center: NotificationCenter) {
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }
}
