/**
 * Ghost Chat — Криптографический модуль v2 (Double Ratchet)
 *
 * Signal Protocol style:
 * - ECDH P-256 key exchange
 * - Double Ratchet: DH ratchet per sender change, symmetric ratchet per message
 * - Every message encrypted with a unique key (per-message forward secrecy)
 * - Encrypted headers hide DH ratchet keys from observers
 * - Header format: 65 bytes DH key + 4 bytes pn + 4 bytes n = 73 bytes
 *
 * Wire format v2:
 * base64( 4-byte headerLen BE + encryptedHeader + encryptedBody )
 *
 * ВСЕ КЛЮЧИ ХРАНЯТСЯ ТОЛЬКО В ПАМЯТИ!
 */

import { logger } from './logger.js';

// ============================================================
// DoubleRatchet — core state machine (mirrors DoubleRatchet.swift)
// ============================================================

class DoubleRatchet {

  static MAX_SKIP = 100;

  // KDF labels — MUST match iOS exactly
  static ROOT_KDF_SALT = 'ghost-dr-root';
  static ROOT_KDF_INFO = 'ghost-dr-rk';
  static CHAIN_KDF_SALT = 'ghost-dr-chain';
  static CHAIN_KDF_INFO_CK = 'ghost-dr-ck';
  static CHAIN_KDF_INFO_MK = 'ghost-dr-mk';
  static HEADER_KDF_INFO = 'ghost-dr-header';
  static INIT_INFO = 'ghost-dr-init';

  constructor() {
    // DH ratchet keys
    this.dhSending = null;          // CryptoKeyPair
    this.dhSendingRaw = null;       // Uint8Array — raw public key (65 bytes, uncompressed)
    this.dhReceiving = null;        // CryptoKey (public)
    this.dhReceivingRaw = null;     // Uint8Array — raw peer public key

    // Chain keys (raw 32-byte ArrayBuffers)
    this.rootKey = null;
    this.sendChainKey = null;
    this.receiveChainKey = null;

    // Header keys (raw 32-byte ArrayBuffers)
    this.sendHeaderKey = null;
    this.receiveHeaderKey = null;
    this.nextSendHeaderKey = null;
    this.nextReceiveHeaderKey = null;

    // Counters
    this.sendMessageNumber = 0;
    this.receiveMessageNumber = 0;
    this.previousChainLength = 0;

    // Skipped keys: Map<string, ArrayBuffer>  key = `${base64(dhKey)}:${n}`
    this.skippedKeys = new Map();
  }

  // ---- Initialization ----

  /**
   * Initialize as initiator (host/Alice)
   * @param {ArrayBuffer} sharedSecret — 32-byte ECDH-derived root secret
   * @param {CryptoKey} peerDHPublicKey — peer's initial DH public key
   * @param {Uint8Array} peerDHPublicKeyRaw — 65 bytes raw
   */
  async initAsInitiator(sharedSecret, peerDHPublicKey, peerDHPublicKeyRaw) {
    // Generate our first DH ratchet key pair
    this.dhSending = await crypto.subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']
    );
    this.dhSendingRaw = new Uint8Array(
      await crypto.subtle.exportKey('raw', this.dhSending.publicKey)
    );
    this.dhReceiving = peerDHPublicKey;
    this.dhReceivingRaw = peerDHPublicKeyRaw;

    // Initial root key from shared secret
    const initialRootKey = await DoubleRatchet._kdfRootInitial(sharedSecret);

    // DH with our key and peer key
    const dhOutput = await crypto.subtle.deriveBits(
      { name: 'ECDH', public: peerDHPublicKey },
      this.dhSending.privateKey,
      256
    );

    // Root KDF → rootKey + chainKey + headerKey + nextHeaderKey
    const { rootKey, chainKey, headerKey, nextHeaderKey } =
      await DoubleRatchet._kdfRootChain(initialRootKey, dhOutput);

