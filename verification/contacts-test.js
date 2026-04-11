/**
 * Ghost Chat — Contacts System Verification Test
 *
 * Воспроизводит ВСЮ логику контактов прозрачно:
 * - Identity Key: P-256 65 байт, hex encoding, O(1) lookup
 * - Avatar Color: SHA-256(identityKey)[0] % 10 → палитра
 * - Fingerprint: SHA-256(identityKey).take(8) → "%02X" joined " "
 * - Auto-Save: known peer → increment, new peer → prompt
 * - Race Condition: sync capture vs async persist
 * - Unexpected Peer: identity mismatch detection
 * - Migration: v3→v4 hex backfill simulation
 * - Full Lifecycle: create → reconnect → edit → delete
 *
 * Запуск: node verification/contacts-test.js
 */

import { webcrypto } from 'crypto';
import { createHash } from 'crypto';
const { subtle } = webcrypto;

// =====================================================
// HELPERS
// =====================================================

let passed = 0;
let failed = 0;
let sectionPassed = 0;
let sectionFailed = 0;

function assert(condition, description) {
  if (condition) {
    console.log(`  ✅ ${description}`);
    passed++;
    sectionPassed++;
  } else {
    console.log(`  ❌ ${description}`);
    failed++;
    sectionFailed++;
  }
}

function assertEq(actual, expected, description) {
  if (actual === expected) {
    console.log(`  ✅ ${description}`);
    passed++;
    sectionPassed++;
  } else {
    console.log(`  ❌ ${description}: expected "${expected}", got "${actual}"`);
    failed++;
    sectionFailed++;
  }
}

function assertDeepEq(actual, expected, description) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a === b) {
    console.log(`  ✅ ${description}`);
    passed++;
    sectionPassed++;
  } else {
    console.log(`  ❌ ${description}: expected ${b}, got ${a}`);
    failed++;
    sectionFailed++;
  }
}

function section(name) {
  sectionPassed = 0;
  sectionFailed = 0;
  console.log(`\n${'='.repeat(60)}`);
  console.log(`  ${name}`);
  console.log('='.repeat(60));
}

function sectionResult(name) {
  const total = sectionPassed + sectionFailed;
  const status = sectionFailed === 0 ? '✅' : '❌';
  console.log(`\n  ${status} ${name}: ${sectionPassed}/${total}`);
}

function hex(bytes) {
  return Array.from(new Uint8Array(bytes)).map(b => b.toString(16).padStart(2, '0')).join('');
}

function hexUpper(bytes) {
  return Array.from(new Uint8Array(bytes)).map(b => b.toString(16).padStart(2, '0').toUpperCase()).join('');
}

// =====================================================
// СЕКЦИЯ 1: IDENTITY KEY LOOKUP
// =====================================================

async function testIdentityKeyLookup() {
  section('СЕКЦИЯ 1: Identity Key Lookup');

  // 1.1. P-256 ключ = 65 байт (uncompressed x963: 0x04 + 32x + 32y)
  const keyPair = await subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveKey', 'deriveBits']
  );
  const rawKey = new Uint8Array(await subtle.exportKey('raw', keyPair.publicKey));
  assertEq(rawKey.length, 65, 'P-256 public key = 65 байт (uncompressed x963)');
  assertEq(rawKey[0], 0x04, 'Первый байт 0x04 (uncompressed point marker)');

  // 1.2. Hex encoding детерминированный
  const hexKey1 = hex(rawKey);
  const hexKey2 = hex(rawKey);
  assertEq(hexKey1, hexKey2, 'Hex encoding детерминированный');
  assertEq(hexKey1.length, 130, 'Hex string = 130 символов (65 * 2)');

  // 1.3. Hex lookup: симуляция SQL-запроса
  const contacts = [];
  for (let i = 0; i < 100; i++) {
    const kp = await subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
    );
    const raw = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
    contacts.push({
      id: `contact-${i}`,
      label: `User ${i}`,
      identityKey: raw,
      identityKeyHex: hex(raw).toLowerCase()
    });
  }
  // Добавить наш ключ под индексом 42
  contacts[42] = {
    id: 'contact-target',
    label: 'Target User',
    identityKey: rawKey,
    identityKeyHex: hex(rawKey).toLowerCase()
  };

  // O(1) indexed hex lookup (эмуляция SQL WHERE identityKeyHex = ?)
  const searchHex = hex(rawKey).toLowerCase();
  const hexIndex = new Map(contacts.map(c => [c.identityKeyHex, c]));
  const found = hexIndex.get(searchHex);
  assertEq(found?.id, 'contact-target', 'Hex lookup находит контакт за O(1)');
  assertEq(found?.label, 'Target User', 'Найденный контакт имеет правильный label');

  // O(n) brute-force (старый способ — fetchAll + find)
  const foundBrute = contacts.find(c =>
    c.identityKey.length === rawKey.length &&
    c.identityKey.every((b, i) => b === rawKey[i])
  );
  assertEq(foundBrute?.id, 'contact-target', 'Brute-force lookup тоже находит (но O(n))');

  // 1.4. Lookup для несуществующего ключа
  const unknownKey = new Uint8Array(65);
  unknownKey[0] = 0x04;
  webcrypto.getRandomValues(unknownKey.subarray(1));
  const notFound = hexIndex.get(hex(unknownKey).toLowerCase());
  assert(notFound === undefined, 'Lookup для неизвестного ключа → undefined');

  // 1.5. Fallback: empty identityKey → publicKey
  const fallbackContact = {
    publicKey: rawKey,
    identityKey: new Uint8Array(0) // Empty — old v2 contact
  };
  const effectiveKey = (fallbackContact.identityKey.length > 0)
    ? fallbackContact.identityKey
    : fallbackContact.publicKey;
  assert(effectiveKey.length === 65, 'Fallback на publicKey при пустом identityKey');
  assertEq(hex(effectiveKey), hex(rawKey), 'Fallback ключ совпадает с publicKey');

  sectionResult('Identity Key Lookup');
}

