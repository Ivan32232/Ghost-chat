#!/usr/bin/env node
// Generate deterministic test vectors for Ghost Chat crypto layer.
// Both iOS (CryptoKit) and Android (BouncyCastle) must produce identical results.

const crypto = require('crypto');

// --- Helpers ---

function hex(buf) { return Buffer.from(buf).toString('hex'); }
function b64(buf) { return Buffer.from(buf).toString('base64'); }
function fromHex(h) { return Buffer.from(h, 'hex'); }

function hmacSha256(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest();
}

function hkdfSha256(ikm, salt, info, length) {
  return Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, length));
}

// P-256 ECDH: create keypair from raw 32-byte private scalar
function makeP256(privateKeyHex) {
  const ecdh = crypto.createECDH('prime256v1');
  ecdh.setPrivateKey(fromHex(privateKeyHex));
  return {
    privateKey: privateKeyHex,
    publicKey: hex(ecdh.getPublicKey()),       // 65 bytes uncompressed (04 + x + y)
    publicKeyRaw: hex(ecdh.getPublicKey().slice(1)), // 64 bytes (x + y, no 04 prefix)
    ecdh
  };
}

function ecdhSharedSecret(myEcdh, peerPublicKeyHex) {
  return myEcdh.computeSecret(fromHex(peerPublicKeyHex));
}

// AES-256-GCM encrypt
function aesGcmEncrypt(key, nonce, plaintext, aad) {
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  if (aad && aad.length > 0) cipher.setAAD(aad);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag(); // 16 bytes
  return { ciphertext: ct, tag };
}

// AES-256-GCM decrypt
function aesGcmDecrypt(key, nonce, ciphertext, tag, aad) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
  if (aad && aad.length > 0) decipher.setAAD(aad);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

// Root KDF: HKDF(ikm=dhOutput, salt=rootKey, info="ghost-dr-rk", len=64)
function rootKDF(rootKey, dhOutput) {
  const out = hkdfSha256(dhOutput, rootKey, 'ghost-dr-rk', 64);
  return {
    newRootKey: out.slice(0, 32),
    chainKey: out.slice(32, 64)
  };
}

// Chain KDF: HMAC-SHA256
function chainKDF(chainKey) {
  const messageKey = hmacSha256(chainKey, Buffer.from([0x01]));
  const nextChainKey = hmacSha256(chainKey, Buffer.from([0x02]));
  return { messageKey, nextChainKey };
}

// Message padding (deterministic: pad with 0x00 for test vectors)
function padMessage(jsonString) {
  const b64Msg = Buffer.from(jsonString, 'utf-8').toString('base64');
  const lenPrefix = b64Msg.length.toString().padStart(4, '0');
  const content = Buffer.from(lenPrefix + b64Msg, 'utf-8');
  const padTo = Math.ceil(content.length / 256) * 256;
  const padLen = padTo === 0 ? 256 : padTo - content.length;
  // Deterministic padding: all zeros for test vectors
  const padding = Buffer.alloc(padLen, 0x00);
  return Buffer.concat([content, padding]);
}

// Unpad
function unpadMessage(padded) {
  const lenStr = padded.slice(0, 4).toString('utf-8');
  const b64Len = parseInt(lenStr, 10);
  const b64Str = padded.slice(4, 4 + b64Len).toString('utf-8');
  return Buffer.from(b64Str, 'base64').toString('utf-8');
}

// Wire format header: version(1) + dhPubKeyRaw(64) + PN(4, big-endian) + N(4, big-endian) = 73 bytes
function buildHeader(dhPublicKeyRaw, pn, n) {
  const buf = Buffer.alloc(73);
  buf[0] = 0x00; // version
  fromHex(dhPublicKeyRaw).copy(buf, 1);    // 64 bytes
  buf.writeUInt32BE(pn, 65);               // PN
  buf.writeUInt32BE(n, 69);                // N
  return buf;
}

// Wire format: headerLen(4) + header(73) + nonce(12) + ciphertext + tag(16)
function buildWireMessage(header, nonce, ciphertext, tag) {
  const headerLen = Buffer.alloc(4);
  headerLen.writeUInt32BE(header.length, 0);
  return Buffer.concat([headerLen, header, nonce, ciphertext, tag]);
}

