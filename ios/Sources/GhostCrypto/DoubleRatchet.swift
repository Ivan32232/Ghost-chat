import CryptoKit
import Foundation
import Security

// MARK: - Key Pair Generator Protocol

public protocol KeyPairGenerating: AnyObject {
    func generateKeyPair() -> P256.KeyAgreement.PrivateKey
}

/// Default generator: random P-256 keys
public final class RandomKeyPairGenerator: KeyPairGenerating {
    public init() {}
    public func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }
}

// MARK: - Encrypted Message Result

public struct EncryptedMessage {
    public let wireBase64: String
    #if DEBUG
    // Test-only: reveals the message key used to produce `wireBase64`.
    // Compiled out in release builds — keep out of any production code path.
    public let debugMessageKey: Data?
    #endif
}

// MARK: - Double Ratchet

public enum RatchetRole { case host, guest }

public struct DoubleRatchet {

    // Ratchet state
    private var dhs: P256.KeyAgreement.PrivateKey     // our DH keypair
    private var dhr: P256.KeyAgreement.PublicKey?      // their DH public key
    private var rk: SymmetricKey                       // root key
    private var cks: SymmetricKey?                     // sending chain key
    private var ckr: SymmetricKey?                     // receiving chain key
    private var ns: UInt32 = 0                         // send counter
    private var nr: UInt32 = 0                         // receive counter
    private var pn: UInt32 = 0                         // previous chain length

    // Skipped message keys: (dhPubRaw hex + ":" + messageNumber) → messageKey
    private var mkSkipped: [String: SymmetricKey] = [:]
    private let maxSkip: UInt32 = 100

    // Last seen DH key (for detecting ratchet triggers)
    private var lastDHr: Data?

    private let keyGen: KeyPairGenerating

    // MARK: - Init

    /// Initialize Double Ratchet.
    /// HOST: generates new DHs, does initial ratchet with guest's public key.
    /// GUEST: uses own ephemeral key as DHs, waits for first message.
    public init(
        role: RatchetRole,
        sharedKey: SymmetricKey,
        ourKeyPair: P256.KeyAgreement.PrivateKey,
        theirPublicKey: P256.KeyAgreement.PublicKey?,
        keyPairGenerator: KeyPairGenerating? = nil
    ) {
        self.keyGen = keyPairGenerator ?? RandomKeyPairGenerator()

        switch role {
        case .host:
            // HOST: DHs = provided keypair, DHr = guest's public key
            self.dhs = ourKeyPair
            self.dhr = theirPublicKey
            self.rk = sharedKey

            // Initial DH ratchet step — set up sending chain
            if let peerPub = theirPublicKey {
                let dhOutput = try! dhs.sharedSecretFromKeyAgreement(with: peerPub).rawData
                let result = CryptoUtils.rootKDF(rootKey: self.rk, dhOutput: dhOutput)
                self.rk = result.newRootKey
                self.cks = result.chainKey
            }
            self.ckr = nil
            self.lastDHr = theirPublicKey.map { dhPublicKeyRaw($0) }

        case .guest:
            // GUEST: DHs = own ephemeral, DHr = nil, RK = shared key
            self.dhs = ourKeyPair
            self.dhr = nil
            self.rk = sharedKey
            self.cks = nil
            self.ckr = nil
        }
    }

    // MARK: - Encrypt

    /// Encrypt plaintext and return wire-format base64 string.
    public mutating func encrypt(
        plaintext: String,
        deterministicNonce: Data? = nil,
        deterministicPadByte: UInt8? = nil
    ) throws -> EncryptedMessage {
        guard let cks = self.cks else {
            throw RatchetError.noSendingChain
        }

        // Chain KDF → message key
        let chain = CryptoUtils.chainKDF(chainKey: cks)
        self.cks = chain.nextChainKey

        // Pad message
        let padded: Data
        if let padByte = deterministicPadByte {
            padded = MessagePadding.pad(plaintext, deterministicPadByte: padByte)
        } else {
            padded = MessagePadding.pad(plaintext)
        }

        // Build header
        let dhPubRaw = dhPublicKeyRaw(dhs.publicKey)
        let header = WireFormat.buildHeader(dhPublicKeyRaw: dhPubRaw, pn: pn, n: ns)

        // Nonce: random or deterministic for tests
        let nonceData: Data
        if let dn = deterministicNonce {
            nonceData = dn
        } else {
            var randomNonce = Data(count: 12)
            randomNonce.withUnsafeMutableBytes { buf in
                _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
            }
            nonceData = randomNonce
        }

        let nonce = try AES.GCM.Nonce(data: nonceData)

        // AES-256-GCM encrypt with header as AAD
        let sealed = try AES.GCM.seal(padded, using: chain.messageKey, nonce: nonce, authenticating: header)

        // Build wire message
        let wire = WireFormat.buildMessage(
            header: header,
            nonce: nonceData,
            ciphertext: sealed.ciphertext,
            tag: Data(Array(sealed.tag))
        )

        ns += 1

        #if DEBUG
        let mkData = chain.messageKey.rawData
        return EncryptedMessage(
            wireBase64: wire.base64EncodedString(),
            debugMessageKey: mkData
        )
        #else
        return EncryptedMessage(
            wireBase64: wire.base64EncodedString()
        )
        #endif
    }