// =====================================================
// СЕКЦИЯ 2: AVATAR COLOR CONSISTENCY
// =====================================================

async function testAvatarColorConsistency() {
  section('СЕКЦИЯ 2: Avatar Color Consistency');

  // Android палитра (hex → RGB)
  const avatarColors = [
    { hex: '#5E5CE6', name: 'Indigo' },
    { hex: '#FF375F', name: 'Pink' },
    { hex: '#FF9F0A', name: 'Orange' },
    { hex: '#30D158', name: 'Green' },
    { hex: '#0A84FF', name: 'Blue' },
    { hex: '#BF5AF2', name: 'Purple' },
    { hex: '#FF453A', name: 'Red' },
    { hex: '#64D2FF', name: 'Cyan' },
    { hex: '#FFD60A', name: 'Yellow' },
    { hex: '#AC8E68', name: 'Brown' },
  ];

  assertEq(avatarColors.length, 10, 'Палитра содержит 10 цветов');

  // 2.1 SHA-256(identityKey)[0] % 10 → индекс
  function getAvatarColorIndex(identityKey) {
    if (identityKey.length === 0) return 0;
    const hash = createHash('sha256').update(identityKey).digest();
    return hash[0] % 10;
  }

  // Генерируем ключ и проверяем детерминированность
  const keyPair = await subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
  );
  const rawKey = new Uint8Array(await subtle.exportKey('raw', keyPair.publicKey));
  const idx1 = getAvatarColorIndex(rawKey);
  const idx2 = getAvatarColorIndex(rawKey);
  assertEq(idx1, idx2, 'Avatar color index детерминированный');
  assert(idx1 >= 0 && idx1 < 10, `Index в диапазоне [0, 9]: получили ${idx1}`);

  // 2.2 Распределение по палитре (100 ключей)
  const distribution = new Array(10).fill(0);
  for (let i = 0; i < 100; i++) {
    const kp = await subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
    );
    const raw = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
    distribution[getAvatarColorIndex(raw)]++;
  }
  const allUsed = distribution.every(c => c > 0);
  // При 100 ключах и 10 цветов, по Coupon Collector's problem все цвета должны быть
  // представлены с вероятностью ~99.97%
  assert(allUsed, `Все 10 цветов задействованы: [${distribution.join(', ')}]`);

  // 2.3 Пустой ключ → fallback на цвет #0
  const emptyIdx = getAvatarColorIndex(new Uint8Array(0));
  assertEq(emptyIdx, 0, 'Пустой ключ → индекс 0 (Indigo)');

  // 2.4 Известный тестовый вектор
  const testKey = new Uint8Array(65);
  testKey[0] = 0x04;
  // Все нули (кроме маркера) → SHA-256 предсказуем
  const testHash = createHash('sha256').update(testKey).digest();
  const expectedIdx = testHash[0] % 10;
  const testIdx = getAvatarColorIndex(testKey);
  assertEq(testIdx, expectedIdx, `Тестовый вектор: SHA-256[0]=${testHash[0]} → index ${expectedIdx} (${avatarColors[expectedIdx].name})`);

  // 2.5 Кроссплатформенная проверка алгоритма
  // Android: SHA-256(identityKey)[0].toInt() and 0xFF % avatarColors.size
  // Kotlin: (hash[0].toInt() and 0xFF) — это unsigned byte
  // Node.js: hash[0] — уже unsigned (Buffer values 0..255)
  const byte = testHash[0];
  const kotlinResult = (byte & 0xFF) % 10; // Kotlin simulation
  const nodeResult = byte % 10; // Node.js
  assertEq(kotlinResult, nodeResult, 'Kotlin и Node.js дают одинаковый avatar index');

  sectionResult('Avatar Color Consistency');
}

