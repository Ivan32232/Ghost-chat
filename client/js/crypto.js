/**
 * Ghost Chat - Криптографический модуль
 *
 * Использует Web Crypto API для:
 * - ECDH (P-256) для обмена ключами
 * - AES-GCM (256-bit) для шифрования сообщений
 * - HKDF для деривации ключей
 * - Двунаправленные ключи для корректного PFS
 *
 * ВСЕ КЛЮЧИ ХРАНЯТСЯ ТОЛЬКО В ПАМЯТИ!
 */

import { logger } from './logger.js';

export class GhostCrypto {
  constructor() {
    this.keyPair = null;        // Наша пара ключей ECDH
    this.peerPublicKey = null;  // Публичный ключ собеседника

    // Двунаправленные ключи для корректного PFS
    // Каждое направление ротируется независимо
    this.sendKey = null;        // Ключ для шифрования исходящих
    this.receiveKey = null;     // Ключ для дешифрования входящих

    this.messageCounter = 0;    // Счётчик исходящих сообщений
    this.peerMessageCounter = 0; // Счётчик входящих сообщений
    this.receivedNonces = new Map(); // nonce -> timestamp для проверки дубликатов
    this.NONCE_EXPIRY_MS = 5 * 60 * 1000;
    this.COUNTER_WINDOW = 100;

    // Perfect Forward Secrecy - ротация ключей
    this.sendKeyRotations = 0;
    this.receiveKeyRotations = 0;
    this.KEY_ROTATION_INTERVAL = 50;
    this.previousReceiveKeys = [];
    this.MAX_PREVIOUS_KEYS = 2;
  }