// Safety number: SHA-256(sorted(keyA + keyB)) → first 16 bytes → hex groups of 4 → uppercase
function safetyNumber(identityKeyA_hex, identityKeyB_hex) {
  const a = fromHex(identityKeyA_hex);
  const b = fromHex(identityKeyB_hex);
  // Sort by raw bytes
  const cmp = Buffer.compare(a, b);
  const sorted = cmp <= 0 ? Buffer.concat([a, b]) : Buffer.concat([b, a]);
  const hash = crypto.createHash('sha256').update(sorted).digest();
  const first16 = hash.slice(0, 16);
  const hexStr = hex(first16).toUpperCase();
  // Groups of 4
  const groups = [];
  for (let i = 0; i < hexStr.length; i += 4) {
    groups.push(hexStr.slice(i, i + 4));
  }
  return groups.join(' ');
}


// ============================
// GENERATE ALL TEST VECTORS
// ============================

const vectors = {};

// --- 1. ECDH Key Exchange ---
// Private keys: SHA-256 of known strings (valid P-256 scalars)
const alicePrivHex = crypto.createHash('sha256').update('alice-ghost-chat-test-vector-key').digest('hex');
const bobPrivHex = crypto.createHash('sha256').update('bob-ghost-chat-test-vector-key').digest('hex');

const alice = makeP256(alicePrivHex);
const bob = makeP256(bobPrivHex);

const sharedSecret = ecdhSharedSecret(alice.ecdh, bob.publicKey);
// Verify symmetric
const sharedSecret2 = ecdhSharedSecret(bob.ecdh, alice.publicKey);
if (!sharedSecret.equals(sharedSecret2)) throw new Error('ECDH not symmetric!');

vectors.ecdh = {
  alice: {
    privateKey: alice.privateKey,
    publicKey: alice.publicKey,           // 65 bytes with 04 prefix
    publicKeyRaw: alice.publicKeyRaw      // 64 bytes without prefix
  },
  bob: {
    privateKey: bob.privateKey,
    publicKey: bob.publicKey,
    publicKeyRaw: bob.publicKeyRaw
  },
  sharedSecret: hex(sharedSecret)
};

// --- 2. Initial Root Key Derivation ---
const initialRootKey = hkdfSha256(sharedSecret, 'ghost-dr-root', 'ghost-dr-rk', 32);

vectors.initialRootKey = {
  ikm: hex(sharedSecret),
  salt: 'ghost-dr-root',
  info: 'ghost-dr-rk',
  length: 32,
  rootKey: hex(initialRootKey)
};

// --- 3. Root KDF (ratchet step) ---
// Simulate: HOST generates new ratchet keypair, does DH with GUEST's key
const hostRatchet1PrivHex = crypto.createHash('sha256').update('host-ratchet-1-test-vector').digest('hex');
const hostRatchet1 = makeP256(hostRatchet1PrivHex);
// DH(hostRatchet1, bob's ephemeral key)
const dhOutput1 = ecdhSharedSecret(hostRatchet1.ecdh, bob.publicKey);
const { newRootKey: rk1, chainKey: ck1 } = rootKDF(initialRootKey, dhOutput1);

vectors.rootKDF = {
  rootKey: hex(initialRootKey),
  dhOutput: hex(dhOutput1),
  newRootKey: hex(rk1),
  chainKey: hex(ck1),
  hostRatchetPublicKey: hostRatchet1.publicKey,
  hostRatchetPublicKeyRaw: hostRatchet1.publicKeyRaw,
  hostRatchetPrivateKey: hostRatchet1.privateKey
};

// --- 4. Chain KDF ---
const { messageKey: mk1, nextChainKey: ck1_next } = chainKDF(ck1);
const { messageKey: mk2, nextChainKey: ck1_next2 } = chainKDF(ck1_next);

vectors.chainKDF = {
  chainKey: hex(ck1),
  messageKey0: hex(mk1),
  nextChainKey0: hex(ck1_next),
  messageKey1: hex(mk2),
  nextChainKey1: hex(ck1_next2)
};

// --- 5. AES-256-GCM ---
const testNonce = fromHex('000102030405060708090a0b'); // 12 bytes, fixed for test
const testPlaintext = Buffer.from('Hello, Ghost Chat!', 'utf-8');
const testHeader = buildHeader(hostRatchet1.publicKeyRaw, 0, 0);
const { ciphertext: ct1, tag: tag1 } = aesGcmEncrypt(mk1, testNonce, testPlaintext, testHeader);