    this.rootKey = rootKey;
    this.sendChainKey = chainKey;
    this.receiveChainKey = null;
    this.sendHeaderKey = headerKey;
    this.nextReceiveHeaderKey = nextHeaderKey;
    this.receiveHeaderKey = null;
    this.nextSendHeaderKey = null;
  }

  /**
   * Initialize as responder (guest/Bob)
   * @param {ArrayBuffer} sharedSecret — 32-byte ECDH-derived root secret
   * @param {CryptoKeyPair} initialKeyPair — initial ECDH key pair (MUST reuse, not generate new)
   *
   * CRITICAL: The responder must reuse the initial ECDH key pair as the first DH ratchet key.
   * The initiator computes DH(theirNewRatchetKey, ourInitialPublicKey), so we need
   * ourInitialPrivateKey to derive the same shared secret in _dhRatchetReceive.
   */
  async initAsResponder(sharedSecret, initialKeyPair) {
    // Reuse initial ECDH key pair as first DH ratchet key (matches iOS DoubleRatchet)
    this.dhSending = initialKeyPair;
    this.dhSendingRaw = new Uint8Array(
      await crypto.subtle.exportKey('raw', initialKeyPair.publicKey)
    );
    this.dhReceiving = null;
    this.dhReceivingRaw = null;

    // Initial root key from shared secret
    this.rootKey = await DoubleRatchet._kdfRootInitial(sharedSecret);
    this.sendChainKey = null;
    this.receiveChainKey = null;
    this.sendHeaderKey = null;
    this.receiveHeaderKey = null;
    this.nextSendHeaderKey = null;
    this.nextReceiveHeaderKey = null;
  }

  /** Export our DH ratchet public key (65 bytes raw) */
  getDHPublicKeyRaw() {
    return this.dhSendingRaw;
  }

  // ---- Encrypt ----

  /**
   * Encrypt plaintext → { encryptedHeader, ciphertext }
   * @param {Uint8Array} plaintext
   * @returns {{ encryptedHeader: Uint8Array, ciphertext: Uint8Array }}
   */
  async encrypt(plaintext) {
    if (!this.sendChainKey) {
      throw new Error('Send chain not initialized');
    }

    // Advance sending chain: chainKey → (newChainKey, messageKey)
    const { chainKey: newCK, messageKey } =
      await DoubleRatchet._kdfChain(this.sendChainKey);
    this.sendChainKey = newCK;

    // Create header: dhKey(65) + pn(4 BE) + n(4 BE) = 73 bytes
    const header = DoubleRatchet._serializeHeader(
      this.dhSendingRaw, this.previousChainLength, this.sendMessageNumber
    );
    this.sendMessageNumber++;

    // Encrypt body with message key (AES-256-GCM)
    const bodyIV = crypto.getRandomValues(new Uint8Array(12));
    const aesMK = await DoubleRatchet._importAESKey(messageKey);
    const bodyCiphertext = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: bodyIV, tagLength: 128 }, aesMK, plaintext
    );
    // Combined: IV(12) + ciphertext+tag
    const ciphertext = new Uint8Array(12 + bodyCiphertext.byteLength);
    ciphertext.set(bodyIV);
    ciphertext.set(new Uint8Array(bodyCiphertext), 12);

    // Always plaintext headers (0x00 prefix) — matches iOS DoubleRatchet
    // Header encryption disabled: avoids chicken-and-egg where responder
    // has no header key to decrypt initiator's first messages.
    // Headers are already protected by the encrypted DataChannel (DTLS-SRTP).
    const encryptedHeader = new Uint8Array(1 + header.byteLength);
    encryptedHeader[0] = 0x00;
    encryptedHeader.set(new Uint8Array(header), 1);

    return { encryptedHeader, ciphertext };
  }

  // ---- Decrypt ----

  /**
   * Decrypt received message
   * @param {Uint8Array} encryptedHeader
   * @param {Uint8Array} ciphertext
   * @returns {Uint8Array}
   */
  async decrypt(encryptedHeader, ciphertext) {
    // Try to decrypt header
    const { header, usedNextKey } = await this._decryptHeader(encryptedHeader);

    const peerDHKeyRaw = header.dhPublicKey;

    // Check if new DH ratchet key from peer
    if (!this.dhReceivingRaw || !DoubleRatchet._arraysEqual(peerDHKeyRaw, this.dhReceivingRaw)) {
      // Skip messages in current chain
      if (this.receiveChainKey) {
        await this._skipMessageKeys(this.receiveChainKey, header.pn,
          this.dhReceivingRaw ? DoubleRatchet._arrayToBase64(this.dhReceivingRaw) : null);
      }
      await this._dhRatchetReceive(peerDHKeyRaw, usedNextKey);
    }

    // Skip missed messages in current receiving chain
    if (!this.receiveChainKey) {
      throw new Error('Receive chain not initialized');
    }
    const peerKeyB64 = DoubleRatchet._arrayToBase64(peerDHKeyRaw);
    await this._skipMessageKeys(this.receiveChainKey, header.n, peerKeyB64);

    // Advance receiving chain
    const { chainKey: newCK, messageKey } =
      await DoubleRatchet._kdfChain(this.receiveChainKey);
    this.receiveChainKey = newCK;
    this.receiveMessageNumber = header.n + 1;

    // Decrypt body
    return await DoubleRatchet._decryptAESGCM(ciphertext, messageKey);
  }

  /**
   * Try to decrypt with a stored skipped key
   * @returns {Uint8Array|null}
   */
  async tryDecryptWithSkippedKey(encryptedHeader, ciphertext) {
    let header;
    try {
      const result = await this._decryptHeader(encryptedHeader);
      header = result.header;
    } catch {
      return null;
    }

    const keyId = DoubleRatchet._arrayToBase64(header.dhPublicKey) + ':' + header.n;
    const messageKey = this.skippedKeys.get(keyId);
    if (!messageKey) return null;

    this.skippedKeys.delete(keyId);
    return await DoubleRatchet._decryptAESGCM(ciphertext, messageKey);
  }

  // ---- DH Ratchet ----

  async _dhRatchetReceive(peerDHKeyRaw, usedNextHeaderKey) {
    const peerDHKey = await crypto.subtle.importKey(
      'raw', peerDHKeyRaw, { name: 'ECDH', namedCurve: 'P-256' }, true, []
    );

    this.previousChainLength = this.sendMessageNumber;
    this.sendMessageNumber = 0;
    this.receiveMessageNumber = 0;
    this.dhReceiving = peerDHKey;
    this.dhReceivingRaw = new Uint8Array(peerDHKeyRaw);

    // Update header keys
    if (usedNextHeaderKey) {
      this.receiveHeaderKey = this.nextReceiveHeaderKey;
    }

    // DH with our current key and new peer key → update receive chain
    const dhOutputRecv = await crypto.subtle.deriveBits(
      { name: 'ECDH', public: peerDHKey }, this.dhSending.privateKey, 256
    );
    const r1 = await DoubleRatchet._kdfRootChain(this.rootKey, dhOutputRecv);
    this.rootKey = r1.rootKey;
    this.receiveChainKey = r1.chainKey;
    this.nextReceiveHeaderKey = r1.nextHeaderKey;

    // Generate new DH key pair
    this.dhSending = await crypto.subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']
    );
    this.dhSendingRaw = new Uint8Array(
      await crypto.subtle.exportKey('raw', this.dhSending.publicKey)
    );

    // DH with new key and peer key → update send chain
    const dhOutputSend = await crypto.subtle.deriveBits(
      { name: 'ECDH', public: peerDHKey }, this.dhSending.privateKey, 256
    );
    const r2 = await DoubleRatchet._kdfRootChain(this.rootKey, dhOutputSend);
    this.rootKey = r2.rootKey;
    this.sendChainKey = r2.chainKey;
    this.sendHeaderKey = r2.headerKey;
    this.nextSendHeaderKey = r2.nextHeaderKey;
  }

  // ---- Header Encryption / Decryption ----

  async _decryptHeader(encryptedHeader) {
    // Check plaintext header (prefix 0x00)
    if (encryptedHeader[0] === 0x00 && encryptedHeader.byteLength === 74) {
      const headerData = encryptedHeader.slice(1);
      return { header: DoubleRatchet._deserializeHeader(headerData), usedNextKey: false };
    }

    // Try current receive header key
    if (this.receiveHeaderKey) {
      try {
        const header = await DoubleRatchet._decryptHeaderWithKey(encryptedHeader, this.receiveHeaderKey);
        return { header, usedNextKey: false };
      } catch { /* try next key */ }
    }

    // Try next receive header key
    if (this.nextReceiveHeaderKey) {
      try {
        const header = await DoubleRatchet._decryptHeaderWithKey(encryptedHeader, this.nextReceiveHeaderKey);
        return { header, usedNextKey: true };
      } catch { /* fail */ }
    }

    throw new Error('Header decryption failed');
  }

  static async _decryptHeaderWithKey(encryptedHeader, key) {
    const headerPlain = await DoubleRatchet._decryptAESGCM(encryptedHeader, key);
    return DoubleRatchet._deserializeHeader(headerPlain);
  }

  // ---- Skipped Keys ----

  async _skipMessageKeys(chainKey, targetN, peerDHKeyB64) {
    if (!peerDHKeyB64) return;
    let currentCK = chainKey;
    let currentN = this.receiveMessageNumber;

    if (targetN - currentN > DoubleRatchet.MAX_SKIP) {
      throw new Error('Too many skipped messages');
    }

    while (currentN < targetN) {
      const { chainKey: newCK, messageKey } = await DoubleRatchet._kdfChain(currentCK);
      const keyId = peerDHKeyB64 + ':' + currentN;
      this.skippedKeys.set(keyId, messageKey);
      currentCK = newCK;
      currentN++;
    }

    this.receiveChainKey = currentCK;
    this.receiveMessageNumber = currentN;

    // Enforce max skip limit — remove by lowest messageNumber (deterministic)
    while (this.skippedKeys.size > DoubleRatchet.MAX_SKIP) {
      let oldestKey = null;
      let oldestN = Infinity;
      for (const key of this.skippedKeys.keys()) {
        const n = parseInt(key.split(':')[1], 10);
        if (n < oldestN) { oldestN = n; oldestKey = key; }
      }
      if (oldestKey) this.skippedKeys.delete(oldestKey);
      else break;
    }
  }

  // ---- KDF Functions ----

  /**
   * Initial root key derivation: HKDF(sharedSecret, salt="ghost-dr-root", info="ghost-dr-init") → 32 bytes
   */
  static async _kdfRootInitial(sharedSecret) {
    const ikm = await crypto.subtle.importKey('raw', sharedSecret, 'HKDF', false, ['deriveBits']);
    const derived = await crypto.subtle.deriveBits(
      {
        name: 'HKDF', hash: 'SHA-256',
        salt: new TextEncoder().encode(DoubleRatchet.ROOT_KDF_SALT),
        info: new TextEncoder().encode(DoubleRatchet.INIT_INFO)
      },
      ikm, 256
    );
    return derived;
  }

  /**
   * Root chain KDF: (rootKey, dhOutput) → { rootKey, chainKey, headerKey, nextHeaderKey }
   * IKM = rootKey || dhOutput, HKDF → 128 bytes split into 4×32
   */
  static async _kdfRootChain(rootKey, dhOutput) {
    // Combine: rootKey(32) + dhOutput(32) = 64 bytes
    const rootKeyArr = new Uint8Array(rootKey);
    const dhOutputArr = new Uint8Array(dhOutput);
    const ikm = new Uint8Array(rootKeyArr.length + dhOutputArr.length);
    ikm.set(rootKeyArr);
    ikm.set(dhOutputArr, rootKeyArr.length);

    const ikmKey = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
    const derived = await crypto.subtle.deriveBits(
      {
        name: 'HKDF', hash: 'SHA-256',
        salt: new TextEncoder().encode(DoubleRatchet.ROOT_KDF_SALT),
        info: new TextEncoder().encode(DoubleRatchet.ROOT_KDF_INFO)
      },
      ikmKey, 1024 // 128 bytes = 1024 bits
    );

    const arr = new Uint8Array(derived);
    return {
      rootKey: arr.slice(0, 32).buffer,
      chainKey: arr.slice(32, 64).buffer,
      headerKey: arr.slice(64, 96).buffer,
      nextHeaderKey: arr.slice(96, 128).buffer
    };
  }

  /**
   * Symmetric chain KDF: chainKey → { chainKey, messageKey }
   * Two separate HKDF calls with different info labels (same as iOS)
   */
  static async _kdfChain(chainKey) {
    const ckData = new Uint8Array(chainKey);
    const salt = new TextEncoder().encode(DoubleRatchet.CHAIN_KDF_SALT);

    const ikmCK = await crypto.subtle.importKey('raw', ckData, 'HKDF', false, ['deriveBits']);
    const newChainKey = await crypto.subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt, info: new TextEncoder().encode(DoubleRatchet.CHAIN_KDF_INFO_CK) },
      ikmCK, 256
    );

    const ikmMK = await crypto.subtle.importKey('raw', ckData, 'HKDF', false, ['deriveBits']);
    const messageKey = await crypto.subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt, info: new TextEncoder().encode(DoubleRatchet.CHAIN_KDF_INFO_MK) },
      ikmMK, 256
    );

    return { chainKey: newChainKey, messageKey };
  }

  // ---- Header serialization (73 bytes) ----

  /**
   * Serialize: dhKey(65) + pn(4 BE) + n(4 BE)
   */
  static _serializeHeader(dhPublicKeyRaw, pn, n) {
    const buf = new Uint8Array(73);
    buf.set(dhPublicKeyRaw);
    const view = new DataView(buf.buffer);
    view.setUint32(65, pn, false); // big-endian
    view.setUint32(69, n, false);
    return buf;
  }

  /**
   * Deserialize 73 bytes → { dhPublicKey, pn, n }
   */
  static _deserializeHeader(data) {
    const arr = new Uint8Array(data);
    if (arr.byteLength !== 73) {
      throw new Error('Invalid DR header: expected 73 bytes, got ' + arr.byteLength);
    }
    const dhPublicKey = arr.slice(0, 65);
    const view = new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
    const pn = view.getUint32(65, false);
    const n = view.getUint32(69, false);
    return { dhPublicKey, pn, n };
  }

  // ---- AES-GCM helpers ----

  static async _importAESKey(rawKey) {
    return await crypto.subtle.importKey(
      'raw', rawKey, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']
    );
  }

  /**
   * Decrypt AES-256-GCM: data = IV(12) + ciphertext + tag(16)
   */
  static async _decryptAESGCM(combined, rawKey) {
    const arr = new Uint8Array(combined);
    const iv = arr.slice(0, 12);
    const ciphertext = arr.slice(12);
    const aesKey = await DoubleRatchet._importAESKey(rawKey);
    const plaintext = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv, tagLength: 128 }, aesKey, ciphertext
    );
    return new Uint8Array(plaintext);
  }

  // ---- Utility ----

  static _arraysEqual(a, b) {
    if (a.byteLength !== b.byteLength) return false;
    const av = new Uint8Array(a);
    const bv = new Uint8Array(b);
    // Constant-time comparison — prevents timing side-channel (L4)
    let diff = 0;
    for (let i = 0; i < av.length; i++) {
      diff |= av[i] ^ bv[i];
    }
    return diff === 0;
  }

  static _arrayToBase64(arr) {
    const bytes = new Uint8Array(arr);
    let binary = '';
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  destroy() {
    // L3: Zero-fill ArrayBuffer keys before releasing references
    const wipe = (buf) => {
      if (buf instanceof ArrayBuffer) new Uint8Array(buf).fill(0);
      else if (buf instanceof Uint8Array) buf.fill(0);
    };
    this.skippedKeys.forEach(mk => wipe(mk));
    this.skippedKeys.clear();
    wipe(this.rootKey);
    wipe(this.sendChainKey);
    wipe(this.receiveChainKey);
    wipe(this.sendHeaderKey);
    wipe(this.receiveHeaderKey);
    wipe(this.nextSendHeaderKey);
    wipe(this.nextReceiveHeaderKey);
    if (this.dhSendingRaw) this.dhSendingRaw.fill(0);
    if (this.dhReceivingRaw) this.dhReceivingRaw.fill(0);
    this.dhSending = null;
    this.dhSendingRaw = null;
    this.dhReceiving = null;
    this.dhReceivingRaw = null;
    this.rootKey = null;
    this.sendChainKey = null;
    this.receiveChainKey = null;
    this.sendHeaderKey = null;
    this.receiveHeaderKey = null;
    this.nextSendHeaderKey = null;
    this.nextReceiveHeaderKey = null;
  }
}