  /**
   * Генерация пары ключей ECDH
   */
  async generateKeyPair() {
    this.keyPair = await crypto.subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' },
      true,
      ['deriveKey', 'deriveBits']
    );
    return this.keyPair;
  }

  /**
   * Экспорт публичного ключа для отправки собеседнику
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
    this.peerPublicKey = await crypto.subtle.importKey(
      'raw', keyData,
      { name: 'ECDH', namedCurve: 'P-256' },
      true, []
    );
    return this.peerPublicKey;
  }

  /**
   * Деривация двунаправленных ключей AES-GCM из ECDH
   * Создаёт отдельные ключи для отправки и получения для корректного PFS
   */
  async deriveSharedKey() {
    if (!this.keyPair || !this.peerPublicKey) {
      throw new Error('Keys not ready for derivation');
    }

    // Получаем общий секрет через ECDH
    const sharedBits = await crypto.subtle.deriveBits(
      { name: 'ECDH', public: this.peerPublicKey },
      this.keyPair.privateKey,
      256
    );

    // Импортируем как ключ для HKDF
    const sharedSecret = await crypto.subtle.importKey(
      'raw', sharedBits, 'HKDF', false, ['deriveKey']
    );

    // Определяем порядок ключей детерминистически по публичным ключам
    const ourKeyRaw = new Uint8Array(await crypto.subtle.exportKey('raw', this.keyPair.publicKey));
    const peerKeyRaw = new Uint8Array(await crypto.subtle.exportKey('raw', this.peerPublicKey));

    let weAreFirst = false;
    for (let i = 0; i < ourKeyRaw.length; i++) {
      if (ourKeyRaw[i] < peerKeyRaw[i]) { weAreFirst = true; break; }
      if (ourKeyRaw[i] > peerKeyRaw[i]) { weAreFirst = false; break; }
    }

    // Деривируем два направленных ключа
    const keyFirstToSecond = await this._deriveDirectionalKey(sharedSecret, 'ghost-first-to-second');
    const keySecondToFirst = await this._deriveDirectionalKey(sharedSecret, 'ghost-second-to-first');

    this.sendKey = weAreFirst ? keyFirstToSecond : keySecondToFirst;
    this.receiveKey = weAreFirst ? keySecondToFirst : keyFirstToSecond;

    return this.sendKey;
  }

  /**
   * Деривация направленного ключа
   */
  async _deriveDirectionalKey(sharedSecret, direction) {
    return await crypto.subtle.deriveKey(
      {
        name: 'HKDF',
        hash: 'SHA-256',
        salt: new TextEncoder().encode('ghost-chat-v1'),
        info: new TextEncoder().encode(direction)
      },
      sharedSecret,
      { name: 'AES-GCM', length: 256 },
      true,
      ['encrypt', 'decrypt']
    );
  }

  /**
   * Padding сообщения до фиксированного размера
   * Скрывает реальную длину сообщения от traffic analysis
   * Использует crypto.getRandomValues() для криптостойкого padding
   */
  padMessage(message, blockSize = 256) {
    const base64Message = this.textToBase64(message);
    const messageLength = base64Message.length;

    // Валидация длины (4 символа на префикс длины)
    if (messageLength > 9999) {
      throw new Error('Message too long');
    }

    // Вычисляем нужный размер (кратный blockSize)
    const paddedLength = Math.ceil((messageLength + 4) / blockSize) * blockSize;
    const paddingLength = paddedLength - messageLength - 4;

    // Криптостойкий случайный padding
    const paddingChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const randomBytes = crypto.getRandomValues(new Uint8Array(paddingLength));
    let padding = '';
    for (let i = 0; i < paddingLength; i++) {
      padding += paddingChars[randomBytes[i] % paddingChars.length];
    }

    // Формат: длина_base64(4 символа) + base64_сообщение + padding
    const lengthPrefix = messageLength.toString().padStart(4, '0');
    return lengthPrefix + base64Message + padding;
  }

  /**
   * Удаление padding из сообщения
   */
  unpadMessage(paddedMessage) {
    const originalLength = parseInt(paddedMessage.substring(0, 4), 10);
    if (isNaN(originalLength) || originalLength < 0 || originalLength > paddedMessage.length - 4) {
      throw new Error('Invalid padded message format');
    }
    const base64Message = paddedMessage.substring(4, 4 + originalLength);
    return this.base64ToText(base64Message);
  }

  /**
   * Шифрование сообщения с использованием sendKey
   * PFS ротация происходит ПОСЛЕ шифрования
   */
  async encrypt(plaintext) {
    if (!this.sendKey) {
      throw new Error('Send key not derived');
    }

    // Увеличиваем счётчик
    this.messageCounter++;

    // Уникальный IV для каждого сообщения (12 байт для GCM)
    const iv = crypto.getRandomValues(new Uint8Array(12));

    // Добавляем timestamp и counter к сообщению для защиты от replay
    const messageWithMeta = JSON.stringify({
      m: plaintext,
      t: Date.now(),
      c: this.messageCounter
    });

    // Применяем padding для защиты от traffic analysis
    const paddedMessage = this.padMessage(messageWithMeta);
    const encodedMessage = new TextEncoder().encode(paddedMessage);

    const ciphertext = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: iv, tagLength: 128 },
      this.sendKey,
      encodedMessage
    );

    // Возвращаем IV + ciphertext в base64
    const combined = new Uint8Array(iv.length + ciphertext.byteLength);
    combined.set(iv);
    combined.set(new Uint8Array(ciphertext), iv.length);

    // PFS: ротация ПОСЛЕ шифрования (сообщение зашифровано старым ключом)
    if (this.messageCounter % this.KEY_ROTATION_INTERVAL === 0) {
      await this._rotateSendKey();
    }

    return this.arrayBufferToBase64(combined.buffer);
  }

  /**
   * Дешифрование сообщения с проверкой replay атак
   * Пробует текущий receiveKey, при неудаче — предыдущие ключи
   * PFS ротация receiveKey синхронизируется по счётчику отправителя
   */
  async decrypt(encryptedBase64) {
    if (!this.receiveKey) {
      throw new Error('Receive key not derived');
    }

    const combined = this.base64ToArrayBuffer(encryptedBase64);
    const combinedArray = new Uint8Array(combined);

    // Извлекаем IV (первые 12 байт)
    const iv = combinedArray.slice(0, 12);
    const ciphertext = combinedArray.slice(12);

    // Создаём nonce из IV для проверки replay
    const nonce = this.arrayBufferToBase64(iv.buffer);

    // Очищаем истёкшие nonces перед проверкой
    this.cleanupExpiredNonces();

    if (this.receivedNonces.has(nonce)) {
      throw new Error('Replay attack detected: duplicate nonce');
    }

    // Попытка дешифрования текущим ключом, затем предыдущими
    const decryptParams = { name: 'AES-GCM', iv: iv, tagLength: 128 };
    let decrypted = null;

    try {
      decrypted = await crypto.subtle.decrypt(decryptParams, this.receiveKey, ciphertext);
    } catch {
      // Пробуем предыдущие ключи (от новых к старым)
      for (let i = this.previousReceiveKeys.length - 1; i >= 0; i--) {
        try {
          decrypted = await crypto.subtle.decrypt(decryptParams, this.previousReceiveKeys[i], ciphertext);
          break;
        } catch { continue; }
      }
    }

    if (!decrypted) {
      throw new Error('Decryption failed');
    }

    const decryptedText = new TextDecoder().decode(decrypted);

    // Удаляем padding
    const unpaddedText = this.unpadMessage(decryptedText);

    // Парсим метаданные
    try {
      const parsed = JSON.parse(unpaddedText);

      // Проверяем timestamp (не старше 5 минут)
      const MESSAGE_MAX_AGE = 5 * 60 * 1000;
      if (Date.now() - parsed.t > MESSAGE_MAX_AGE) {
        throw new Error('Message too old, possible replay attack');
      }

      // Проверяем counter
      if (typeof parsed.c === 'number') {
        if (parsed.c <= this.peerMessageCounter - this.COUNTER_WINDOW) {
          throw new Error('Message counter too old, possible replay attack');
        }
        if (parsed.c > this.peerMessageCounter) {
          this.peerMessageCounter = parsed.c;
        }
      }

      // Сохраняем nonce с timestamp для защиты от повторов
      this.receivedNonces.set(nonce, Date.now());

      // PFS: ротация receiveKey когда счётчик отправителя пересекает порог
      // Отправитель ротирует sendKey ПОСЛЕ шифрования сообщения #N (кратного интервалу)
      // Значит следующее сообщение (#N+1) будет зашифровано новым ключом
      // Получатель ротирует receiveKey после получения сообщения #N
      if (parsed.c > 0 && parsed.c % this.KEY_ROTATION_INTERVAL === 0) {
        await this._rotateReceiveKey();
      }

      return parsed.m;
    } catch (e) {
      if (e.message && e.message.includes('attack')) {
        throw e;
      }
      return unpaddedText;
    }
  }

  /**
   * Генерация fingerprint ключа для верификации
   */
  async generateFingerprint() {
    if (!this.keyPair || !this.peerPublicKey) {
      throw new Error('Keys not ready');
    }

    const ourKey = await crypto.subtle.exportKey('raw', this.keyPair.publicKey);
    const peerKey = await crypto.subtle.exportKey('raw', this.peerPublicKey);

    // Сортируем для консистентности
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
   * Очистка истёкших nonces (старше 5 минут)
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
   * Безопасная перезапись ArrayBuffer нулями
   */
  secureWipe(buffer) {
    if (buffer instanceof ArrayBuffer) {
      const view = new Uint8Array(buffer);
      crypto.getRandomValues(view);
      view.fill(0);
    }
  }

  /**
   * PFS: ротация ключа отправки
   */
  async _rotateSendKey() {
    const oldKeyMaterial = await crypto.subtle.exportKey('raw', this.sendKey);
    this.sendKey = await this._rotateKeyInternal(oldKeyMaterial);
    this.secureWipe(oldKeyMaterial);
    this.sendKeyRotations++;
    logger.log(`Send key rotated (PFS #${this.sendKeyRotations})`);
  }

  /**
   * PFS: ротация ключа приёма
   * Сохраняет предыдущие ключи для расшифровки out-of-order сообщений
   */
  async _rotateReceiveKey() {
    this.previousReceiveKeys.push(this.receiveKey);
    if (this.previousReceiveKeys.length > this.MAX_PREVIOUS_KEYS) {
      this.previousReceiveKeys.shift();
    }
    const oldKeyMaterial = await crypto.subtle.exportKey('raw', this.receiveKey);
    this.receiveKey = await this._rotateKeyInternal(oldKeyMaterial);
    this.secureWipe(oldKeyMaterial);
    this.receiveKeyRotations++;
    logger.log(`Receive key rotated (PFS #${this.receiveKeyRotations})`);
  }

  /**
   * Общая логика ротации: SHA-256(старый ключ) → HKDF → новый AES-GCM ключ
   */
  async _rotateKeyInternal(keyMaterial) {
    const newKeyMaterial = await crypto.subtle.digest('SHA-256', keyMaterial);

    const importedKey = await crypto.subtle.importKey(
      'raw', newKeyMaterial, 'HKDF', false, ['deriveKey']
    );

    return await crypto.subtle.deriveKey(
      {
        name: 'HKDF',
        hash: 'SHA-256',
        salt: new TextEncoder().encode('ghost-pfs-rotation'),
        info: new TextEncoder().encode('key-rotation')
      },
      importedKey,
      { name: 'AES-GCM', length: 256 },
      true,
      ['encrypt', 'decrypt']
    );
  }

  /**
   * Полная очистка всех ключей из памяти
   */
  destroy() {
    if (this.receivedNonces) {
      this.receivedNonces.clear();
      this.receivedNonces = null;
    }

    // Обнуляем все ключи
    this.sendKey = null;
    this.receiveKey = null;
    this.keyPair = null;
    this.peerPublicKey = null;

    if (this.previousReceiveKeys) {
      this.previousReceiveKeys.length = 0;
      this.previousReceiveKeys = null;
    }

    this.messageCounter = 0;
    this.peerMessageCounter = 0;
    this.sendKeyRotations = 0;
    this.receiveKeyRotations = 0;

    logger.log('Crypto keys destroyed');
  }

  /**
   * Проверка целостности ключей
   */
  isReady() {
    return this.keyPair !== null &&
           this.sendKey !== null &&
           this.receiveKey !== null &&
           this.peerPublicKey !== null;
  }

  // === Утилиты для конвертации ===

  /**
   * UTF-8 safe base64 encoding (заменяет deprecated unescape/escape)
   */
  textToBase64(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  /**
   * UTF-8 safe base64 decoding
   */
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