    // MARK: - Decrypt

    /// Decrypt a wire-format base64 string, returning the plaintext.
    public mutating func decrypt(wireBase64: String) throws -> String {
        guard let wireData = Data(base64Encoded: wireBase64) else {
            throw RatchetError.invalidBase64
        }

        let parsed = try WireFormat.parseMessage(wireData)
        let headerParsed = try WireFormat.parseHeader(parsed.header)

        // Reconstruct peer's public key from header (add 04 prefix for x963)
        let peerDHPubRaw = headerParsed.dhPublicKeyRaw
        let peerDHPubX963 = Data([0x04]) + peerDHPubRaw
        let peerPub = try P256.KeyAgreement.PublicKey(x963Representation: peerDHPubX963)

        // Check if this is a skipped message
        let skipKey = peerDHPubRaw.hexString + ":" + String(headerParsed.n)
        if let mk = mkSkipped[skipKey] {
            mkSkipped.removeValue(forKey: skipKey)
            return try decryptWithKey(mk, parsed: parsed)
        }

        // Check if we need a DH ratchet step
        let peerRawHex = peerDHPubRaw.hexString
        let currentDHrHex = lastDHr?.hexString

        if peerRawHex != currentDHrHex {
            // Skip missed messages from current receiving chain
            if self.ckr != nil {
                try skipMessages(until: headerParsed.pn, dhPubRaw: lastDHr!)
            }

            // DH ratchet step
            self.pn = self.ns
            self.ns = 0
            self.nr = 0
            self.dhr = peerPub
            self.lastDHr = peerDHPubRaw

            // Receiving chain
            let dhRecv = try dhs.sharedSecretFromKeyAgreement(with: peerPub).rawData
            let recvResult = CryptoUtils.rootKDF(rootKey: rk, dhOutput: dhRecv)
            self.rk = recvResult.newRootKey
            self.ckr = recvResult.chainKey

            // New sending keypair + chain
            self.dhs = keyGen.generateKeyPair()
            let dhSend = try dhs.sharedSecretFromKeyAgreement(with: peerPub).rawData
            let sendResult = CryptoUtils.rootKDF(rootKey: rk, dhOutput: dhSend)
            self.rk = sendResult.newRootKey
            self.cks = sendResult.chainKey
        }

        // Skip any missed messages in current receiving chain
        try skipMessages(until: headerParsed.n, dhPubRaw: peerDHPubRaw)

        // Chain KDF for this message
        guard let ckr = self.ckr else {
            throw RatchetError.noReceivingChain
        }
        let chain = CryptoUtils.chainKDF(chainKey: ckr)
        self.ckr = chain.nextChainKey
        self.nr += 1

        return try decryptWithKey(chain.messageKey, parsed: parsed)
    }

    // MARK: - Private Helpers

    private mutating func skipMessages(until n: UInt32, dhPubRaw: Data) throws {
        guard var ckr = self.ckr else { return }

        while nr < n {
            guard mkSkipped.count < maxSkip else {
                throw RatchetError.tooManySkippedMessages
            }
            let chain = CryptoUtils.chainKDF(chainKey: ckr)
            let key = dhPubRaw.hexString + ":" + String(nr)
            mkSkipped[key] = chain.messageKey
            ckr = chain.nextChainKey
            nr += 1
        }
        self.ckr = ckr
    }

    private func decryptWithKey(_ messageKey: SymmetricKey, parsed: WireFormat.ParsedMessage) throws -> String {
        let nonce = try AES.GCM.Nonce(data: parsed.nonce)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: parsed.ciphertext, tag: parsed.tag)
        let padded = try AES.GCM.open(box, using: messageKey, authenticating: parsed.header)
        return MessagePadding.unpad(padded)
    }
}

// MARK: - Errors

public enum RatchetError: Error {
    case noSendingChain
    case noReceivingChain
    case invalidBase64
    case tooManySkippedMessages
    case replayDetected
}

// MARK: - Helpers

/// Extract 64-byte raw public key (no 04 prefix) from P256 public key
private func dhPublicKeyRaw(_ key: P256.KeyAgreement.PublicKey) -> Data {
    let x963 = key.x963Representation
    return Data(x963.dropFirst()) // Remove 04 prefix
}

