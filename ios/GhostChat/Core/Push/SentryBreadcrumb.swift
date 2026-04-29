import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Lowercase-hex encode/decode helpers for raw push-token bytes. Kept here
/// (rather than as a private extension on `ContactManager`) so the wire
/// format is reusable between PushManager / ConnectionManager / ContactManager.
extension Data {
    /// Lowercase hex without a `0x` prefix. Used for VoIP/APNs/FCM token
    /// transport over the encrypted control channel.
    var tokenHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Inverse of `tokenHex`. Returns `nil` on odd length or invalid chars.
    init?(tokenHex hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out = Data(); out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self = out
    }
}

/// Tiny shim around Sentry's `Breadcrumb` API plus `print` fallback so push
/// lifecycle events show up both in the local debug console (visible during
/// `xcrun simctl spawn ... log stream`) and in Sentry crash reports — without
/// ever logging token bytes themselves.
enum SentryBreadcrumb {
    /// Records a breadcrumb in the "push" category. The caller must NEVER
    /// include token bytes in `message`; pass length / kind only.
    static func push(_ message: String) {
        // Always print so simulator log captures the event.
        print("🔔 \(message)")
        #if canImport(Sentry)
        let crumb = Breadcrumb()
        crumb.category = "push"
        crumb.level = .info
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }
}