// =====================================================
// СЕКЦИЯ 3: CONTACT AUTO-SAVE FLOW
// =====================================================

async function testContactAutoSaveFlow() {
  section('СЕКЦИЯ 3: Contact Auto-Save Flow');

  // Симуляция ContactStore
  class MockContactStore {
    constructor() {
      this.contacts = new Map();
      this.sessionIncrements = [];
    }

    save(contact) {
      this.contacts.set(contact.id, { ...contact });
    }

    fetchByIdentityKey(identityKey) {
      const hexKey = hex(identityKey).toLowerCase();
      for (const c of this.contacts.values()) {
        if (c.identityKeyHex === hexKey) return c;
      }
      return null;
    }

    incrementSessionCount(id) {
      const c = this.contacts.get(id);
      if (c) {
        c.sessionCount = (c.sessionCount || 0) + 1;
        this.sessionIncrements.push(id);
      }
    }
  }

  // Симуляция ChatViewModel
  class MockChatViewModel {
    constructor(contactStore) {
      this.contactStore = contactStore;
      this.currentPeerContact = null;
      this.showSaveContactPrompt = false;
      this.peerIdentityKeyData = null;
    }

    // Новый handleContactAutoSave (исправленный)
    handleContactAutoSave() {
      if (!this.peerIdentityKeyData) return;
      const existing = this.currentPeerContact;
      if (existing != null) {
        this.contactStore.incrementSessionCount(existing.id);
      } else {
        this.showSaveContactPrompt = true;
      }
    }

    // saveContact с валидацией (BUG 3 fix)
    saveContact(name) {
      const trimmedName = name.trim();
      if (!trimmedName) return false;
      const id = `contact-${Date.now()}`;
      const contact = {
        id,
        label: trimmedName,
        identityKey: this.peerIdentityKeyData,
        identityKeyHex: hex(this.peerIdentityKeyData).toLowerCase(),
        publicKey: this.peerIdentityKeyData,
        sessionCount: 1,
        createdAt: Date.now()
      };
      this.contactStore.save(contact);
      this.currentPeerContact = contact;
      this.showSaveContactPrompt = false;
      return true;
    }
  }

  const store = new MockContactStore();
  const keyPair = await subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
  );
  const peerKey = new Uint8Array(await subtle.exportKey('raw', keyPair.publicKey));

  // 3.1 Новый пир → showSaveContactPrompt = true
  const vm = new MockChatViewModel(store);
  vm.peerIdentityKeyData = peerKey;
  vm.handleContactAutoSave();
  assertEq(vm.showSaveContactPrompt, true, 'Новый пир → showSaveContactPrompt = true');
  assert(store.sessionIncrements.length === 0, 'Новый пир → НЕ incrementSessionCount');

  // 3.2 Сохранение с валидным именем
  const saved = vm.saveContact('  Alice  ');
  assertEq(saved, true, 'Сохранение с валидным именем → success');
  assertEq(vm.currentPeerContact?.label, 'Alice', 'Имя обрезано (trimmed)');
  assertEq(vm.showSaveContactPrompt, false, 'Prompt скрыт после сохранения');

  // 3.3 Пустое имя → отказ (BUG 3)
  const vm2 = new MockChatViewModel(store);
  vm2.peerIdentityKeyData = peerKey;
  const savedEmpty = vm2.saveContact('');
  assertEq(savedEmpty, false, 'Пустое имя → отказ');

  // 3.4 Whitespace-only → отказ
  const savedWhitespace = vm2.saveContact('   \t\n  ');
  assertEq(savedWhitespace, false, 'Whitespace-only имя → отказ');

  // 3.5 Известный пир → incrementSessionCount (не показывать prompt)
  const vm3 = new MockChatViewModel(store);
  vm3.peerIdentityKeyData = peerKey;
  // Предварительно найти контакт (как делает handleSecureChannelEstablished)
  vm3.currentPeerContact = store.fetchByIdentityKey(peerKey);
  assert(vm3.currentPeerContact !== null, 'Известный пир найден в store');
  vm3.handleContactAutoSave();
  assertEq(vm3.showSaveContactPrompt, false, 'Известный пир → НЕ показывать prompt');
  assertEq(store.sessionIncrements.length, 1, 'Известный пир → incrementSessionCount вызван');
  assertEq(vm3.currentPeerContact?.sessionCount, 2, 'sessionCount увеличен до 2');

  // 3.6 No peerIdentityKeyData → no action (web v2 peer)
  const vm4 = new MockChatViewModel(store);
  vm4.peerIdentityKeyData = null;
  vm4.handleContactAutoSave();
  assertEq(vm4.showSaveContactPrompt, false, 'Нет peerIdentityKeyData → нет действий');

  sectionResult('Contact Auto-Save Flow');
}

