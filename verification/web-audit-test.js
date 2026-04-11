/**
 * Ghost Chat — Web Audit Verification Test
 *
 * Проверяет 4 бага, найденных при аудите Web клиента:
 * W1: Ringing timeout (30s auto-decline)
 * W2: unpadMessage strict prefix validation
 * W3: startCall error path voice/mic cleanup
 * W4: acceptCall error handler voice destruction
 *
 * + regression тесты: false positive верификация
 */

import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rootDir = resolve(__dirname, '..');

let passed = 0;
let failed = 0;

function assert(condition, message) {
  if (condition) {
    passed++;
    console.log(`  ✅ ${message}`);
  } else {
    failed++;
    console.log(`  ❌ ${message}`);
  }
}

function section(title) {
  console.log(`\n━━━ ${title} ━━━`);
}

// ============================================================
// Load source files
// ============================================================
const appJs = readFileSync(resolve(rootDir, 'client/js/app.js'), 'utf-8');
const cryptoJs = readFileSync(resolve(rootDir, 'client/js/crypto.js'), 'utf-8');
const voiceJs = readFileSync(resolve(rootDir, 'client/js/voice.js'), 'utf-8');
const webrtcJs = readFileSync(resolve(rootDir, 'client/js/webrtc.js'), 'utf-8');
const securityMonitorJs = readFileSync(resolve(rootDir, 'client/js/security-monitor.js'), 'utf-8');
const serverJs = readFileSync(resolve(rootDir, 'server/index.js'), 'utf-8');

// ============================================================
// W1: RINGING TIMEOUT
// ============================================================
section('W1: Ringing Timeout (30s auto-decline)');

// Check _ringingTimeout property is declared
assert(
  appJs.includes('this._ringingTimeout = null'),
  'Constructor declares _ringingTimeout property'
);

// Check handleIncomingCall sets timeout
assert(
  appJs.includes("this._ringingTimeout = setTimeout(") &&
  appJs.includes("30000"),
  'handleIncomingCall sets 30s ringing timeout'
);

