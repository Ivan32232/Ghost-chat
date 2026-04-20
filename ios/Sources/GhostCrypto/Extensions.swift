import CryptoKit
import Foundation

extension Data {
    /// Init from hex string (e.g. "48656c6c6f")
    public init?(hex: String) {
        let len = hex.count
        guard len % 2 == 0 else { return nil }
        var data = Data(capacity: len / 2)
        var index = hex.startIndex
        for _ in 0..<len / 2 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

extension Data {
    /// Hex string representation (lowercase)
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension SymmetricKey {
    /// Raw bytes as Data
    public var rawData: Data {
        withUnsafeBytes { ptr in Data(bytes: ptr.baseAddress!, count: ptr.count) }
    }
}

extension SharedSecret {
    /// Raw bytes as Data (for cross-platform comparison)
    public var rawData: Data {
        withUnsafeBytes { ptr in Data(bytes: ptr.baseAddress!, count: ptr.count) }
    }
}