// Verify decrypt
const decrypted = aesGcmDecrypt(mk1, testNonce, ct1, tag1, testHeader);
if (!decrypted.equals(testPlaintext)) throw new Error('AES-GCM roundtrip failed!');

vectors.aesGcm = {
  key: hex(mk1),
  nonce: hex(testNonce),
  plaintext: hex(testPlaintext),
  plaintextUtf8: 'Hello, Ghost Chat!',
  aad: hex(testHeader),
  ciphertext: hex(ct1),
  tag: hex(tag1)
};

// --- 6. Message Padding ---
const msgJson = '{"m":"Hello, Ghost!","t":1713100800000,"c":0,"id":"550e8400-e29b-41d4-a716-446655440000"}';
const padded = padMessage(msgJson);
const unpadded = unpadMessage(padded);
if (unpadded !== msgJson) throw new Error('Padding roundtrip failed!');

vectors.messagePadding = {
  input: msgJson,
  inputBase64: Buffer.from(msgJson, 'utf-8').toString('base64'),
  paddedHex: hex(padded),
  paddedLength: padded.length,
  // Verify it's a multiple of 256
  isMultipleOf256: padded.length % 256 === 0
};

// --- 7. Wire Format ---
const wireHeader = buildHeader(hostRatchet1.publicKeyRaw, 0, 0);
// Encrypt the padded message
const wireMsgNonce = fromHex('0a0b0c0d0e0f101112131415'); // different nonce
const { ciphertext: wireCt, tag: wireTag } = aesGcmEncrypt(mk1, wireMsgNonce, padded, wireHeader);
const wireMessage = buildWireMessage(wireHeader, wireMsgNonce, wireCt, wireTag);

vectors.wireFormat = {
  headerVersion: 0,
  dhPublicKeyRaw: hostRatchet1.publicKeyRaw,
  pn: 0,
  n: 0,
  headerHex: hex(wireHeader),
  headerLength: wireHeader.length,
  nonce: hex(wireMsgNonce),
  ciphertext: hex(wireCt),
  tag: hex(wireTag),
  wireMessageHex: hex(wireMessage),
  wireMessageBase64: b64(wireMessage),
  wireMessageLength: wireMessage.length
};

// --- 8. Safety Number ---
// Use alice and bob identity keys (their ephemeral public keys serve as identity keys for test)
const fingerprint = safetyNumber(alice.publicKey, bob.publicKey);

vectors.safetyNumber = {
  identityKeyA: alice.publicKey,
  identityKeyB: bob.publicKey,
  fingerprint: fingerprint
};

// --- 9. Full Double Ratchet Session ---
// Simulate a 5-message session between HOST and GUEST
// HOST sends 3, GUEST sends 2

// Pre-generate all ratchet keypairs for deterministic testing
const ratchetKeys = [];
for (let i = 0; i < 6; i++) {
  const privHex = crypto.createHash('sha256').update(`ratchet-keypair-${i}-test-vector`).digest('hex');
  const kp = makeP256(privHex);
  ratchetKeys.push({
    privateKey: kp.privateKey,
    publicKey: kp.publicKey,
    publicKeyRaw: kp.publicKeyRaw,
    ecdh: kp.ecdh
  });
}