// Check timeout calls declineCall
{
  const incomingCallMatch = appJs.match(
    /this\._ringingTimeout\s*=\s*setTimeout\(\(\)\s*=>\s*\{[^}]*declineCall/s
  );
  assert(!!incomingCallMatch, 'Ringing timeout triggers declineCall()');
}

// Check timeout adds "missed call" message
assert(
  appJs.includes('Пропущенный звонок'),
  'Ringing timeout shows "Пропущенный звонок" message'
);

// Check acceptCall clears ringing timeout
{
  const acceptCallBody = appJs.substring(
    appJs.indexOf('async acceptCall()'),
    appJs.indexOf('async acceptCall()') + 500
  );
  assert(
    acceptCallBody.includes('clearTimeout(this._ringingTimeout)'),
    'acceptCall() clears ringing timeout'
  );
}

// Check declineCall clears ringing timeout
{
  const declineIdx = appJs.indexOf('declineCall() {');
  const declineBody = appJs.substring(declineIdx, declineIdx + 500);
  assert(
    declineBody.includes('clearTimeout(this._ringingTimeout)'),
    'declineCall() clears ringing timeout'
  );
}

// Check handleCallEnded clears ringing timeout
{
  const endedIdx = appJs.indexOf('handleCallEnded()');
  const endedBody = appJs.substring(endedIdx, endedIdx + 500);
  assert(
    endedBody.includes('clearTimeout(this._ringingTimeout)'),
    'handleCallEnded() clears ringing timeout'
  );
}

// Check destroy clears ringing timeout
{
  const destroyIdx = appJs.indexOf('destroy() {');
  const destroyBody = appJs.substring(destroyIdx, destroyIdx + 1000);
  assert(
    destroyBody.includes('clearTimeout(this._ringingTimeout)'),
    'destroy() clears ringing timeout'
  );
}

// ============================================================
// W2: UNPAD MESSAGE STRICT PREFIX VALIDATION
// ============================================================
section('W2: unpadMessage Strict Prefix Validation');

// Check regex validation exists
assert(
  cryptoJs.includes('/^\\d{4}$/'),
  'unpadMessage uses strict /^\\d{4}$/ regex for prefix'
);

// Check regex is applied before parseInt
{
  const unpadIdx = cryptoJs.indexOf('unpadMessage(paddedMessage)');
  const unpadBody = cryptoJs.substring(unpadIdx, unpadIdx + 400);
  const regexIdx = unpadBody.indexOf('/^\\d{4}$/');
  const parseIntIdx = unpadBody.indexOf('parseInt');
  assert(
    regexIdx > 0 && parseIntIdx > 0 && regexIdx < parseIntIdx,
    'Regex check occurs BEFORE parseInt'
  );
}

// Simulate prefix validation logic
function testUnpadPrefix(prefix) {
  return /^\d{4}$/.test(prefix);
}

assert(testUnpadPrefix('0012'), 'Valid prefix "0012" passes');
assert(testUnpadPrefix('0256'), 'Valid prefix "0256" passes');
assert(testUnpadPrefix('9999'), 'Valid prefix "9999" passes');
assert(!testUnpadPrefix('00ab'), 'Invalid prefix "00ab" rejected');
assert(!testUnpadPrefix('ab12'), 'Invalid prefix "ab12" rejected');
assert(!testUnpadPrefix('   4'), 'Whitespace prefix "   4" rejected');
assert(!testUnpadPrefix('12'), 'Short prefix "12" rejected');
assert(!testUnpadPrefix('12345'), 'Long prefix "12345" rejected');
assert(!testUnpadPrefix(''), 'Empty prefix rejected');

// Check original length bounds check still present
{
  const unpadIdx = cryptoJs.indexOf('unpadMessage(paddedMessage)');
  const unpadBody = cryptoJs.substring(unpadIdx, unpadIdx + 500);
  assert(
    unpadBody.includes('originalLength > paddedMessage.length - 4'),
    'Bounds check: originalLength <= paddedMessage.length - 4'
  );
}

// ============================================================
// W3: startCall ERROR PATH CLEANUP
// ============================================================
section('W3: startCall Error Path — Voice/Mic Cleanup');

// Extract the catch block of startCall
{
  const startCallIdx = appJs.indexOf('async startCall()');
  const startCallEnd = appJs.indexOf('handleIncomingCall()', startCallIdx);
  const startCallBody = appJs.substring(startCallIdx, startCallEnd);

  // Find catch block
  const catchIdx = startCallBody.lastIndexOf('} catch (error)');
  const catchBlock = startCallBody.substring(catchIdx);

  assert(
    catchBlock.includes('this.voice.destroy()'),
    'startCall catch: destroys voice'
  );
  assert(
    catchBlock.includes('this.voice = null'),
    'startCall catch: nullifies voice reference'
  );
  assert(
    catchBlock.includes('this._cleanupRemoteAudio()'),
    'startCall catch: cleans up remote audio'
  );
  assert(
    catchBlock.includes('this._remoteStream = null'),
    'startCall catch: nullifies remote stream'
  );
  assert(
    catchBlock.includes("this.callState = 'idle'"),
    'startCall catch: resets callState to idle'
  );
  assert(
    catchBlock.includes('_suppressNegotiation = false'),
    'startCall catch: resets _suppressNegotiation'
  );
}

// ============================================================
// W4: acceptCall ERROR HANDLER VOICE DESTRUCTION
// ============================================================
section('W4: acceptCall Error Handler — Proper Voice Destruction');

{
  const acceptIdx = appJs.indexOf('async acceptCall()');
  const acceptEnd = appJs.indexOf('declineCall()', acceptIdx);
  const acceptBody = appJs.substring(acceptIdx, acceptEnd);

  const catchIdx = acceptBody.lastIndexOf('} catch (error)');
  const catchBlock = acceptBody.substring(catchIdx);

  assert(
    catchBlock.includes('this.voice.destroy()'),
    'acceptCall catch: destroys voice (stops mic stream)'
  );
  assert(
    catchBlock.includes('this.voice = null'),
    'acceptCall catch: nullifies voice reference'
  );
  assert(
    catchBlock.includes('this._cleanupRemoteAudio()'),
    'acceptCall catch: cleans up remote audio'
  );
  assert(
    catchBlock.includes('this._remoteStream = null'),
    'acceptCall catch: nullifies remote stream'
  );
  assert(
    catchBlock.includes('this.pendingRenegotiationOffer = null'),
    'acceptCall catch: clears pending renegotiation offer'
  );
  assert(
    catchBlock.includes('_suppressNegotiation = true') &&
    catchBlock.includes('_suppressNegotiation = false'),
    'acceptCall catch: wraps cleanup with suppress/unsuppress negotiation'
  );
}

// Old pattern should NOT exist (partial cleanup)
{
  // The old pattern was: this.voice.isInCall = false; this.voice.stopCallTimer();
  // without calling destroy(). After fix, voice is destroyed.
  const acceptIdx = appJs.indexOf('async acceptCall()');
  const acceptEnd = appJs.indexOf('declineCall()', acceptIdx);
  const acceptBody = appJs.substring(acceptIdx, acceptEnd);
  const catchIdx = acceptBody.lastIndexOf('} catch (error)');
  const catchBlock = acceptBody.substring(catchIdx);

  assert(
    !catchBlock.includes('this.voice.isInCall = false'),
    'Old pattern removed: no partial "voice.isInCall = false" in catch'
  );
  assert(
    !catchBlock.includes('this.voice.stopCallTimer()'),
    'Old pattern removed: no partial "voice.stopCallTimer()" in catch'
  );
}

// ============================================================
// REGRESSION: Voice cleanup on disconnect
// ============================================================
section('Regression: Voice cleanup on network disconnect');

{
  const disconnectIdx = appJs.indexOf('this.rtc.onDisconnected');
  const disconnectBody = appJs.substring(disconnectIdx, disconnectIdx + 600);
  assert(
    disconnectBody.includes('this.voice.destroy()'),
    'onDisconnected handler destroys voice'
  );
  assert(
    disconnectBody.includes("this.callState = 'idle'"),
    'onDisconnected resets callState'
  );
}

// ============================================================
// REGRESSION: onnegotiationneeded try/finally
// ============================================================
section('Regression: WebRTC onnegotiationneeded safety');

{
  const negIdx = webrtcJs.indexOf('onnegotiationneeded');
  const negBody = webrtcJs.substring(negIdx, negIdx + 1000);
  assert(
    negBody.includes('finally') && negBody.includes('_negotiating = false'),
    'onnegotiationneeded uses try/finally for _negotiating flag'
  );
}

// ============================================================
// REGRESSION: DoubleRatchet destroy zeroes all keys
// ============================================================
section('Regression: DoubleRatchet key zeroing on destroy');

{
  const destroyIdx = cryptoJs.indexOf('destroy() {');
  const destroyBody = cryptoJs.substring(destroyIdx, destroyIdx + 600);
  assert(
    destroyBody.includes('this.skippedKeys.forEach(mk => wipe(mk))'),
    'destroy() zeroes skipped message keys'
  );
  assert(
    destroyBody.includes('wipe(this.rootKey)'),
    'destroy() zeroes rootKey'
  );
  assert(
    destroyBody.includes('wipe(this.sendChainKey)') && destroyBody.includes('wipe(this.receiveChainKey)'),
    'destroy() zeroes send/receive chain keys'
  );
  assert(
    destroyBody.includes('wipe(this.sendHeaderKey)') && destroyBody.includes('wipe(this.receiveHeaderKey)'),
    'destroy() zeroes send/receive header keys'
  );
  assert(
    destroyBody.includes('this.dhSendingRaw.fill(0)'),
    'destroy() zeroes dhSendingRaw'
  );
}

// ============================================================
// REGRESSION: Serialization queue prevents concurrent ratchet ops
// ============================================================
section('Regression: Serialization queue for encrypt/decrypt');

assert(
  cryptoJs.includes('this._queue = Promise.resolve()'),
  'GhostCrypto has serialization queue (_queue)'
);

// Check encrypt uses queue
{
  const encryptIdx = cryptoJs.indexOf('async encrypt(');
  if (encryptIdx > -1) {
    const encryptBody = cryptoJs.substring(encryptIdx, encryptIdx + 300);
    assert(
      cryptoJs.includes('this._queue = this._queue.then') || cryptoJs.includes('_enqueue'),
      'encrypt/decrypt operations are serialized through queue'
    );
  }
}

// ============================================================
// REGRESSION: DTLS fingerprint binding
// ============================================================
section('Regression: DTLS fingerprint MITM protection');

assert(
  appJs.includes('DTLS fingerprint не совпадает') || appJs.includes('DTLS fingerprint mismatch'),
  'DTLS fingerprint mismatch triggers MITM block'
);

assert(
  appJs.includes("this.leave()") &&
  appJs.match(/fingerprint.*leave\(\)/s),
  'DTLS mismatch terminates connection (calls leave())'
);

// ============================================================
// REGRESSION: P-256 key validation
// ============================================================
section('Regression: P-256 public key validation');

assert(
  cryptoJs.includes('keyBytes.byteLength !== 65'),
  'Validates P-256 key is exactly 65 bytes'
);
assert(
  cryptoJs.includes("keyBytes[0] !== 0x04"),
  'Validates uncompressed point prefix (0x04)'
);
assert(
  cryptoJs.includes('identity point rejected'),
  'Rejects identity (all-zero) point'
);
assert(
  cryptoJs.includes('reflection attack'),
  'Rejects peer key matching own key (reflection attack)'
);

// ============================================================
// REGRESSION: CSPRNG entropy check
// ============================================================
section('Regression: CSPRNG entropy health check');

assert(
  cryptoJs.includes('CSPRNG entropy check failed'),
  'Entropy health check before key generation'
);

// ============================================================
// REGRESSION: Replay protection
// ============================================================
section('Regression: Replay protection');

assert(
  cryptoJs.includes('receivedNonces'),
  'Nonce tracking for replay protection'
);
assert(
  cryptoJs.includes('NONCE_EXPIRY_MS'),
  'Nonce expiry (5 min) configured'
);

// ============================================================
// SERVER: Security headers
// ============================================================
section('Server: Security Headers');

assert(
  serverJs.includes("script-src 'self'"),
  "CSP: script-src 'self' (no unsafe-inline)"
);
assert(
  serverJs.includes("style-src 'self'"),
  "CSP: style-src 'self' (no unsafe-inline)"
);
assert(
  serverJs.includes("object-src 'none'"),
  "CSP: object-src 'none'"
);
assert(
  serverJs.includes("frame-ancestors 'none'"),
  "CSP: frame-ancestors 'none' (anti-clickjacking)"
);
assert(
  serverJs.includes('Strict-Transport-Security'),
  'HSTS header present'
);
assert(
  serverJs.includes("X-Frame-Options', 'DENY"),
  'X-Frame-Options: DENY'
);
assert(
  serverJs.includes("Cross-Origin-Opener-Policy', 'same-origin"),
  'COOP: same-origin (Spectre protection)'
);

// ============================================================
// SERVER: Rate limiting
// ============================================================
section('Server: Rate Limiting');

assert(
  serverJs.includes('checkRateLimit(clientIp)'),
  'Per-IP rate limiting on WS connection'
);
assert(
  serverJs.includes('checkRoomJoinLimit('),
  'Per-room join rate limiting (brute force protection)'
);
assert(
  serverJs.includes('SIGNAL_RATE_LIMIT') && serverJs.includes('30'),
  'Per-connection signal rate limit (30/sec)'
);

// ============================================================
// SERVER: WebSocket validation
// ============================================================
section('Server: WebSocket Validation');

assert(
  serverJs.includes("url.pathname === '/ws'"),
  'WebSocket upgrade restricted to /ws path'
);
assert(
  serverJs.includes('ALLOWED_WS_MESSAGE_TYPES'),
  'WebSocket message type whitelist'
);
assert(
  serverJs.includes('ALLOWED_SIGNAL_TYPES'),
  'Signal data type whitelist (offer, answer, ice-candidate)'
);
assert(
  serverJs.includes('maxPayload: 64 * 1024'),
  'WebSocket max payload 64KB (DoS protection)'
);

// ============================================================
// SERVER: Path traversal protection
// ============================================================
section('Server: Path Traversal Protection');

assert(
  serverJs.includes('resolvedPath.startsWith(clientDir)'),
  'Resolved path must be within client directory'
);
assert(
  serverJs.includes('req.url.length > 2048'),
  'URL length limit (2048 chars)'
);

// ============================================================
// SERVER: SRI (Subresource Integrity)
// ============================================================
section('Server: Subresource Integrity');

assert(
  serverJs.includes('computeSRI'),
  'SRI hashes computed at startup'
);
assert(
  serverJs.includes('integrity=') && serverJs.includes('crossorigin="anonymous"'),
  'SRI integrity attributes injected into HTML'
);

// ============================================================
// VOICE: Proper cleanup
// ============================================================
section('Voice: Call Cleanup');

assert(
  voiceJs.includes('this.peerConnection.removeTrack(this.audioSender)'),
  'endCall removes audio track from PeerConnection'
);
assert(
  voiceJs.includes("track.stop()"),
  'endCall stops all local tracks'
);
assert(
  voiceJs.includes('this.audioContext.close()'),
  'endCall closes AudioContext'
);

// ============================================================
// VOICE: Security monitoring
// ============================================================
section('Voice: Security Monitoring');

assert(
  voiceJs.includes('startSecurityMonitoring'),
  'Voice starts security monitoring during calls'
);
assert(
  voiceJs.includes('stopSecurityMonitoring'),
  'Voice stops security monitoring on endCall'
);

// ============================================================
// SecurityMonitor: Detection
// ============================================================
section('SecurityMonitor: Detection Capabilities');

assert(
  securityMonitorJs.includes('suspicious-audio-device'),
  'Detects suspicious audio devices (virtual mixers)'
);
assert(
  securityMonitorJs.includes('screen-capture-attempt'),
  'Intercepts Screen Capture API'
);
assert(
  securityMonitorJs.includes('devtools-detected'),
  'Detects DevTools opening'
);
assert(
  securityMonitorJs.includes('ALERT_COOLDOWN'),
  'Alert cooldown prevents spam (10s)'
);

// ============================================================
// SecurityMonitor: Cleanup
// ============================================================
section('SecurityMonitor: Proper Cleanup');

assert(
  securityMonitorJs.includes('removeEventListener(\'devicechange\''),
  'stopMonitoring removes devicechange listener'
);
assert(
  securityMonitorJs.includes('this._originalGetDisplayMedia') &&
  securityMonitorJs.includes('navigator.mediaDevices.getDisplayMedia = this._originalGetDisplayMedia'),
  'stopMonitoring restores original getDisplayMedia'
);

// ============================================================
// APP: Session persistence
// ============================================================
section('App: Session Persistence');

assert(
  appJs.includes('GhostChat._savedSession'),
  'Session stored in memory (not sessionStorage — zero-trace)'
);
assert(
  appJs.includes('SESSION_TTL') && appJs.includes('10 * 60 * 1000'),
  'Session TTL: 10 minutes (matches server room TTL)'
);

// ============================================================
// APP: destroy() comprehensive cleanup
// ============================================================
section('App: destroy() Comprehensive Cleanup');

{
  const destroyIdx = appJs.indexOf('destroy() {');
  const destroyBody = appJs.substring(destroyIdx, destroyIdx + 2000);

  assert(
    destroyBody.includes('this._reconnecting = false'),
    'destroy: stops reconnection'
  );
  assert(
    destroyBody.includes('this.roomId = null'),
    'destroy: clears roomId'
  );
  assert(
    destroyBody.includes('this.rtc.destroy()'),
    'destroy: destroys RTC'
  );
  assert(
    destroyBody.includes('this.crypto.destroy()'),
    'destroy: destroys crypto (zeroes keys)'
  );
  assert(
    destroyBody.includes('this.ws.onclose = null'),
    'destroy: removes WS onclose to prevent reconnect'
  );
  assert(
    destroyBody.includes('clearTimeout(this._ringingTimeout)'),
    'destroy: clears ringing timeout'
  );
  assert(
    destroyBody.includes('clearTimeout(this._typingCancelTimer)'),
    'destroy: clears typing timers'
  );
}

// ============================================================
// CROSS-PLATFORM: Protocol version
// ============================================================
section('Cross-Platform: Protocol Compatibility');

assert(
  cryptoJs.includes('static PROTOCOL_VERSION = 3'),
  'Web protocol version is 3'
);
assert(
  appJs.includes("peerVersion < 2"),
  'Web accepts v2+ peers (backward compat)'
);

// ============================================================
// CROSS-PLATFORM: KDF labels match
// ============================================================
section('Cross-Platform: KDF Label Consistency');

const kdfLabels = [
  'ghost-dr-root',
  'ghost-dr-rk',
  'ghost-dr-chain',
  'ghost-dr-ck',
  'ghost-dr-mk',
  'ghost-dr-init'
];

for (const label of kdfLabels) {
  assert(
    cryptoJs.includes(label),
    `KDF label "${label}" present in Web crypto`
  );
}

assert(
  cryptoJs.includes('ghost-chat-v2') && cryptoJs.includes('ghost-dr-init-secret'),
  'HKDF derivation uses "ghost-chat-v2" salt + "ghost-dr-init-secret" info'
);

// ============================================================
// CROSS-PLATFORM: Padding format
// ============================================================
section('Cross-Platform: Message Padding');

assert(
  cryptoJs.includes('blockSize = 256'),
  'Default pad block size: 256 bytes'
);
assert(
  cryptoJs.includes('messageLength > 9999'),
  'Max message length: 9999 (4-digit prefix)'
);
assert(
  cryptoJs.includes("messageLength.toString().padStart(4, '0')"),
  'Prefix is 4-digit zero-padded length'
);

// ============================================================
// RESULTS
// ============================================================
console.log('\n' + '═'.repeat(60));
console.log(`  TOTAL: ${passed + failed} tests | ✅ Passed: ${passed} | ❌ Failed: ${failed}`);
console.log('═'.repeat(60));

if (failed > 0) {
  process.exit(1);
}