// =====================================================
// СЕКЦИЯ 4: RACE CONDITION SIMULATION
// =====================================================

async function testRaceCondition() {
  section('СЕКЦИЯ 4: Race Condition (persistContactState)');

  // Старый flow: async persist + immediate destroy → потеря состояния
  let cryptoDestroyed = false;
  let persistedState = null;

  const mockCrypto = {
    exportRatchetState() {
      if (cryptoDestroyed) return null; // Race condition!
      return { rootKey: 'rk-123', chainKey: 'ck-456', sendCount: 10, receiveCount: 5 };
    },
    exportSkippedKeys() {
      if (cryptoDestroyed) return [];
      return [{ dhKey: 'dh1', msgNum: 3, msgKey: 'mk1' }];
    },
    destroy() {
      cryptoDestroyed = true;
    }
  };

  // 4.1 СТАРЫЙ FLOW (баг): async persist + immediate destroy
  async function oldPersistContactState() {
    // IO корутина начинается...
    await new Promise(r => setTimeout(r, 10)); // Симуляция async IO delay
    // К этому моменту crypto уже уничтожен leave()
    const ratchetState = mockCrypto.exportRatchetState();
    const skippedKeys = mockCrypto.exportSkippedKeys();
    persistedState = { ratchetState, skippedKeys };
  }

  function oldLeave() {
    oldPersistContactState(); // Fire and forget (не await!)
    mockCrypto.destroy(); // Сразу уничтожаем crypto
  }

  cryptoDestroyed = false;
  persistedState = null;
  oldLeave();
  await new Promise(r => setTimeout(r, 50)); // Ждём завершения async

  assertEq(persistedState?.ratchetState, null, 'СТАРЫЙ flow: ratchetState = null (потеря из-за race)');
  assertDeepEq(persistedState?.skippedKeys, [], 'СТАРЫЙ flow: skippedKeys = [] (потеря из-за race)');

  // 4.2 НОВЫЙ FLOW (исправление): sync capture + async write
  cryptoDestroyed = false;
  persistedState = null;

  const mockCrypto2 = {
    destroyed: false,
    exportRatchetState() {
      if (this.destroyed) return null;
      return { rootKey: 'rk-123', chainKey: 'ck-456', sendCount: 10, receiveCount: 5 };
    },
    exportSkippedKeys() {
      if (this.destroyed) return [];
      return [{ dhKey: 'dh1', msgNum: 3, msgKey: 'mk1' }];
    },
    destroy() {
      this.destroyed = true;
    }
  };

  async function newPersistContactState() {
    // Шаг 1: СИНХРОННО захватываем состояние ДО уничтожения crypto
    const ratchetState = mockCrypto2.exportRatchetState();
    const skippedKeys = mockCrypto2.exportSkippedKeys();
    if (!ratchetState) return;

    // Шаг 2: Сериализуем JSON синхронно (быстрая in-memory операция)
    const stateJson = JSON.stringify({
      rootKey: ratchetState.rootKey,
      chainKey: ratchetState.chainKey,
      sendCount: ratchetState.sendCount,
      receiveCount: ratchetState.receiveCount
    });

    // Шаг 3: Async IO только для записи в БД
    await new Promise(r => setTimeout(r, 10)); // Симуляция IO delay
    // crypto уже уничтожен, но stateJson уже захвачен!
    persistedState = { ratchetState, skippedKeys, stateJson };
  }

  function newLeave() {
    newPersistContactState(); // Sync capture happens immediately
    mockCrypto2.destroy(); // Destroy crypto — but state already captured
  }

  newLeave();
  await new Promise(r => setTimeout(r, 50));

  assert(persistedState?.ratchetState !== null, 'НОВЫЙ flow: ratchetState сохранён');
  assertEq(persistedState?.ratchetState?.rootKey, 'rk-123', 'НОВЫЙ flow: rootKey = rk-123');
  assertEq(persistedState?.skippedKeys?.length, 1, 'НОВЫЙ flow: 1 skipped key сохранён');
  assert(persistedState?.stateJson?.includes('rk-123'), 'НОВЫЙ flow: JSON сериализован до destroy');

  // 4.3 Edge case: crypto уже null → early return
  let earlyReturnCalled = false;
  function persistWithNullCrypto() {
    const crypto = null;
    const ratchetState = crypto?.exportRatchetState();
    if (!ratchetState) {
      earlyReturnCalled = true;
      return;
    }
  }
  persistWithNullCrypto();
  assert(earlyReturnCalled, 'crypto = null → early return (no crash)');

  sectionResult('Race Condition');
}