// Simulate HOST side
function simulateSession() {
  // Both exchange ephemeral keys and compute shared secret
  // Use alice as HOST, bob as GUEST
  const SK = hkdfSha256(sharedSecret, 'ghost-dr-root', 'ghost-dr-rk', 32);

  // HOST init (Alice = HOST, using Signal's RatchetInitAlice)
  let hostState = {
    DHs: ratchetKeys[0],                          // HOST's first ratchet keypair
    DHr: fromHex(bob.publicKey),                   // GUEST's ephemeral public key
    RK: null,
    CKs: null,
    CKr: null,
    Ns: 0,
    Nr: 0,
    PN: 0
  };
  // HOST does initial ratchet step
  const hostDH0 = ecdhSharedSecret(hostState.DHs.ecdh, bob.publicKey);
  const hostRoot0 = rootKDF(SK, hostDH0);
  hostState.RK = hostRoot0.newRootKey;
  hostState.CKs = hostRoot0.chainKey;

  // GUEST init (Bob = GUEST, using Signal's RatchetInitBob)
  let guestState = {
    DHs: bob,                                       // GUEST's ephemeral keypair
    DHr: null,                                       // Unknown until first message
    RK: Buffer.from(SK),                             // Shared key
    CKs: null,
    CKr: null,
    Ns: 0,
    Nr: 0,
    PN: 0
  };

  const messages = [];

  // --- HOST sends message 0 ---
  {
    const { messageKey, nextChainKey } = chainKDF(hostState.CKs);
    hostState.CKs = nextChainKey;
    const msgJson = '{"m":"Hello from HOST","t":1713100800000,"c":0,"id":"msg-0"}';
    const padded = padMessage(msgJson);
    const nonce = fromHex('a00000000000000000000000');
    const header = buildHeader(hostState.DHs.publicKeyRaw, hostState.PN, hostState.Ns);
    const { ciphertext, tag } = aesGcmEncrypt(messageKey, nonce, padded, header);
    const wire = buildWireMessage(header, nonce, ciphertext, tag);
    hostState.Ns++;

    messages.push({
      sender: 'HOST',
      index: 0,
      messageJson: msgJson,
      paddedHex: hex(padded),
      messageKey: hex(messageKey),
      nonce: hex(nonce),
      headerHex: hex(header),
      ciphertextHex: hex(ciphertext),
      tagHex: hex(tag),
      wireBase64: b64(wire)
    });

    // GUEST receives: sees new DH key → ratchet
    const msgHeader = header;
    const senderDHPub = hex(msgHeader.slice(1, 65));
    // DH ratchet step on GUEST
    guestState.PN = guestState.Ns;
    guestState.Ns = 0;
    guestState.Nr = 0;
    guestState.DHr = fromHex(hostState.DHs.publicKey);
    const guestDH_recv = ecdhSharedSecret(guestState.DHs.ecdh, hostState.DHs.publicKey);
    const guestRoot_recv = rootKDF(guestState.RK, guestDH_recv);
    guestState.RK = guestRoot_recv.newRootKey;
    guestState.CKr = guestRoot_recv.chainKey;
    // Generate new GUEST ratchet keypair
    guestState.DHs = ratchetKeys[1];
    const guestDH_send = ecdhSharedSecret(guestState.DHs.ecdh, hostState.DHs.publicKey);
    const guestRoot_send = rootKDF(guestState.RK, guestDH_send);
    guestState.RK = guestRoot_send.newRootKey;
    guestState.CKs = guestRoot_send.chainKey;
    // Decrypt
    const { messageKey: guestMK } = chainKDF(guestState.CKr);
    guestState.CKr = chainKDF(guestState.CKr).nextChainKey;
    guestState.Nr++;
    const decrypted = aesGcmDecrypt(guestMK, nonce, ciphertext, tag, msgHeader);
    const text = unpadMessage(decrypted);
    if (text !== msgJson) throw new Error(`Decrypt failed msg 0: got "${text}"`);
  }

  // --- HOST sends message 1 (same chain, no ratchet) ---
  {
    const { messageKey, nextChainKey } = chainKDF(hostState.CKs);
    hostState.CKs = nextChainKey;
    const msgJson = '{"m":"Second from HOST","t":1713100801000,"c":1,"id":"msg-1"}';
    const padded = padMessage(msgJson);
    const nonce = fromHex('a10000000000000000000000');
    const header = buildHeader(hostState.DHs.publicKeyRaw, hostState.PN, hostState.Ns);
    const { ciphertext, tag } = aesGcmEncrypt(messageKey, nonce, padded, header);
    const wire = buildWireMessage(header, nonce, ciphertext, tag);
    hostState.Ns++;

    messages.push({
      sender: 'HOST',
      index: 1,
      messageJson: msgJson,
      paddedHex: hex(padded),
      messageKey: hex(messageKey),
      nonce: hex(nonce),
      headerHex: hex(header),
      ciphertextHex: hex(ciphertext),
      tagHex: hex(tag),
      wireBase64: b64(wire)
    });

    // GUEST receives: same DH key → no ratchet, just chain step
    const { messageKey: guestMK } = chainKDF(guestState.CKr);
    guestState.CKr = chainKDF(guestState.CKr).nextChainKey;
    guestState.Nr++;
    const decrypted = aesGcmDecrypt(guestMK, nonce, ciphertext, tag, header);
    if (unpadMessage(decrypted) !== msgJson) throw new Error('Decrypt failed msg 1');
  }

  // --- GUEST sends message 0 (triggers DH ratchet on HOST) ---
  {
    const { messageKey, nextChainKey } = chainKDF(guestState.CKs);
    guestState.CKs = nextChainKey;
    const msgJson = '{"m":"Reply from GUEST","t":1713100802000,"c":0,"id":"msg-2"}';
    const padded = padMessage(msgJson);
    const nonce = fromHex('b00000000000000000000000');
    const header = buildHeader(guestState.DHs.publicKeyRaw, guestState.PN, guestState.Ns);
    const { ciphertext, tag } = aesGcmEncrypt(messageKey, nonce, padded, header);
    const wire = buildWireMessage(header, nonce, ciphertext, tag);
    guestState.Ns++;

    messages.push({
      sender: 'GUEST',
      index: 2,
      messageJson: msgJson,
      paddedHex: hex(padded),
      messageKey: hex(messageKey),
      nonce: hex(nonce),
      headerHex: hex(header),
      ciphertextHex: hex(ciphertext),
      tagHex: hex(tag),
      wireBase64: b64(wire)
    });

    // HOST receives: new DH key from GUEST → ratchet
    hostState.PN = hostState.Ns;
    hostState.Ns = 0;
    hostState.Nr = 0;
    hostState.DHr = fromHex(guestState.DHs.publicKey);
    const hostDH_recv = ecdhSharedSecret(hostState.DHs.ecdh, guestState.DHs.publicKey);
    const hostRoot_recv = rootKDF(hostState.RK, hostDH_recv);
    hostState.RK = hostRoot_recv.newRootKey;
    hostState.CKr = hostRoot_recv.chainKey;
    // New HOST ratchet keypair
    hostState.DHs = ratchetKeys[2];
    const hostDH_send = ecdhSharedSecret(hostState.DHs.ecdh, guestState.DHs.publicKey);
    const hostRoot_send = rootKDF(hostState.RK, hostDH_send);
    hostState.RK = hostRoot_send.newRootKey;
    hostState.CKs = hostRoot_send.chainKey;
    // Decrypt
    const { messageKey: hostMK } = chainKDF(hostState.CKr);
    hostState.CKr = chainKDF(hostState.CKr).nextChainKey;
    hostState.Nr++;
    const decrypted = aesGcmDecrypt(hostMK, nonce, ciphertext, tag, header);
    if (unpadMessage(decrypted) !== msgJson) throw new Error('Decrypt failed msg 2');
  }

  // --- HOST sends message 0 in new chain ---
  {
    const { messageKey, nextChainKey } = chainKDF(hostState.CKs);
    hostState.CKs = nextChainKey;
    const msgJson = '{"m":"HOST again","t":1713100803000,"c":0,"id":"msg-3"}';
    const padded = padMessage(msgJson);
    const nonce = fromHex('a20000000000000000000000');
    const header = buildHeader(hostState.DHs.publicKeyRaw, hostState.PN, hostState.Ns);
    const { ciphertext, tag } = aesGcmEncrypt(messageKey, nonce, padded, header);
    const wire = buildWireMessage(header, nonce, ciphertext, tag);
    hostState.Ns++;

    messages.push({
      sender: 'HOST',
      index: 3,
      messageJson: msgJson,
      paddedHex: hex(padded),
      messageKey: hex(messageKey),
      nonce: hex(nonce),
      headerHex: hex(header),
      ciphertextHex: hex(ciphertext),
      tagHex: hex(tag),
      wireBase64: b64(wire)
    });

    // GUEST receives msg 3: new DH key (ratchetKeys[2]) → ratchet
    guestState.PN = guestState.Ns;
    guestState.Ns = 0;
    guestState.Nr = 0;
    guestState.DHr = fromHex(hostState.DHs.publicKey);
    const guestDH_recv3 = ecdhSharedSecret(guestState.DHs.ecdh, hostState.DHs.publicKey);
    const guestRoot_recv3 = rootKDF(guestState.RK, guestDH_recv3);
    guestState.RK = guestRoot_recv3.newRootKey;
    guestState.CKr = guestRoot_recv3.chainKey;
    // Generate new GUEST ratchet keypair
    guestState.DHs = ratchetKeys[3];
    const guestDH_send3 = ecdhSharedSecret(guestState.DHs.ecdh, hostState.DHs.publicKey);
    const guestRoot_send3 = rootKDF(guestState.RK, guestDH_send3);
    guestState.RK = guestRoot_send3.newRootKey;
    guestState.CKs = guestRoot_send3.chainKey;
    // Decrypt msg 3
    const { messageKey: guestMK3 } = chainKDF(guestState.CKr);
    guestState.CKr = chainKDF(guestState.CKr).nextChainKey;
    guestState.Nr++;
    const decrypted3 = aesGcmDecrypt(guestMK3, nonce, ciphertext, tag, header);
    if (unpadMessage(decrypted3) !== msgJson) throw new Error('Decrypt failed msg 3');
  }

  // --- GUEST sends message 0 in new chain (after ratchet from receiving msg 3) ---
  {
    const { messageKey, nextChainKey } = chainKDF(guestState.CKs);
    guestState.CKs = nextChainKey;
    const msgJson = '{"m":"GUEST second","t":1713100804000,"c":0,"id":"msg-4"}';
    const padded = padMessage(msgJson);
    const nonce = fromHex('b10000000000000000000000');
    const header = buildHeader(guestState.DHs.publicKeyRaw, guestState.PN, guestState.Ns);
    const { ciphertext, tag } = aesGcmEncrypt(messageKey, nonce, padded, header);
    const wire = buildWireMessage(header, nonce, ciphertext, tag);
    guestState.Ns++;

    messages.push({
      sender: 'GUEST',
      index: 4,
      messageJson: msgJson,
      paddedHex: hex(padded),
      messageKey: hex(messageKey),
      nonce: hex(nonce),
      headerHex: hex(header),
      ciphertextHex: hex(ciphertext),
      tagHex: hex(tag),
      wireBase64: b64(wire)
    });
  }

  return messages;
}

