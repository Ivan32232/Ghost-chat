import Foundation
import Security

public enum MessagePadding {

    /// Pad message: 4-char length prefix + base64(message) + random padding to 256-byte boundary.
    /// `deterministicPadByte`: if non-nil, use this byte for padding instead of random (test only).
    public static func pad(_ message: String, deterministicPadByte: UInt8? = nil) -> Data {
        let b64 = Data(message.utf8).base64EncodedString()
        let lenPrefix = String(format: "%04d", b64.count)
        let content = Data((lenPrefix + b64).utf8)
        let padTo = content.count == 0 ? 256 : ((content.count + 255) / 256) * 256
        let padLen = padTo - content.count

        var padding: Data
        if let byte = deterministicPadByte {
            padding = Data(repeating: byte, count: padLen)
        } else {
            padding = Data(count: padLen)
            padding.withUnsafeMutableBytes { buf in
                _ = SecRandomCopyBytes(kSecRandomDefault, padLen, buf.baseAddress!)
            }
        }
        return content + padding
    }

    /// Unpad: read 4-char length prefix, extract base64, decode.
    public static func unpad(_ padded: Data) -> String {
        guard padded.count >= 4 else { return "" }
        let lenStr = String(data: padded.prefix(4), encoding: .utf8) ?? "0"
        let b64Len = Int(lenStr) ?? 0
        guard padded.count >= 4 + b64Len else { return "" }
        let b64Str = String(data: padded[4..<(4 + b64Len)], encoding: .utf8) ?? ""
        guard let decoded = Data(base64Encoded: b64Str) else { return "" }
        return String(data: decoded, encoding: .utf8) ?? ""
    }
}
