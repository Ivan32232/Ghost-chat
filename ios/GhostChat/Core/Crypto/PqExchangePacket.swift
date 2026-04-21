import Foundation

/// Second-round handshake packet — GUEST-originated. Sent over the plaintext DataChannel
/// *after* the initial simultaneous exchange of `KeyExchangePacket`s, iff HOST advertised
/// a Kyber public key in its `pqKey` field and the GUEST can do ML-KEM encapsulation.
///
/// HOST decapsulates the `pqCiphertext` into the 32-byte PQ shared secret, combines it
/// with the ECDH shared secret via `PostQuantum.hybridDeriveSharedKey`, and only then
/// initialises its DoubleRatchet — before that it sits in an `awaitingPq` state.
///
/// Wire shape: `{"type":"pq-exchange","pqCiphertext":"<base64>"}`.
/// Byte-identical to Android `PqExchangePacket`.
struct PqExchangePacket: Codable, Equatable {
    let type: String           // always "pq-exchange"
    let pqCiphertext: Data     // 1088 bytes (ML-KEM768 ciphertext), base64 over the wire

    init(pqCiphertext: Data) {
        self.type = "pq-exchange"
        self.pqCiphertext = pqCiphertext
    }
}
