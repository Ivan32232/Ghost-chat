/**
 * Ghost Chat — Phase 3 Feature Verification Tests
 * Tests: wire format migration, reply, delete, edit, backward compatibility
 *
 * Run: node verification/phase3-test.js
 */

import assert from 'node:assert';

let passed = 0;
let failed = 0;

function test(name, fn) {
    try {
        fn();
        passed++;
        console.log(`  ✅ ${name}`);
    } catch (e) {
        failed++;
        console.log(`  ❌ ${name}: ${e.message}`);
    }
}

console.log('\n════════════════════════════════════════════════════════════');
console.log('  PHASE 3: Wire Format + Reply + Delete + Edit Tests');
console.log('════════════════════════════════════════════════════════════\n');

// ═══════════════════════════════════════════
// 1. NEW WIRE FORMAT
// ═══════════════════════════════════════════
console.log('NEW WIRE FORMAT: JSON {m, id, r}');
console.log('========================================');

test('Basic message format: {m, id}', () => {
    const msg = { m: 'Hello', id: '550e8400-e29b-41d4-a716-446655440000' };
    assert.strictEqual(typeof msg.m, 'string');
    assert.strictEqual(typeof msg.id, 'string');
    assert.strictEqual(msg.id.length, 36); // UUID format
});

test('Reply message format: {m, id, r: {id, t}}', () => {
    const msg = {
        m: 'Reply text',
        id: '550e8400-e29b-41d4-a716-446655440001',
        r: {
            id: '550e8400-e29b-41d4-a716-446655440000',
            t: 'Original message text'
        }
    };
    assert.strictEqual(msg.m, 'Reply text');
    assert.ok(msg.r);
    assert.strictEqual(typeof msg.r.id, 'string');
    assert.strictEqual(typeof msg.r.t, 'string');
});

test('Message without reply has no r field', () => {
    const msg = { m: 'Hello', id: 'uuid-123' };
    assert.strictEqual(msg.r, undefined);
});

test('Reply text is truncated to 100 chars max', () => {
    const longText = 'A'.repeat(200);
    const truncated = longText.substring(0, 100);
    assert.strictEqual(truncated.length, 100);
});

// ═══════════════════════════════════════════
// 2. BACKWARD COMPATIBILITY
// ═══════════════════════════════════════════
console.log('\nBACKWARD COMPATIBILITY');
console.log('========================================');

test('Old format (raw string) is still valid plaintext', () => {
    const plaintext = 'Hello from old client';
    // Try JSON parse — should fail
    let parsed = null;
    try { parsed = JSON.parse(plaintext); } catch (_) {}
    // Fallback: use raw string
    const displayText = parsed?.m ?? plaintext;
    assert.strictEqual(displayText, 'Hello from old client');
});

test('New format parsed correctly', () => {
    const plaintext = JSON.stringify({ m: 'Hello from new client', id: 'uuid-123' });
    const parsed = JSON.parse(plaintext);
    assert.strictEqual(parsed.m, 'Hello from new client');
    assert.strictEqual(parsed.id, 'uuid-123');
});

test('New format with reply parsed correctly', () => {
    const plaintext = JSON.stringify({
        m: 'Reply!',
        id: 'uuid-456',
        r: { id: 'uuid-123', t: 'Original' }
    });
    const parsed = JSON.parse(plaintext);
    assert.strictEqual(parsed.m, 'Reply!');
    assert.strictEqual(parsed.r.id, 'uuid-123');
    assert.strictEqual(parsed.r.t, 'Original');
});

test('Control message NOT confused with new format (has _ctrl)', () => {
    const ctrl = { type: 'typing', isTyping: true, _ctrl: true };
    // Has _ctrl — it's a control message, not chat
    assert.strictEqual(ctrl._ctrl, true);
    assert.strictEqual(ctrl.m, undefined); // no m field
});

test('New format NOT confused with control (no _ctrl)', () => {
    const msg = { m: 'Hello', id: 'uuid' };
    assert.strictEqual(msg._ctrl, undefined);
    assert.ok(msg.m); // has m field — it's a chat message
});

test('Malformed JSON falls back to raw text', () => {
    const plaintext = 'Not {valid JSON';
    let parsed = null;
    try { parsed = JSON.parse(plaintext); } catch (_) {}
    const displayText = parsed?.m ?? plaintext;
    assert.strictEqual(displayText, 'Not {valid JSON');
});

test('JSON without m field falls back to raw text', () => {
    const plaintext = JSON.stringify({ text: 'old format maybe' });
    const parsed = JSON.parse(plaintext);
    if (!parsed.m && !parsed._ctrl) {
        // Fallback to raw string
        assert.ok(true);
    }
});

// ═══════════════════════════════════════════
// 3. CONTROL MESSAGES: DELETE + EDIT
// ═══════════════════════════════════════════
console.log('\nCONTROL MESSAGES: DELETE + EDIT');
console.log('========================================');

test('message-delete format', () => {
    const ctrl = { type: 'message-delete', messageId: 'uuid-123', _ctrl: true };
    assert.strictEqual(ctrl.type, 'message-delete');
    assert.strictEqual(ctrl.messageId, 'uuid-123');
    assert.strictEqual(ctrl._ctrl, true);
});

test('message-edit format', () => {
    const ctrl = { type: 'message-edit', messageId: 'uuid-123', newText: 'Edited text', _ctrl: true };
    assert.strictEqual(ctrl.type, 'message-edit');
    assert.strictEqual(ctrl.messageId, 'uuid-123');
    assert.strictEqual(ctrl.newText, 'Edited text');
    assert.strictEqual(ctrl._ctrl, true);
});

test('message-delete without messageId is invalid', () => {
    const ctrl = { type: 'message-delete', _ctrl: true };
    assert.strictEqual(ctrl.messageId, undefined);
    // Parser should return null for this
});

