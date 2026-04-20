import Foundation

public enum WireFormat {

    public enum WireError: Error {
        case headerTooShort
        case invalidHeaderVersion
        case messageTooShort
        case headerLengthMismatch
    }

    // MARK: - Header: version(1) + dhPubKeyRaw(64) + PN(4, BE) + N(4, BE) = 73 bytes

    public static let headerSize = 73

    public struct ParsedHeader {
        public let version: UInt8
        public let dhPublicKeyRaw: Data  // 64 bytes (x + y, no 04 prefix)
        public let pn: UInt32
        public let n: UInt32
    }

    public static func buildHeader(dhPublicKeyRaw: Data, pn: UInt32, n: UInt32) -> Data {
        var buf = Data(capacity: headerSize)
        buf.append(0x00) // version
        buf.append(dhPublicKeyRaw) // 64 bytes
        var pnBE = pn.bigEndian
        buf.append(Data(bytes: &pnBE, count: 4))
        var nBE = n.bigEndian
        buf.append(Data(bytes: &nBE, count: 4))
        return buf
    }

    public static func parseHeader(_ data: Data) throws -> ParsedHeader {
        guard data.count >= headerSize else { throw WireError.headerTooShort }
        let version = data[data.startIndex]
        guard version == 0x00 else { throw WireError.invalidHeaderVersion }
        let dhPubRaw = data[(data.startIndex + 1)..<(data.startIndex + 65)]
        let pn = data[(data.startIndex + 65)..<(data.startIndex + 69)].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
        let n = data[(data.startIndex + 69)..<(data.startIndex + 73)].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
        return ParsedHeader(version: version, dhPublicKeyRaw: Data(dhPubRaw), pn: pn, n: n)
    }

    // MARK: - Wire message: headerLen(4, BE) + header + nonce(12) + ciphertext + tag(16)

    public struct ParsedMessage {
        public let header: Data
        public let nonce: Data       // 12 bytes
        public let ciphertext: Data
        public let tag: Data         // 16 bytes
    }

    public static func buildMessage(header: Data, nonce: Data, ciphertext: Data, tag: Data) -> Data {
        var buf = Data(capacity: 4 + header.count + nonce.count + ciphertext.count + tag.count)
        var headerLenBE = UInt32(header.count).bigEndian
        buf.append(Data(bytes: &headerLenBE, count: 4))
        buf.append(header)
        buf.append(nonce)
        buf.append(ciphertext)
        buf.append(tag)
        return buf
    }

    public static func parseMessage(_ data: Data) throws -> ParsedMessage {
        guard data.count >= 4 else { throw WireError.messageTooShort }
        let headerLen = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let expected = 4 + Int(headerLen) + 12 + 16
        guard data.count >= expected else { throw WireError.messageTooShort }

        let headerStart = 4
        let headerEnd = headerStart + Int(headerLen)
        let nonceStart = headerEnd
        let nonceEnd = nonceStart + 12
        let tagStart = data.count - 16
        let ctStart = nonceEnd
        let ctEnd = tagStart

        return ParsedMessage(
            header: Data(data[headerStart..<headerEnd]),
            nonce: Data(data[nonceStart..<nonceEnd]),
            ciphertext: Data(data[ctStart..<ctEnd]),
            tag: Data(data[tagStart..<data.count])
        )
    }
}