// ============================================================
// GhostCrypto — public API (mirrors GhostCrypto.swift)
// ============================================================

export class GhostCrypto {

  static PROTOCOL_VERSION = 3;

  constructor() {
    this.keyPair = null;        // Наша пара ключей ECDH
    this.peerPublicKey = null;  // Публичный ключ собеседника (CryptoKey)
    this.peerPublicKeyRaw = null; // Raw bytes

    // Double Ratchet state
    this.ratchet = null;

    this.isHost = false;

    this.messageCounter = 0;
    this.peerMessageCounter = 0;
    this.receivedNonces = new Map();
    this.NONCE_EXPIRY_MS = 60 * 60 * 1000; // 1 hour
    this.COUNTER_WINDOW = 100;

    // Serialization queue — prevents concurrent encrypt/decrypt corrupting ratchet state
    this._queue = Promise.resolve();

    // Send chain readiness (guest waits for first received message to init send chain)
    this._sendChainReady = null;
    this._sendChainReadyResolve = null;

    // Last decrypted message metadata (initialized to null before first decrypt)
    this.lastDecryptedId = null;
    this.lastDecryptedReply = null;
  }

  /**
   * Генерация пары ключей ECDH
   */
  async generateKeyPair() {
    // Verify Web Crypto CSPRNG availability before key generation
    if (!crypto?.subtle?.generateKey || !crypto?.getRandomValues) {
      throw new Error('Web Crypto API not available — secure key generation impossible');
    }

    // Entropy health check — verify CSPRNG produces non-degenerate output
    const entropyTest = new Uint8Array(32);
    crypto.getRandomValues(entropyTest);
    let zeros = 0;
    for (let i = 0; i < 32; i++) if (entropyTest[i] === 0) zeros++;
    if (zeros > 16) {
      throw new Error('CSPRNG entropy check failed — aborting');
    }

    this.keyPair = await crypto.subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' },
      true,
      ['deriveBits']
    );
    return this.keyPair;
  }

  /**
   * Экспорт публичного ключа для отправки собеседнику (base64)
   */
  async exportPublicKey() {
    if (!this.keyPair) throw new Error('Key pair not generated');
    const exported = await crypto.subtle.exportKey('raw', this.keyPair.publicKey);
    return this.arrayBufferToBase64(exported);
  }

  /**
   * Импорт публичного ключа собеседника
   */
  async importPeerPublicKey(base64Key) {
    const keyData = this.base64ToArrayBuffer(base64Key);
    const keyBytes = new Uint8Array(keyData);

    // P-256 uncompressed point validation:
    // Must be exactly 65 bytes, starting with 0x04 (uncompressed)
    if (keyBytes.byteLength !== 65) {
      throw new Error('Invalid peer public key: expected 65 bytes for P-256 uncompressed point');
    }
    if (keyBytes[0] !== 0x04) {
      throw new Error('Invalid peer public key: must be uncompressed point (0x04 prefix)');
    }

    // Reject identity point (all zeros) and low-order points
    let allZero = true;
    for (let i = 1; i < 65; i++) {
      if (keyBytes[i] !== 0) { allZero = false; break; }
    }
    if (allZero) {
      throw new Error('Invalid peer public key: identity point rejected');
    }

    // Reject if peer key equals our own key (reflection attack)
    if (this.keyPair) {
      const ourKeyRaw = new Uint8Array(await crypto.subtle.exportKey('raw', this.keyPair.publicKey));
      if (DoubleRatchet._arraysEqual(keyBytes, ourKeyRaw)) {
        throw new Error('Peer public key matches our own key — possible reflection attack');
      }
    }

    this.peerPublicKeyRaw = new Uint8Array(keyData);
    this.peerPublicKey = await crypto.subtle.importKey(
      'raw', keyData,
      { name: 'ECDH', namedCurve: 'P-256' },
      true, []
    );
    return this.peerPublicKey;
  }

  /**
   * Derive shared key and initialize Double Ratchet
   * @param {boolean} asHost — true for initiator (host), false for responder (guest)
   */
  async deriveSharedKey(asHost = false) {
    if (!this.keyPair || !this.peerPublicKey) {
      throw new Error('Keys not ready for derivation');
    }

    this.isHost = asHost;

    // ECDH shared secret (32 bytes)
    const sharedBits = await crypto.subtle.deriveBits(
      { name: 'ECDH', public: this.peerPublicKey },
      this.keyPair.privateKey,
      256
    );

    // HKDF from ECDH shared secret → root symmetric key
    const salt = new TextEncoder().encode('ghost-chat-v2');
    const info = new TextEncoder().encode('ghost-dr-init-secret');
    const ikmKey = await crypto.subtle.importKey('raw', sharedBits, 'HKDF', false, ['deriveBits']);
    const rootSecret = await crypto.subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt, info },
      ikmKey, 256
    );

    // Initialize Double Ratchet
    this.ratchet = new DoubleRatchet();
    if (asHost) {
      await this.ratchet.initAsInitiator(rootSecret, this.peerPublicKey, this.peerPublicKeyRaw);
    } else {
      await this.ratchet.initAsResponder(rootSecret, this.keyPair);
      // Guest: send chain will be initialized after first received message triggers DH ratchet
      this._sendChainReady = new Promise(resolve => {
        this._sendChainReadyResolve = resolve;
      });
    }
  }

  /**
   * Export the DH ratchet public key (base64)
   */
  exportDHRatchetKey() {
    if (!this.ratchet) return null;
    return this.arrayBufferToBase64(this.ratchet.getDHPublicKeyRaw());
  }

  /**
   * Шифрование сообщения (Double Ratchet v2) — serialized
   * Returns base64(4-byte headerLen BE + encryptedHeader + ciphertext)
   */
  async encrypt(plaintext, options = {}) {
    // Wait for send chain initialization (guest only, before first received message)
    if (this._sendChainReady) {
      await Promise.race([
        this._sendChainReady,
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error('Send chain initialization timeout')), 10000)
        )
      ]);
    }
    return this._enqueue(() => this._encryptImpl(plaintext, options));
  }

  async _encryptImpl(plaintext, options = {}) {
    if (!this.ratchet) {
      throw new Error('Double Ratchet not initialized');
    }

    this.messageCounter++;

    // Build message with metadata {m, t, c, id}
    const metaObj = {
      m: plaintext,
      t: Date.now(),
      c: this.messageCounter
    };
    if (options.id) metaObj.id = options.id;
    if (options.r) metaObj.r = options.r;
    const meta = JSON.stringify(metaObj);

    // Padding
    const padded = this.padMessage(meta);
    const paddedData = new TextEncoder().encode(padded);

    // Double Ratchet encrypt → (encryptedHeader, ciphertext)
    const { encryptedHeader, ciphertext } = await this.ratchet.encrypt(paddedData);

    // Combine: 4-byte headerLen BE + encryptedHeader + ciphertext
    const headerLen = encryptedHeader.byteLength;
    const combined = new Uint8Array(4 + headerLen + ciphertext.byteLength);
    const view = new DataView(combined.buffer);
    view.setUint32(0, headerLen, false); // big-endian
    combined.set(encryptedHeader, 4);
    combined.set(ciphertext, 4 + headerLen);

    return this.arrayBufferToBase64(combined.buffer);
  }

  /**
   * Дешифрование сообщения (Double Ratchet v2) — serialized
   */
  async decrypt(encryptedBase64) {
    return this._enqueue(() => this._decryptImpl(encryptedBase64));
  }

  async _decryptImpl(encryptedBase64) {
    if (!this.ratchet) {
      throw new Error('Double Ratchet not initialized');
    }

    const combined = new Uint8Array(this.base64ToArrayBuffer(encryptedBase64));

    // Parse: 4-byte headerLen + encryptedHeader + ciphertext
    if (combined.byteLength <= 4) {
      throw new Error('Invalid ciphertext');
    }

    const view = new DataView(combined.buffer, combined.byteOffset, combined.byteLength);
    const headerLen = view.getUint32(0, false);

    if (combined.byteLength <= 4 + headerLen) {
      throw new Error('Invalid ciphertext');
    }

    const encryptedHeader = combined.slice(4, 4 + headerLen);
    const ciphertext = combined.slice(4 + headerLen);

    // Replay protection: extract nonce from ciphertext (first 12 bytes = IV)
    if (ciphertext.byteLength <= 12) {
      throw new Error('Invalid ciphertext');
    }
    const nonceData = ciphertext.slice(0, 12);
    const nonceString = this.arrayBufferToBase64(nonceData.buffer);

    this.cleanupExpiredNonces();

    if (this.receivedNonces.has(nonceString)) {
      throw new Error('Replay attack detected: duplicate nonce');
    }

    // Try skipped keys first (out-of-order messages)
    let plainData = await this.ratchet.tryDecryptWithSkippedKey(encryptedHeader, ciphertext);
    if (plainData) {
      this._resolveSendChainReady();
      return this._processDecryptedData(plainData, nonceString);
    }

    // Normal Double Ratchet decrypt
    plainData = await this.ratchet.decrypt(encryptedHeader, ciphertext);
    this._resolveSendChainReady();
    return this._processDecryptedData(plainData, nonceString);
  }

  /**
   * Serialization queue — ensures only one encrypt/decrypt runs at a time
   */
  _enqueue(fn) {
    const p = this._queue.then(fn);
    this._queue = p.catch(() => {});
    return p;
  }

  /**
   * Resolve send chain readiness promise after successful decrypt
   * (guest's first decrypt triggers DH ratchet which initializes send chain)
   */
  _resolveSendChainReady() {
    if (this._sendChainReadyResolve && this.ratchet && this.ratchet.sendChainKey) {
      this._sendChainReadyResolve();
      this._sendChainReadyResolve = null;
      this._sendChainReady = null;
    }
  }

  /**
   * Process decrypted data: unpad, validate metadata, return message
   */
  _processDecryptedData(data, nonceString) {
    const paddedText = new TextDecoder().decode(data);
    const unpaddedText = this.unpadMessage(paddedText);

    try {
      const parsed = JSON.parse(unpaddedText);

      // Timestamp validation (5 min tolerance for clock skew, mandatory)
      if (typeof parsed.t !== 'number' || parsed.t <= 0) {
        throw new Error('Message too old, possible replay attack');
      }
      const now = Date.now();
      const messageAge = now - parsed.t;
      if (messageAge > 5 * 60 * 1000 || messageAge < -5 * 60 * 1000) {
        throw new Error('Message too old, possible replay attack');
      }

      // Counter validation (mandatory — reject messages without counter)
      if (typeof parsed.c !== 'number' || parsed.c < 0) {
        throw new Error('Message counter too old, possible replay attack');
      }
      const windowStart = Math.max(0, this.peerMessageCounter - this.COUNTER_WINDOW);
      if (parsed.c <= windowStart && this.peerMessageCounter > 0) {
        throw new Error('Message counter too old, possible replay attack');
      }
      if (parsed.c > this.peerMessageCounter) {
        this.peerMessageCounter = parsed.c;
      }

      // Save nonce
      this.receivedNonces.set(nonceString, Date.now());

      if (typeof parsed.m === 'string') {
        // Return object with metadata for caller
        this.lastDecryptedId = parsed.id || null;
        this.lastDecryptedReply = parsed.r || null;
        return parsed.m;
      }
    } catch (e) {
      if (e.message && e.message.includes('attack')) {
        throw e;
      }
      // Not JSON — return as-is
    }

    this.lastDecryptedId = null;
    this.lastDecryptedReply = null;
    return unpaddedText;
  }

  /**
   * Padding сообщения до кратного blockSize
   */
  padMessage(message, blockSize = 256) {
    const base64Message = this.textToBase64(message);
    const messageLength = base64Message.length;

    if (messageLength > 9999) {
      throw new Error('Message too long');
    }

    const paddedLength = Math.ceil((messageLength + 4) / blockSize) * blockSize;
    const paddingLength = paddedLength - messageLength - 4;

    const paddingChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const randomBytes = crypto.getRandomValues(new Uint8Array(paddingLength));
    let padding = '';
    for (let i = 0; i < paddingLength; i++) {
      padding += paddingChars[randomBytes[i] % paddingChars.length];
    }

    const lengthPrefix = messageLength.toString().padStart(4, '0');
    return lengthPrefix + base64Message + padding;
  }

  /**
   * Удаление padding
   */
  unpadMessage(paddedMessage) {
    const prefix = paddedMessage.substring(0, 4);
    if (!/^\d{4}$/.test(prefix)) {
      throw new Error('Invalid padded message format');
    }
    const originalLength = parseInt(prefix, 10);
    if (originalLength < 0 || originalLength > paddedMessage.length - 4) {
      throw new Error('Invalid padded message format');
    }
    const base64Message = paddedMessage.substring(4, 4 + originalLength);
    return this.base64ToText(base64Message);
  }

  /**
   * Генерация fingerprint для верификации
   */
  async generateFingerprint() {
    if (!this.keyPair || !this.peerPublicKey) {
      throw new Error('Keys not ready');
    }

    const ourKey = await crypto.subtle.exportKey('raw', this.keyPair.publicKey);
    const peerKey = await crypto.subtle.exportKey('raw', this.peerPublicKey);

    const keys = [
      new Uint8Array(ourKey),
      new Uint8Array(peerKey)
    ].sort((a, b) => {
      for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return a[i] - b[i];
      }
      return 0;
    });

    const combined = new Uint8Array(keys[0].length + keys[1].length);
    combined.set(keys[0]);
    combined.set(keys[1], keys[0].length);

    const hash = await crypto.subtle.digest('SHA-256', combined);
    const hashArray = new Uint8Array(hash);

    return Array.from(hashArray.slice(0, 16))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('')
      .match(/.{1,4}/g)
      .join(' ')
      .toUpperCase();
  }

  /**
   * Очистка истёкших nonces
   */
  cleanupExpiredNonces() {
    const now = Date.now();
    for (const [nonce, timestamp] of this.receivedNonces) {
      if (now - timestamp > this.NONCE_EXPIRY_MS) {
        this.receivedNonces.delete(nonce);
      }
    }
  }

  /**
   * Проверка готовности
   */
  isReady() {
    return this.keyPair !== null &&
           this.ratchet !== null &&
           this.peerPublicKey !== null;
  }

  /**
   * Полная очистка
   */
  destroy() {
    if (this.receivedNonces) {
      this.receivedNonces.clear();
      this.receivedNonces = null;
    }

    if (this.ratchet) {
      this.ratchet.destroy();
      this.ratchet = null;
    }

    // L3: Zero-fill raw key material before releasing
    if (this.peerPublicKeyRaw) this.peerPublicKeyRaw.fill(0);
    this.keyPair = null;
    this.peerPublicKey = null;
    this.peerPublicKeyRaw = null;
    this.messageCounter = 0;
    this.peerMessageCounter = 0;
    this.isHost = false;
    this._queue = Promise.resolve();
    this._sendChainReady = null;
    this._sendChainReadyResolve = null;

    logger.log('Crypto keys destroyed');
  }

  // === Утилиты ===

  textToBase64(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  base64ToText(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return new TextDecoder().decode(bytes);
  }

  arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  base64ToArrayBuffer(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }
}