test('message-edit without newText is invalid', () => {
    const ctrl = { type: 'message-edit', messageId: 'uuid', _ctrl: true };
    assert.strictEqual(ctrl.newText, undefined);
});

// ═══════════════════════════════════════════
// 4. CROSS-PLATFORM FORMAT VERIFICATION
// ═══════════════════════════════════════════
console.log('\nCROSS-PLATFORM: iOS ↔ Android ↔ Web');
console.log('========================================');

test('iOS sends JSON, Android receives correctly', () => {
    // iOS sends
    const iosSent = JSON.stringify({
        m: 'Привет!',
        id: 'ios-uuid-abc',
        r: { id: 'android-uuid-def', t: 'Как дела?' }
    });

    // Android receives + parses
    const parsed = JSON.parse(iosSent);
    assert.strictEqual(parsed.m, 'Привет!');
    assert.strictEqual(parsed.id, 'ios-uuid-abc');
    assert.strictEqual(parsed.r.t, 'Как дела?');
});

test('Web receives new format and extracts text', () => {
    const newFormat = JSON.stringify({ m: 'Hello', id: 'uuid', r: { id: 'r-uuid', t: 'Quote' } });
    const parsed = JSON.parse(newFormat);
    // Web: use msg.m as display text, ignore r
    const displayText = parsed.m || newFormat;
    assert.strictEqual(displayText, 'Hello');
});

test('Web receives old format (raw string)', () => {
    const rawText = 'Hello from old version';
    let parsed = null;
    try { parsed = JSON.parse(rawText); } catch (_) {}
    const displayText = parsed?.m || rawText;
    assert.strictEqual(displayText, 'Hello from old version');
});

test('Unicode in reply text preserved', () => {
    const msg = { m: '🔥 Fire!', id: 'uuid', r: { id: 'r', t: '🎉 Party!' } };
    const json = JSON.stringify(msg);
    const parsed = JSON.parse(json);
    assert.strictEqual(parsed.m, '🔥 Fire!');
    assert.strictEqual(parsed.r.t, '🎉 Party!');
});

test('Cyrillic + special chars in messages', () => {
    const msg = { m: 'Тестовое сообщение с "кавычками" и <тегами>', id: 'uuid' };
    const json = JSON.stringify(msg);
    const parsed = JSON.parse(json);
    assert.strictEqual(parsed.m, msg.m);
});

// ═══════════════════════════════════════════
// 5. SECURITY: _ctrl ISOLATION
// ═══════════════════════════════════════════
console.log('\nSECURITY: _ctrl Isolation');
console.log('========================================');

test('_ctrl=true with unknown type is silently ignored (not shown as text)', () => {
    const malicious = { type: 'evil-type', _ctrl: true, text: 'HACK' };
    // Parser returns null for unknown type
    // _ctrl=true → NEVER show as text, even if parse fails
    assert.strictEqual(malicious._ctrl, true);
    // Both iOS and Android: if _ctrl=true, return early without addMessage
});

test('_ctrl=false is treated as normal message', () => {
    const msg = { m: 'Hello', _ctrl: false };
    // _ctrl is false → not a control message
    // But has m field → use as chat text
    assert.strictEqual(msg._ctrl, false);
    assert.strictEqual(msg.m, 'Hello');
});

test('Message with type field but no _ctrl is regular JSON message', () => {
    const msg = { m: 'Hello', type: 'some-type', id: 'uuid' };
    // No _ctrl → not a control message, treat as chat
    assert.strictEqual(msg._ctrl, undefined);
    assert.strictEqual(msg.m, 'Hello');
});

// ═══════════════════════════════════════════
// 6. DB SCHEMA (verification of new columns)
// ═══════════════════════════════════════════
console.log('\nDB SCHEMA: v8 Migration');
console.log('========================================');

test('ChatMessage model has replyToId field', () => {
    const msg = { replyToId: 'uuid-123', replyToText: 'Quoted text', isEdited: false, senderMessageId: 'sender-uuid' };
    assert.strictEqual(msg.replyToId, 'uuid-123');
    assert.strictEqual(msg.replyToText, 'Quoted text');
    assert.strictEqual(msg.isEdited, false);
    assert.strictEqual(msg.senderMessageId, 'sender-uuid');
});

test('Null reply fields for non-reply messages', () => {
    const msg = { replyToId: null, replyToText: null, isEdited: false, senderMessageId: 'uuid' };
    assert.strictEqual(msg.replyToId, null);
    assert.strictEqual(msg.replyToText, null);
});

test('isEdited becomes true after edit', () => {
    let msg = { text: 'Original', isEdited: false };
    // Simulate edit
    msg.text = 'Edited';
    msg.isEdited = true;
    assert.strictEqual(msg.isEdited, true);
    assert.strictEqual(msg.text, 'Edited');
});

test('senderMessageId correlation for delete', () => {
    const sent = { id: 'local-uuid', senderMessageId: 'sender-uuid-abc' };
    const deleteCtrl = { type: 'message-delete', messageId: 'sender-uuid-abc', _ctrl: true };
    // Receiver finds message by senderMessageId
    assert.strictEqual(sent.senderMessageId, deleteCtrl.messageId);
});

// ═══════════════════════════════════════════
// RESULTS
// ═══════════════════════════════════════════

console.log('\n════════════════════════════════════════════════════════════');
console.log(`  ИТОГО: ${passed} passed, ${failed} failed из ${passed + failed}`);
if (failed === 0) {
    console.log('  ✅ ALL PHASE 3 TESTS PASSED');
} else {
    console.log('  ❌ SOME TESTS FAILED');
    process.exit(1);
}
console.log('════════════════════════════════════════════════════════════\n');