const sessionMessages = simulateSession();

vectors.session = {
  description: 'Full 5-message session: HOST sends 2, GUEST sends 1, HOST sends 1, GUEST sends 1',
  hostEphemeralPrivateKey: alice.privateKey,
  hostEphemeralPublicKey: alice.publicKey,
  guestEphemeralPrivateKey: bob.privateKey,
  guestEphemeralPublicKey: bob.publicKey,
  sharedSecret: hex(sharedSecret),
  initialRootKey: hex(hkdfSha256(sharedSecret, 'ghost-dr-root', 'ghost-dr-rk', 32)),
  ratchetKeypairs: ratchetKeys.map(k => ({
    privateKey: k.privateKey,
    publicKey: k.publicKey,
    publicKeyRaw: k.publicKeyRaw
  })),
  messages: sessionMessages
};

// --- Phase 6: contact key rotation (deterministic HKDF) ---
{
  const shared = Buffer.alloc(32, 0xAA);
  const derived = hkdfSha256(shared, Buffer.from('ghost-rot-v1'), Buffer.from('ghost-rot-seed'), 32);
  vectors.contactRotation = {
    description: 'HKDF-derived next-generation keypair seed, deterministic across iOS ↔ Android.',
    sessionSecret: hex(shared),
    salt: 'ghost-rot-v1',
    info: 'ghost-rot-seed',
    length: 32,
    derivedSeed: hex(derived)
  };
}