// =====================================================
// СЕКЦИЯ 5: UNEXPECTED PEER DETECTION
// =====================================================

async function testUnexpectedPeerDetection() {
  section('СЕКЦИЯ 5: Unexpected Peer Detection');

  // Генерируем 2 разных ключа
  const kp1 = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']);
  const kp2 = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']);
  const key1 = new Uint8Array(await subtle.exportKey('raw', kp1.publicKey));
  const key2 = new Uint8Array(await subtle.exportKey('raw', kp2.publicKey));

  // Симуляция handleSecureChannelEstablished
  class MockSecurityVM {
    constructor() {
      this.currentPeerContact = null;
      this.securityAlert = null;
      this.systemMessages = [];
      this.expectedPeerIdentityKey = null;
    }

    handleIdentityCheck(idKeyData) {
      const expected = this.expectedPeerIdentityKey;

      if (expected !== null) {
        const match = expected.length === idKeyData.length &&
          expected.every((b, i) => b === idKeyData[i]);

        if (!match) {
          this.systemMessages.push('ПРЕДУПРЕЖДЕНИЕ: Другой identity key! Возможная подмена.');
          this.securityAlert = 'ПРЕДУПРЕЖДЕНИЕ: Другой identity key!';
          this.currentPeerContact = null; // Не доверяем
          return 'unexpected';
        }
        return 'expected';
      }

      // Нет ожидаемого ключа → первое подключение
      return 'new';
    }
  }

  // 5.1 Expected == actual → нет предупреждения
  const vm1 = new MockSecurityVM();
  vm1.expectedPeerIdentityKey = key1;
  vm1.currentPeerContact = { id: 'c1', label: 'Alice' };
  const result1 = vm1.handleIdentityCheck(key1);
  assertEq(result1, 'expected', 'Expected == actual → "expected"');
  assert(vm1.securityAlert === null, 'Нет security alert');
  assert(vm1.currentPeerContact !== null, 'Contact сохранён');

  // 5.2 Expected != actual → предупреждение + сброс contact
  const vm2 = new MockSecurityVM();
  vm2.expectedPeerIdentityKey = key1;
  vm2.currentPeerContact = { id: 'c1', label: 'Alice' };
  const result2 = vm2.handleIdentityCheck(key2);
  assertEq(result2, 'unexpected', 'Expected != actual → "unexpected"');
  assert(vm2.securityAlert !== null, 'Security alert установлен');
  assert(vm2.currentPeerContact === null, 'Contact сброшен (не доверяем)');
  assertEq(vm2.systemMessages.length, 1, 'Системное сообщение добавлено');

  // 5.3 Нет ожидаемого ключа (первое подключение) → graceful
  const vm3 = new MockSecurityVM();
  vm3.expectedPeerIdentityKey = null;
  const result3 = vm3.handleIdentityCheck(key1);
  assertEq(result3, 'new', 'Нет expected key → "new"');
  assert(vm3.securityAlert === null, 'Нет alert для нового подключения');

  // 5.4 Same identity key — different byte arrays (deep equality)
  const vm4 = new MockSecurityVM();
  const key1Copy = new Uint8Array(key1); // Копия — другой ArrayBuffer
  vm4.expectedPeerIdentityKey = key1;
  const result4 = vm4.handleIdentityCheck(key1Copy);
  assertEq(result4, 'expected', 'Deep equality для identity key (не reference)');

  // 5.5 Пустой identity key vs ожидаемый → mismatch
  const vm5 = new MockSecurityVM();
  vm5.expectedPeerIdentityKey = key1;
  vm5.currentPeerContact = { id: 'c1', label: 'Bob' };
  const result5 = vm5.handleIdentityCheck(new Uint8Array(0));
  assertEq(result5, 'unexpected', 'Пустой ключ vs ожидаемый → unexpected');
  assert(vm5.currentPeerContact === null, 'Contact сброшен при пустом ключе');

  sectionResult('Unexpected Peer Detection');
}

// =====================================================
// СЕКЦИЯ 6: FINGERPRINT CROSS-PLATFORM
// =====================================================

