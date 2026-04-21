import Darwin
import Foundation

// Swift flags the unix `fork()` symbol as `@available(*, unavailable)` on iOS
// because sandboxed app binaries cannot legally call it. The jailbreak
// detector intentionally PROBES the call — on a sandbox-relaxed (jailbroken)
// device it succeeds and we reap the child. `@_silgen_name` bypasses the
// availability attribute so we can still link the libc symbol; on a sandboxed
// device the kernel returns -1 + EPERM and we just move on.
@_silgen_name("fork") private func _jb_fork() -> pid_t

enum JailbreakStatus: Equatable {
    case safe
    case suspicious
}

struct JailbreakReport: Equatable {
    let status: JailbreakStatus
    /// Specific heuristic hits (`path:/Applications/Cydia.app`, `fork-succeeded`, …).
    /// Useful for diagnostics in the SecurityDashboard and never sent to the peer
    /// beyond a boolean "rooted-device" security-alert flag.
    let markers: [String]
}

/// Best-effort jailbreak detection.
///
/// Per spec ("Warn user but don't block"), we surface a boolean and the list of
/// markers we hit to the `SecurityDashboard`. We do NOT block the session — some
/// legitimate users run jailbroken devices and we'd rather err on the side of
/// usability. The report also drives a one-shot `security-alert` control message
/// so the peer knows to treat the session with extra caution.
///
/// Heuristics covered:
/// 1. Well-known Cydia / MobileSubstrate / apt filesystem paths.
/// 2. `fork()` success — sandboxed apps are denied fork by the kernel; on
///    jailbroken devices, the sandbox is typically relaxed.
/// 3. Ability to open `/etc/fstab` or `/private/var/stash/` for reading.
///
/// Simulator must always report `.safe` — we early-return on `targetEnvironment(simulator)`.
enum JailbreakDetector {

    /// Absolute paths we'd expect to see only on a jailbroken device.
    static let knownPaths: [String] = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/Library/MobileSubstrate/DynamicLibraries/",
        "/usr/libexec/cydia/",
        "/usr/sbin/sshd",
        "/usr/bin/ssh",
        "/etc/apt",
        "/private/var/lib/apt/",
        "/private/var/stash/",
        "/bin/bash",
        "/bin/sh"
    ]

    /// Run all heuristics and return a report.
    /// - Parameter extraPaths: additional paths to check (tests inject fake markers here).
    /// - Parameter simulator: set to `false` to force heuristics even on simulator (tests).
    static func detect(extraPaths: [String] = [],
                       simulator: Bool = isSimulator()) -> JailbreakReport {
        if simulator {
            return JailbreakReport(status: .safe, markers: [])
        }

        var markers: [String] = []
        let fm = FileManager.default

        for p in (knownPaths + extraPaths) {
            if fm.fileExists(atPath: p) {
                markers.append("path:\(p)")
            }
        }

        // fork(2) success — the iOS sandbox denies fork (returns -1 with EPERM).
        // On a jailbroken device, this often succeeds; if so, we reap the child
        // and note the marker. We guard with `targetEnvironment(simulator)` via
        // the `simulator` flag above so tests on the sim never trip it.
        #if !targetEnvironment(simulator)
        let pid = _jb_fork()
        if pid >= 0 {
            markers.append("fork-succeeded")
            if pid > 0 {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
            } else {
                exit(0) // child — exit immediately
            }
        }
        #endif

        // Open /private/ to confirm we can read outside the app container.
        if let handle = fopen("/private/var/stash/", "r") {
            markers.append("readable:/private/var/stash/")
            fclose(handle)
        }

        return JailbreakReport(
            status: markers.isEmpty ? .safe : .suspicious,
            markers: markers
        )
    }

    static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