// --- Phase 6: ML-KEM hybrid root-key derivation (no actual KEM — just the combine step) ---
{
  const ecdhSS = Buffer.alloc(32, 0xAB);
  const pqSS   = Buffer.alloc(32, 0xCD);
  const withPQ = hkdfSha256(
    Buffer.concat([ecdhSS, pqSS]),
    Buffer.from('ghost-chat-v1-pq'),
    Buffer.from('ghost-dr-root'),
    32
  );
  const noPQ = hkdfSha256(
    ecdhSS,
    Buffer.from('ghost-chat-v1-pq'),
    Buffer.from('ghost-dr-root'),
    32
  );
  vectors.pqHybrid = {
    description: 'HKDF combine of ECDH shared secret + optional ML-KEM shared secret.',
    ecdhSharedSecret: hex(ecdhSS),
    pqSharedSecret: hex(pqSS),
    salt: 'ghost-chat-v1-pq',
    info: 'ghost-dr-root',
    combinedWithPQ: hex(withPQ),
    combinedWithoutPQ: hex(noPQ)
  };
}

// --- Phase 6: ReplayGuard boundary values (no crypto — just human reference) ---
vectors.replayGuard = {
  description: 'Timestamp and counter window parameters for ReplayGuard. Informational only.',
  timestampWindowMs: 5 * 60 * 1000,
  counterWindow: 1000,
  nonceTrackWindowMs: 10 * 60 * 1000
};