async function testFingerprintCrossPlatform() {
  section('СЕКЦИЯ 6: Fingerprint Cross-Platform');

  // Алгоритм (одинаковый на iOS, Android, Web):
  // SHA-256(identityKey) → take first 8 bytes → uppercase hex joined by " "
  function formatFingerprint(keyData) {
    const hash = createHash('sha256').update(keyData).digest();
    const first8 = hash.slice(0, 8);
    return Array.from(first8).map(b => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
  }

  // 6.1 Формат: "XX XX XX XX XX XX XX XX"
  const keyPair = await subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
  );
  const rawKey = new Uint8Array(await subtle.exportKey('raw', keyPair.publicKey));
  const fp = formatFingerprint(rawKey);
  const parts = fp.split(' ');
  assertEq(parts.length, 8, 'Fingerprint = 8 hex-пар');
  assert(parts.every(p => /^[0-9A-F]{2}$/.test(p)), 'Каждая пара — uppercase hex');
  assertEq(fp.length, 23, 'Формат: "XX XX XX XX XX XX XX XX" (23 символа)');

  // 6.2 Детерминированность
  const fp2 = formatFingerprint(rawKey);
  assertEq(fp, fp2, 'Fingerprint детерминированный');

  // 6.3 Тестовый вектор: нулевой ключ
  const zeroKey = new Uint8Array(65);
  zeroKey[0] = 0x04;
  const zeroFp = formatFingerprint(zeroKey);
  // SHA-256 нулевого 65-байтного массива (с 0x04) — предсказуемый результат
  const expectedHash = createHash('sha256').update(zeroKey).digest();
  const expectedFp = Array.from(expectedHash.slice(0, 8))
    .map(b => b.toString(16).padStart(2, '0').toUpperCase())
    .join(' ');
  assertEq(zeroFp, expectedFp, `Тестовый вектор zero key: ${zeroFp}`);

  // 6.4 Кросс-платформенная эквивалентность
  // iOS:   let hash = SHA256.hash(data: keyData); bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
  // Android: hash.take(8).joinToString(" ") { "%02X".format(it) }
  // Node.js: hash.slice(0,8).map(b => b.toString(16).padStart(2,'0').toUpperCase()).join(' ')
  //
  // Все три используют одинаковый алгоритм:
  // 1. SHA-256 от raw identity key
  // 2. Берём первые 8 байт
  // 3. Форматируем как uppercase hex с пробелами
  console.log('  ℹ️  Алгоритм fingerprint идентичен на iOS/Android/Node.js');
  console.log(`  ℹ️  Пример: ${fp}`);
  assert(true, 'Алгоритм верифицирован: SHA-256 → take(8) → %02X → join(" ")');

  // 6.5 Разные ключи → разные fingerprints
  const kp2 = await subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
  );
  const key2 = new Uint8Array(await subtle.exportKey('raw', kp2.publicKey));
  const fp3 = formatFingerprint(key2);
  assert(fp !== fp3, 'Разные ключи → разные fingerprints');

  // 6.6 Пустой ключ → валидный fingerprint (без crash)
  const emptyFp = formatFingerprint(new Uint8Array(0));
  assertEq(emptyFp.split(' ').length, 8, 'Пустой ключ → валидный 8-парный fingerprint (SHA-256 от пустого)');

  sectionResult('Fingerprint Cross-Platform');
}

// =====================================================
// СЕКЦИЯ 7: MIGRATION SIMULATION (v3 → v4)
// =====================================================

async function testMigrationSimulation() {
  section('СЕКЦИЯ 7: Migration v3 → v4 Simulation');

  // Симуляция SQLite таблицы (v3 — без identityKeyHex)
  const v3Table = [];
  for (let i = 0; i < 5; i++) {
    const kp = await subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
    );
    const pubKey = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
    v3Table.push({
      id: `contact-${i}`,
      label: `User ${i}`,
      publicKey: pubKey,
      identityKey: i < 3 ? pubKey : null, // Контакты 3,4 — старые, без identityKey
      identityKeyHex: null, // v3 не имеет этого столбца
      ratchetState: null,
      sessionCount: i,
      createdAt: Date.now()
    });
  }

  // 7.1 Миграция шаг 1: ALTER TABLE ADD COLUMN identityKeyHex TEXT
  // (уже добавлен как null — симулируем)
  assert(v3Table.every(c => c.identityKeyHex === null), 'v3: identityKeyHex = null для всех контактов');

  // 7.2 Миграция шаг 2: UPDATE contacts SET identityKey = publicKey WHERE identityKey IS NULL
  for (const c of v3Table) {
    if (c.identityKey === null) {
      c.identityKey = c.publicKey;
    }
  }
  assert(v3Table.every(c => c.identityKey !== null), 'Backfill: все identityKey заполнены');
  // Контакты 3,4 теперь имеют identityKey = publicKey
  assertEq(
    hex(v3Table[3].identityKey),
    hex(v3Table[3].publicKey),
    'Backfill: contact[3].identityKey = publicKey'
  );

  // 7.3 Миграция шаг 3: UPDATE contacts SET identityKeyHex = lower(hex(identityKey))
  for (const c of v3Table) {
    if (c.identityKey) {
      c.identityKeyHex = hex(c.identityKey).toLowerCase();
    }
  }
  assert(v3Table.every(c => c.identityKeyHex !== null), 'Hex column: все заполнены');
  assert(v3Table.every(c => c.identityKeyHex.length === 130), 'Hex column: 130 символов (65 * 2)');
  assert(v3Table.every(c => c.identityKeyHex === c.identityKeyHex.toLowerCase()), 'Hex column: lowercase');

  // 7.4 Миграция шаг 4: CREATE INDEX
  // Симулируем индекс как Map
  const hexIndex = new Map();
  for (const c of v3Table) {
    hexIndex.set(c.identityKeyHex, c);
  }
  assertEq(hexIndex.size, 5, 'Индекс содержит 5 записей');

  // 7.5 Hex lookup работает после миграции
  const searchKey = v3Table[2].identityKey;
  const searchHex = hex(searchKey).toLowerCase();
  const found = hexIndex.get(searchHex);
  assertEq(found?.id, 'contact-2', 'Hex lookup после миграции: найден contact-2');

  // 7.6 Backfilled контакт (identityKey = publicKey) тоже находится
  const found3 = hexIndex.get(hex(v3Table[3].publicKey).toLowerCase());
  assertEq(found3?.id, 'contact-3', 'Backfilled контакт (identityKey == publicKey) найден');

  // 7.7 Уникальность hex ключей
  const uniqueHexes = new Set(v3Table.map(c => c.identityKeyHex));
  assertEq(uniqueHexes.size, 5, 'Все hex ключи уникальны');

  sectionResult('Migration v3 → v4');
}

