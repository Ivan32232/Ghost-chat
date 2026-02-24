import Foundation
import UIKit
import AVFoundation

/// Мониторинг безопасности — порт security-monitor.js
/// iOS-специфичная реализация: screen capture, audio route changes
final class SecurityMonitor {

    // MARK: - Properties

    private var isMonitoring = false
    private var alertCooldowns: [String: Date] = [:]
    private let alertCooldownInterval: TimeInterval = 10

    private var screenCaptureObserver: NSObjectProtocol?
    private var audioRouteObserver: NSObjectProtocol?

    // MARK: - Callback

    var onAlert: ((SecurityAlert) -> Void)?

    struct SecurityAlert {
        let type: String
        let message: String
        let severity: Severity
        let timestamp: Date

        enum Severity: String {
            case high, medium, low
        }
    }

    // MARK: - Start/Stop

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        setupScreenCaptureDetection()
        setupAudioRouteMonitoring()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        if let observer = screenCaptureObserver {
            NotificationCenter.default.removeObserver(observer)
            screenCaptureObserver = nil
        }

        if let observer = audioRouteObserver {
            NotificationCenter.default.removeObserver(observer)
            audioRouteObserver = nil
        }
    }

    // MARK: - Screen Capture Detection

    /// Детекция записи экрана — UIScreen.isCaptured (нативное API)
    private func setupScreenCaptureDetection() {
        // Проверяем текущее состояние
        if UIScreen.main.isCaptured {
            triggerAlert(
                type: "screen-capture-active",
                message: "Запись экрана активна",
                severity: .high
            )
        }

        // Подписываемся на изменения
        screenCaptureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if UIScreen.main.isCaptured {
                self?.triggerAlert(
                    type: "screen-capture-started",
                    message: "Обнаружена запись экрана",
                    severity: .high
                )
            }
        }
    }

    // MARK: - Audio Route Monitoring

    /// Мониторинг аудио маршрутов — детекция подозрительных устройств
    private func setupAudioRouteMonitoring() {
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let changeReason = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }

            switch changeReason {
            case .newDeviceAvailable:
                let route = AVAudioSession.sharedInstance().currentRoute
                for output in route.outputs {
                    // Bluetooth или другое внешнее устройство
                    if output.portType == .bluetoothA2DP ||
                       output.portType == .bluetoothHFP ||
                       output.portType == .bluetoothLE {
                        self?.triggerAlert(
                            type: "audio-device-change",
                            message: "Подключено Bluetooth устройство: \(output.portName)",
                            severity: .medium
                        )
                    }
                }

            case .oldDeviceUnavailable:
                self?.triggerAlert(
                    type: "audio-device-removed",
                    message: "Аудио устройство отключено",
                    severity: .low
                )

            default:
                break
            }
        }
    }

    // MARK: - Alert

    private func triggerAlert(type: String, message: String, severity: SecurityAlert.Severity) {
        // Cooldown
        if let lastAlert = alertCooldowns[type],
           Date().timeIntervalSince(lastAlert) < alertCooldownInterval {
            return
        }

        alertCooldowns[type] = Date()

        let alert = SecurityAlert(
            type: type,
            message: message,
            severity: severity,
            timestamp: Date()
        )

        onAlert?(alert)
    }

    // MARK: - Cleanup

    func destroy() {
        stopMonitoring()
        onAlert = nil
        alertCooldowns.removeAll()
    }
}