// --- Phase 7: ML-KEM hybrid handshake combine step, with pinned shared secrets ---
// Kyber encapsulation itself is not seedable deterministically from fixed inputs in Node,
// so we pin the COMBINE step (HKDF over concat(ecdh, pq)). Both sides independently run
// PostQuantum.hybridDeriveSharedKey and must land on `expectedSessionKey`.
{
  const ecdhSS = Buffer.alloc(32, 0xAB); // matches pqHybrid above
  const pqSS   = Buffer.alloc(32, 0xCD);
  const expectedSessionKey = hkdfSha256(
    Buffer.concat([ecdhSS, pqSS]),
    Buffer.from('ghost-chat-v1-pq'),
    Buffer.from('ghost-dr-root'),
    32
  );
  const expectedSessionKeyEcdhOnly = hkdfSha256(
    ecdhSS,
    Buffer.from('ghost-chat-v1-pq'),
    Buffer.from('ghost-dr-root'),
    32
  );
  vectors.pqHandshake = {
    description: 'Hybrid session-key derivation after ML-KEM handshake. Pins the combine step; ' +
                 'the KEM itself is exercised by platform tests because Kyber is not deterministic from ' +
                 'fixed seeds in Node.',
    ecdhSharedSecret: hex(ecdhSS),
    pqSharedSecret: hex(pqSS),
    hybridSalt: 'ghost-chat-v1-pq',
    hybridInfo: 'ghost-dr-root',
    expectedSessionKey: hex(expectedSessionKey),
    expectedSessionKeyEcdhOnly: hex(expectedSessionKeyEcdhOnly)
  };
}

// --- Phase 7: Message envelope {m, t, c, id} — padded form. Sorted keys in JSON. ---
{
  // Envelope is sorted-key JSON: c, id, m, t.
  const envJson = '{"c":7,"id":"env-1","m":"hello","t":1713100800000}';
  // Pad using the same zero-fill algorithm as Phase-2 messagePadding test vector.
  const paddedEnv = padMessage(envJson);
  vectors.messageEnvelope = {
    description: 'Plaintext envelope wrapping every chat/control message. Sorted JSON keys, then ' +
                 'padded via the Phase-2 MessagePadding algorithm before encryption.',
    fields: { m: 'hello', t: 1713100800000, c: 7, id: 'env-1' },
    canonicalJson: envJson,
    paddedHex: hex(paddedEnv),
    paddedLength: paddedEnv.length,
    isMultipleOf256: paddedEnv.length % 256 === 0
  };
}

// --- Output ---
const output = JSON.stringify(vectors, null, 2);
const fs = require('fs');
const path = require('path');
const outPath = path.join(__dirname, '..', 'docs', 'test-vectors.json');
fs.writeFileSync(outPath, output + '\n');
console.log(`Test vectors written to ${outPath}`);
console.log(`ECDH shared secret: ${vectors.ecdh.sharedSecret.slice(0, 16)}...`);
console.log(`Initial root key: ${vectors.initialRootKey.rootKey.slice(0, 16)}...`);
console.log(`Safety number: ${vectors.safetyNumber.fingerprint}`);
console.log(`Session messages: ${sessionMessages.length}`);
console.log(`Contact rotation seed: ${vectors.contactRotation.derivedSeed.slice(0, 16)}...`);
console.log(`PQ hybrid (with PQ): ${vectors.pqHybrid.combinedWithPQ.slice(0, 16)}...`);
console.log(`PQ handshake combine: ${vectors.pqHandshake.expectedSessionKey.slice(0, 16)}...`);
console.log(`Envelope padded length: ${vectors.messageEnvelope.paddedLength} (mult256=${vectors.messageEnvelope.isMultipleOf256})`);
console.log('All self-checks passed.');