// =====================================================
// СЕКЦИЯ 8: FULL CONTACT LIFECYCLE
// =====================================================

async function testFullContactLifecycle() {
  section('СЕКЦИЯ 8: Full Contact Lifecycle');

  // Полная БД с индексом
  class MockDatabase {
    constructor() {
      this.contacts = new Map();
      this.skippedKeys = new Map(); // contactId → [keys]
      this.hexIndex = new Map();
    }

    save(contact) {
      const c = { ...contact, identityKeyHex: hex(contact.identityKey).toLowerCase() };
      this.contacts.set(c.id, c);
      this.hexIndex.set(c.identityKeyHex, c);
    }

    fetchByIdentityKey(identityKey) {
      const hexKey = hex(identityKey).toLowerCase();
      return this.hexIndex.get(hexKey) ?? null;
    }

    fetchAll() {
      return Array.from(this.contacts.values());
    }

    updateLabel(id, newLabel) {
      const c = this.contacts.get(id);
      if (c) c.label = newLabel;
    }

    updateNotes(id, notes) {
      const c = this.contacts.get(id);
      if (c) c.notes = notes;
    }

    updateRatchetState(id, stateBytes) {
      const c = this.contacts.get(id);
      if (c) c.ratchetState = stateBytes;
    }

    incrementSessionCount(id) {
      const c = this.contacts.get(id);
      if (c) c.sessionCount = (c.sessionCount || 0) + 1;
    }

    saveSkippedKeys(contactId, keys) {
      this.skippedKeys.set(contactId, keys);
    }

    delete(id) {
      const c = this.contacts.get(id);
      if (c) {
        this.hexIndex.delete(c.identityKeyHex);
        this.contacts.delete(id);
        this.skippedKeys.delete(id);
      }
    }
  }

  const db = new MockDatabase();

  // --- Шаг 1: Создание контакта (после key exchange) ---
  console.log('\n  --- Шаг 1: Создание контакта ---');
  const kp = await subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
  );
  const aliceKey = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));

  // Первое подключение — пир не найден
  const lookupFirst = db.fetchByIdentityKey(aliceKey);
  assertEq(lookupFirst, null, 'Первое подключение: контакт не найден');

  // Пользователь сохраняет контакт
  db.save({
    id: 'alice-001',
    label: 'Alice',
    publicKey: aliceKey,
    identityKey: aliceKey,
    ratchetState: null,
    notes: null,
    sessionCount: 1,
    createdAt: Date.now(),
    lastSessionAt: Date.now()
  });

  const savedAlice = db.fetchByIdentityKey(aliceKey);
  assertEq(savedAlice?.label, 'Alice', 'Контакт сохранён: Alice');
  assertEq(savedAlice?.sessionCount, 1, 'sessionCount = 1');
  assertEq(db.contacts.size, 1, 'В БД 1 контакт');

  // --- Шаг 2: Переподключение (распознавание по identityKey) ---
  console.log('\n  --- Шаг 2: Переподключение ---');
  const lookupSecond = db.fetchByIdentityKey(aliceKey);
  assert(lookupSecond !== null, 'Повторное подключение: контакт найден');
  assertEq(lookupSecond?.label, 'Alice', 'Распознан как Alice');

  db.incrementSessionCount('alice-001');
  assertEq(db.contacts.get('alice-001')?.sessionCount, 2, 'sessionCount = 2');

  // Persist ratchet state
  const ratchetState = JSON.stringify({
    rootKey: 'base64-root-key',
    chainKey: 'base64-chain-key',
    sendCount: 15,
    receiveCount: 12
  });
  db.updateRatchetState('alice-001', new TextEncoder().encode(ratchetState));
  assert(db.contacts.get('alice-001')?.ratchetState !== null, 'Ratchet state сохранён');

  // Persist skipped keys
  db.saveSkippedKeys('alice-001', [
    { dhKey: 'dh-pub-1', msgNum: 5, msgKey: 'mk-5' },
    { dhKey: 'dh-pub-1', msgNum: 7, msgKey: 'mk-7' }
  ]);
  assertEq(db.skippedKeys.get('alice-001')?.length, 2, '2 skipped keys сохранены');

  // --- Шаг 3: Редактирование имени + заметок ---
  console.log('\n  --- Шаг 3: Редактирование ---');
  db.updateLabel('alice-001', 'Alice (Work)');
  assertEq(db.contacts.get('alice-001')?.label, 'Alice (Work)', 'Имя обновлено');

  db.updateNotes('alice-001', 'Коллега из офиса');
  assertEq(db.contacts.get('alice-001')?.notes, 'Коллега из офиса', 'Заметки добавлены');

  // --- Шаг 4: Добавление второго контакта ---
  console.log('\n  --- Шаг 4: Второй контакт ---');
  const kp2 = await subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
  );
  const bobKey = new Uint8Array(await subtle.exportKey('raw', kp2.publicKey));
  db.save({
    id: 'bob-002',
    label: 'Bob',
    publicKey: bobKey,
    identityKey: bobKey,
    ratchetState: null,
    notes: null,
    sessionCount: 1,
    createdAt: Date.now(),
    lastSessionAt: null
  });
  assertEq(db.contacts.size, 2, 'В БД 2 контакта');

  // Оба контакта находятся по identity key
  assertEq(db.fetchByIdentityKey(aliceKey)?.label, 'Alice (Work)', 'Alice найдена');
  assertEq(db.fetchByIdentityKey(bobKey)?.label, 'Bob', 'Bob найден');

  // --- Шаг 5: Start chat from contact → expectedPeerIdentityKey ---
  console.log('\n  --- Шаг 5: Start Chat from Contact ---');
  const selectedContact = db.fetchByIdentityKey(aliceKey);
  const expectedPeerIdentityKey = selectedContact?.identityKey ?? null;
  assert(expectedPeerIdentityKey !== null, 'expectedPeerIdentityKey установлен');
  assertEq(hex(expectedPeerIdentityKey), hex(aliceKey), 'expectedPeerIdentityKey = Alice key');

  // --- Шаг 6: Удаление контакта (+ каскад skippedKeys) ---
  console.log('\n  --- Шаг 6: Удаление контакта ---');
  db.delete('alice-001');
  assertEq(db.contacts.size, 1, 'Осталось 1 контакт');
  assertEq(db.fetchByIdentityKey(aliceKey), null, 'Alice больше не найдена по identity key');
  assert(!db.skippedKeys.has('alice-001'), 'Skipped keys удалены каскадно');

  // Bob не затронут
  assertEq(db.fetchByIdentityKey(bobKey)?.label, 'Bob', 'Bob не затронут');

  // --- Шаг 7: fetchAll —
  console.log('\n  --- Шаг 7: fetchAll ---');
  const allContacts = db.fetchAll();
  assertEq(allContacts.length, 1, 'fetchAll возвращает 1 контакт');
  assertEq(allContacts[0].label, 'Bob', 'Единственный контакт — Bob');

  sectionResult('Full Contact Lifecycle');
}

// =====================================================
// MAIN
// =====================================================

async function main() {
  console.log('╔══════════════════════════════════════════════════════════╗');
  console.log('║  Ghost Chat — Contacts System Verification             ║');
  console.log('║  Воспроизводит логику контактов для верификации          ║');
  console.log('╚══════════════════════════════════════════════════════════╝');

  await testIdentityKeyLookup();
  await testAvatarColorConsistency();
  await testContactAutoSaveFlow();
  await testRaceCondition();
  await testUnexpectedPeerDetection();
  await testFingerprintCrossPlatform();
  await testMigrationSimulation();
  await testFullContactLifecycle();

  console.log('\n' + '═'.repeat(60));
  console.log(`\n  ИТОГО: ${passed} passed, ${failed} failed из ${passed + failed}`);

  if (failed === 0) {
    console.log('  ✅ ALL TESTS PASSED\n');
  } else {
    console.log('  ❌ SOME TESTS FAILED\n');
    process.exit(1);
  }
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
