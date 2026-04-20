#!/usr/bin/env node
// Cross-platform verification: verifies that test-vectors.json is present,
// well-formed, and that both iOS and Android tests reference the same file.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function sha256File(filePath) {
  return crypto.createHash('sha256')
    .update(fs.readFileSync(filePath))
    .digest('hex');
}

function fail(msg) {
  console.error(`FAIL: ${msg}`);
  process.exit(1);
}

const rootDir = path.join(__dirname, '..');
const docsVectors = path.join(rootDir, 'docs', 'test-vectors.json');
const iosVectors = path.join(rootDir, 'ios', 'Tests', 'GhostCryptoTests', 'test-vectors.json');
const androidVectors = path.join(rootDir, 'android', 'crypto', 'src', 'test', 'resources', 'test-vectors.json');

// 1. All three files must exist and be identical
for (const p of [docsVectors, iosVectors, androidVectors]) {
  if (!fs.existsSync(p)) fail(`Test vectors missing at ${p}`);
}

const docsHash = sha256File(docsVectors);
const iosHash = sha256File(iosVectors);
const androidHash = sha256File(androidVectors);

if (docsHash !== iosHash) fail(`iOS test-vectors.json diverged from docs/ (${iosHash} vs ${docsHash})`);
if (docsHash !== androidHash) fail(`Android test-vectors.json diverged from docs/ (${androidHash} vs ${docsHash})`);

console.log(`OK: All three test-vectors.json files identical (sha256=${docsHash.slice(0, 16)}...)`);

// 2. Parse and validate structure
const vectors = JSON.parse(fs.readFileSync(docsVectors, 'utf-8'));

const requiredSections = [
  'ecdh', 'initialRootKey', 'rootKDF', 'chainKDF', 'aesGcm',
  'messagePadding', 'wireFormat', 'safetyNumber', 'session'
];
for (const section of requiredSections) {
  if (!vectors[section]) fail(`Missing section: ${section}`);
}

// 3. Session must have 5 messages covering both sender→receiver and DH ratchet triggers
const msgs = vectors.session.messages;
if (msgs.length < 5) fail(`Session has ${msgs.length} messages, expected >= 5`);

const senders = msgs.map(m => m.sender);
if (!senders.includes('HOST')) fail('No HOST messages in session');
if (!senders.includes('GUEST')) fail('No GUEST messages in session');

// 4. Independently re-verify a sample vector using Node.js crypto
// This catches drift between the JSON and what Node's crypto actually produces
const { ecdh } = vectors;
const alice = crypto.createECDH('prime256v1');
alice.setPrivateKey(Buffer.from(ecdh.alice.privateKey, 'hex'));
const computedShared = alice.computeSecret(Buffer.from(ecdh.bob.publicKey, 'hex')).toString('hex');
if (computedShared !== ecdh.sharedSecret) {
  fail(`Test vector drift: ECDH shared secret mismatch. Vector says ${ecdh.sharedSecret}, Node computes ${computedShared}`);
}

// Initial root key
const hkdfOut = Buffer.from(crypto.hkdfSync('sha256',
  Buffer.from(ecdh.sharedSecret, 'hex'),
  Buffer.from('ghost-dr-root', 'utf-8'),
  Buffer.from('ghost-dr-rk', 'utf-8'),
  32)).toString('hex');
if (hkdfOut !== vectors.initialRootKey.rootKey) {
  fail(`Test vector drift: initial root key mismatch. Vector says ${vectors.initialRootKey.rootKey}, Node computes ${hkdfOut}`);
}

console.log('OK: Test vectors self-consistent with Node.js crypto.');
console.log('OK: Cross-platform verification passed.');
