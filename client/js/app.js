/**
 * Ghost Chat - Main Application
 *
 * Связывает все модули воедино:
 * - WebSocket для signaling
 * - WebRTC для P2P соединения
 * - Crypto для E2E шифрования
 */

import { GhostCrypto } from './crypto.js';
import { GhostRTC } from './webrtc.js';
import { GhostVoice } from './voice.js';
import { logger } from './logger.js';

class GhostChat {
  constructor() {
    this.ws = null;
    this.rtc = null;
    this.crypto = null;
    this.roomId = null;
    this.isHost = false;
    this.isConnected = false;
    this.pendingIceCandidates = [];
    this.guestInitPromise = null; // Promise for guest initialization (race condition fix)

    // Voice call state
    this.voice = null;
    this.callState = 'idle'; // idle, calling, ringing, active
    this.pendingRenegotiationOffer = null; // Store offer while waiting for user to accept call

    // Remote audio output (iOS earpiece/speaker switching)
    this._remoteStream = null;
    this._remoteAudioCtx = null;
    this._remoteAudioSource = null;

    // Delivery confirmation tracking
    this.sentMessages = new Map(); // messageCounter → messageElement

    // Centralized message timer
    this.activeMessageTimers = [];
    this.messageTimerInterval = null;

    // Connection timeout
    this.connectionTimeout = null;

    this.initUI();
    this.checkInviteLink();
    // Если нет invite link — пробуем восстановить сохранённую сессию
    if (!this._hasInviteLink) {
      this.restoreSession();
    }
  }

  /**
   * Check URL for invite link and auto-join
   * Format: https://domain/?room=ROOM_ID
   */
  checkInviteLink() {
    const params = new URLSearchParams(window.location.search);
    const roomId = params.get('room');
    if (!roomId) return;

    this._hasInviteLink = true;

    // Clear query from URL so refresh doesn't retry
    history.replaceState(null, '', window.location.pathname);

    // Auto-join after a short delay to let UI initialize
    setTimeout(() => {
      this.elements.joinInput.value = roomId;
      this.joinRoom();
    }, 100);
  }

  initUI() {
    // DOM элементы
    this.screens = {
      welcome: document.getElementById('welcome-screen'),
      waiting: document.getElementById('waiting-screen'),
      connecting: document.getElementById('connecting-screen'),
      chat: document.getElementById('chat-screen')
    };

    this.elements = {
      createBtn: document.getElementById('create-room-btn'),
      joinBtn: document.getElementById('join-room-btn'),
      joinInput: document.getElementById('join-room-input'),
      roomIdDisplay: document.getElementById('room-id-display'),
      copyBtn: document.getElementById('copy-room-btn'),
      leaveBtn: document.getElementById('leave-btn'),
      messagesContainer: document.getElementById('messages'),
      messageInput: document.getElementById('message-input'),
      sendBtn: document.getElementById('send-btn'),
      fingerprint: document.getElementById('fingerprint'),
      connectionStatus: document.getElementById('connection-status'),
      privacyToggle: document.getElementById('privacy-mode-toggle'),
      verifyBtn: document.getElementById('verify-btn'),
      verifyPanel: document.getElementById('verify-panel'),
      safetyNumberDisplay: document.getElementById('safety-number-display'),
      verifiedBtn: document.getElementById('verified-btn'),
      notVerifiedBtn: document.getElementById('not-verified-btn'),
      // Voice call elements
      callBtn: document.getElementById('call-btn'),
      callOverlay: document.getElementById('call-overlay'),
      callTimer: document.getElementById('call-timer'),
      muteBtn: document.getElementById('mute-btn'),
      muteIconOn: document.getElementById('mute-icon-on'),
      muteIconOff: document.getElementById('mute-icon-off'),
      endCallBtn: document.getElementById('end-call-btn'),
      speakerBtn: document.getElementById('speaker-btn'),
      speakerIconOn: document.getElementById('speaker-icon-on'),
      speakerIconOff: document.getElementById('speaker-icon-off'),
      incomingCall: document.getElementById('incoming-call'),
      acceptCallBtn: document.getElementById('accept-call-btn'),
      declineCallBtn: document.getElementById('decline-call-btn'),
      remoteAudio: document.getElementById('remote-audio'),
      securityAlerts: document.getElementById('security-alerts'),
      shareBtn: document.getElementById('share-room-btn')
    };

    // Режим приватности (скрывает IP через relay)
    this.privacyMode = false;
    this.isVerified = false;
    this.isSpeakerOn = false;

    // Показываем кнопку "Поделиться" если Web Share API доступен (мобильные)
    if (navigator.share && this.elements.shareBtn) {
      this.elements.shareBtn.style.display = 'flex';
    }

    // Event listeners
    this.elements.createBtn.addEventListener('click', () => this.createRoom());
    this.elements.joinBtn.addEventListener('click', () => this.joinRoom());
    this.elements.copyBtn.addEventListener('click', () => this.copyRoomId());
    if (this.elements.shareBtn) {
      this.elements.shareBtn.addEventListener('click', () => this.shareRoomId());
    }
    this.elements.leaveBtn.addEventListener('click', () => this.leave());
    document.getElementById('connecting-leave-btn').addEventListener('click', () => this.leave());
    this.elements.sendBtn.addEventListener('click', () => this.sendMessage());
    this.elements.messageInput.addEventListener('keypress', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        this.sendMessage();
      }
    });

    // Privacy mode toggle
    this.elements.privacyToggle.addEventListener('change', (e) => {
      this.privacyMode = e.target.checked;
      logger.log(`Privacy mode: ${this.privacyMode ? 'ON' : 'OFF'}`);
    });

    // Verification panel
    this.elements.verifyBtn.addEventListener('click', () => this.toggleVerifyPanel());
    this.elements.verifiedBtn.addEventListener('click', () => this.markAsVerified(true));
    this.elements.notVerifiedBtn.addEventListener('click', () => this.markAsVerified(false));

    // Voice call controls
    this.elements.callBtn.addEventListener('click', () => this.startCall());
    this.elements.muteBtn.addEventListener('click', () => this.toggleMute());
    this.elements.speakerBtn.addEventListener('click', () => this.toggleSpeaker());
    this.elements.endCallBtn.addEventListener('click', () => this.endCall());
    this.elements.acceptCallBtn.addEventListener('click', () => this.acceptCall());
    this.elements.declineCallBtn.addEventListener('click', () => this.declineCall());

    // Уничтожаем сессию только при реальном закрытии вкладки (не при переключении приложений на мобильных)
    // pagehide с persisted=false = реальное закрытие; persisted=true = bfcache (мобильные)
    window.addEventListener('pagehide', (e) => {
      if (!e.persisted) {
        this.destroy();
      }
    });

    // Восстановление WS при возврате в приложение (мобильные: WS умирает при фоне)
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden && this.roomId && !this.isConnected) {
        // Страница стала видимой, есть комната, но нет P2P — переподключаем WS
        if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
          this.scheduleReconnect();
        }
      }
    });

    // Screenshot detection (работает в некоторых браузерах)
    this.setupScreenshotDetection();

    // Автоудаление сообщений
    this.messageAutoDeleteTime = 5 * 60 * 1000; // 5 минут по умолчанию
  }

  /**
   * Настройка детекции скриншотов
   */
  setupScreenshotDetection() {
    // Keyboard shortcut detection (PrintScreen, Cmd+Shift+3/4 на Mac)
    document.addEventListener('keyup', (e) => {
      if (e.key === 'PrintScreen' ||
          (e.metaKey && e.shiftKey && (e.key === '3' || e.key === '4'))) {
        this.onScreenshotAttempt();
      }
    });

    // Visibility change (может указывать на screenshot tool)
    document.addEventListener('visibilitychange', () => {
      if (document.hidden && this.isConnected) {
        // Предупреждаем при переключении вкладки во время чата
        logger.log('Tab hidden - potential screenshot');
      }
    });
  }

  /**
   * Обработка попытки скриншота
   */
  onScreenshotAttempt() {
    if (this.isConnected && this.rtc) {
      this.sendEncryptedControl({ type: 'security-alert', alert: 'screenshot-attempt' });
      this.addSystemMessage('Обнаружен скриншот. Собеседник уведомлён.');
    }
  }

  /**
   * Отправка зашифрованного управляющего сообщения через E2E
   */
  async sendEncryptedControl(message) {
    if (!this.crypto?.isReady() || !this.rtc?.isConnected()) return false;
    try {
      const encrypted = await this.crypto.encrypt(JSON.stringify(message));
      return this.rtc.send(JSON.stringify({ type: 'encrypted-message', data: encrypted, v: 2 }));
    } catch (e) {
      logger.error('Failed to send encrypted control:', e);
      return false;
    }
  }

  /**
   * Подключение к WebSocket серверу с автопереподключением
   */
  connectWebSocket() {
    return new Promise((resolve, reject) => {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${protocol}//${window.location.host}/ws`;

      this.ws = new WebSocket(wsUrl);

      this.ws.onopen = () => {
        resolve();
      };

      this.ws.onerror = (error) => {
        logger.error('WebSocket error:', error);
        reject(error);
      };

      this.ws.onclose = () => {
        logger.log('Disconnected from signaling server');
        // Автопереподключение если мы на экране ожидания или подключения
        if (this.roomId && !this.isConnected) {
          this.scheduleReconnect();
        }
      };

      this.ws.onmessage = (event) => {
        this.handleSignalingMessage(JSON.parse(event.data));
      };
    });
  }

  /**
   * Автопереподключение WS (мобильные: WS умирает при переключении приложений)
   */
  scheduleReconnect() {
    if (this._reconnecting) return;
    this._reconnecting = true;
    this._reconnectAttempts = 0;
    const MAX_RECONNECT_ATTEMPTS = 10;

    const attempt = () => {
      if (!this.roomId || this.isConnected) {
        this._reconnecting = false;
        return;
      }

      this._reconnectAttempts++;
      if (this._reconnectAttempts > MAX_RECONNECT_ATTEMPTS) {
        this._reconnecting = false;
        this.showToast('Не удалось переподключиться');
        this.leave();
        return;
      }

      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${protocol}//${window.location.host}/ws`;
      const ws = new WebSocket(wsUrl);

      ws.onopen = () => {
        this.ws = ws;
        this._reconnectAttempts = 0;
        ws.onmessage = (event) => {
          this.handleSignalingMessage(JSON.parse(event.data));
        };
        ws.onclose = () => {
          if (this.roomId && !this.isConnected) {
            this.scheduleReconnect();
          }
        };
        // Переподключаемся к комнате
        ws.send(JSON.stringify({
          type: 'rejoin-room',
          roomId: this.roomId,
          role: this.isHost ? 'host' : 'guest'
        }));
        this._reconnecting = false;
      };

      ws.onerror = () => {
        try { ws.close(); } catch {}
        // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
        const delay = Math.min(1000 * Math.pow(2, this._reconnectAttempts - 1), 30000);
        setTimeout(attempt, delay);
      };
    };

    setTimeout(attempt, 1000);
  }

  /**
   * Обработка сообщений от signaling сервера
   */
  async handleSignalingMessage(message) {
    switch (message.type) {
      case 'room-created':
        this.roomId = message.roomId;
        this.elements.roomIdDisplay.textContent = message.roomId;
        this.saveSession();
        this.showScreen('waiting');
        break;

      case 'rejoin-ok':
        logger.log('Rejoined room after reconnect');
        break;

      case 'room-joined':
        this.roomId = message.roomId;
        this.saveSession();
        logger.log('Room joined, initializing as guest...');
        // Гость - показываем экран подключения
        this.showScreen('connecting');
        // Store promise so handleSignal can wait for initialization
        this.guestInitPromise = this.initAsGuest();
        await this.guestInitPromise;
        this.guestInitPromise = null;
        logger.log('Guest initialized, waiting for WebRTC offer...');
        break;

      case 'peer-joined':
        // Оба участника на месте — начинаем WebRTC handshake
        // Сброс isConnected гарантирует свежий key exchange (критично при rejoin)
        this.isConnected = false;
        this.showScreen('connecting');
        if (this.isHost) {
          // Хост создаёт offer
          await this.startWebRTCConnection();
        } else {
          // Гость готовится принять offer (на случай rejoin)
          if (!this.guestInitPromise) {
            this.guestInitPromise = this.initAsGuest();
            await this.guestInitPromise;
            this.guestInitPromise = null;
          }
        }
        break;

      case 'signal':
        logger.log('Received signal:', message.data.type);
        await this.handleSignal(message.data);
        break;

      case 'peer-left':
        // Полный сброс — собеседник ушёл, комната бесполезна
        this.leave();
        this.showToast('Собеседник отключился');
        break;

      case 'error':
        // Полный сброс при критических ошибках
        this.leave();
        // Показываем ошибку только если это не тихий rejoin (восстановление сессии)
        if (message.message) {
          this.showToast(message.message);
        }
        break;
    }
  }

  /**
   * Создание новой комнаты (хост)
   */
  async createRoom() {
    // Блокируем кнопку
    this.elements.createBtn.disabled = true;
    this.elements.createBtn.querySelector('span').textContent = 'Создаём...';

    try {
      await this.connectWebSocket();

      this.isHost = true;
      this.crypto = new GhostCrypto();
      await this.crypto.generateKeyPair();

      this.rtc = new GhostRTC();
      this.rtc.setPrivacyMode(this.privacyMode);
      this.setupRTCHandlers();

      this.ws.send(JSON.stringify({ type: 'create-room' }));
    } catch (e) {
      logger.error('Error creating room:', e);
      this.showToast('Ошибка создания комнаты');
      this.elements.createBtn.disabled = false;
      const createSpan = this.elements.createBtn.querySelector('span');
      if (createSpan) createSpan.textContent = 'Новый чат';
    }
  }

  /**
   * Присоединение к комнате (гость)
   */
  async joinRoom() {
    const roomId = this.elements.joinInput.value.trim();
    if (!roomId) {
      this.showToast('Введите код комнаты');
      return;
    }

    // Блокируем кнопку чтобы избежать двойного нажатия
    this.elements.joinBtn.disabled = true;
    this.elements.joinBtn.textContent = 'Входим...';

    try {
      await this.connectWebSocket();

      this.isHost = false;
      this.crypto = new GhostCrypto();
      await this.crypto.generateKeyPair();

      this.rtc = new GhostRTC();
      this.rtc.setPrivacyMode(this.privacyMode);
      this.setupRTCHandlers();

      this.ws.send(JSON.stringify({
        type: 'join-room',
        roomId: roomId
      }));
    } catch (e) {
      logger.error('Error joining room:', e);
      this.showToast('Ошибка входа в комнату');
      this.elements.joinBtn.disabled = false;
      this.elements.joinBtn.textContent = 'Войти';
    }
  }

  /**
   * Настройка обработчиков WebRTC
   */
  setupRTCHandlers() {
    this.rtc.onIceCandidate = (candidate) => {
      this.ws.send(JSON.stringify({
        type: 'signal',
        data: { type: 'ice-candidate', candidate }
      }));
    };

    this.rtc.onConnected = async () => {
      // Очищаем таймаут подключения
      if (this.connectionTimeout) {
        clearTimeout(this.connectionTimeout);
        this.connectionTimeout = null;
      }
      const wasConnected = this.isConnected;
      this.isConnected = true;
      this.updateConnectionStatus('connected');
      this.elements.sendBtn.disabled = false;
      this.elements.messageInput.disabled = false;

      if (!wasConnected) {
        // First connection — exchange keys (v2 Double Ratchet)
        const publicKey = await this.crypto.exportPublicKey();
        this.rtc.send(JSON.stringify({
          type: 'key-exchange',
          publicKey: publicKey,
          v: GhostCrypto.PROTOCOL_VERSION
        }));
      } else {
        // Reconnected after temporary disconnect
        this.addSystemMessage('Соединение восстановлено');
      }
    };

    this.rtc.onDisconnected = () => {
      this.addSystemMessage('Соединение потеряно');
      this.showDisconnected();
      // End call if active
      if (this.voice) {
        this.voice.destroy();
        this.voice = null;
      }
      this._cleanupRemoteAudio();
      this._remoteStream = null;
      this.callState = 'idle';
      this.updateCallUI('idle');
    };

    this.rtc.onMessage = async (data) => {
      await this.handleP2PMessage(data);
    };

    // Voice call support
    this.rtc.onTrack = (event) => {
      if (this.voice) {
        this.voice.handleRemoteTrack(event);
      }
    };

    this.rtc.onRenegotiationNeeded = async (offer) => {
      // Send renegotiation offer through encrypted channel
      try {
        const encrypted = await this.crypto.encrypt(JSON.stringify({
          type: 'renegotiate',
          sdp: offer.sdp
        }));
        this.rtc.send(JSON.stringify({
          type: 'encrypted-message',
          data: encrypted,
          v: 2
        }));
      } catch (e) {
        logger.error('Failed to send renegotiation:', e);
      }
    };
  }

  /**
   * Начало WebRTC соединения (для хоста)
   */
  async startWebRTCConnection() {
    logger.log('Starting WebRTC connection as host...');
    const offer = await this.rtc.initAsHost();
    logger.log('Offer created:', offer.type);

    this.ws.send(JSON.stringify({
      type: 'signal',
      data: offer
    }));
    logger.log('Offer sent to signaling server');
  }

  /**
   * Инициализация как гость
   */
  async initAsGuest() {
    await this.rtc.initAsGuest();
  }

  /**
   * Обработка WebRTC signaling
   */
  async handleSignal(signal) {
    logger.log('handleSignal called with:', signal.type);

    // Wait for guest initialization to complete (race condition fix:
    // offer can arrive before initAsGuest finishes creating peer connection)
    if (this.guestInitPromise) {
      logger.log('Waiting for guest initialization before processing signal...');
      await this.guestInitPromise;
    }

    if (signal.type === 'offer') {
      logger.log('Processing offer...');
      const answer = await this.rtc.handleOffer(signal.sdp);
      logger.log('Answer created, sending...');

      this.ws.send(JSON.stringify({
        type: 'signal',
        data: answer
      }));

      // Добавляем отложенные ICE кандидаты
      for (const candidate of this.pendingIceCandidates) {
        await this.rtc.addIceCandidate(candidate);
      }
      this.pendingIceCandidates = [];

    } else if (signal.type === 'answer') {
      logger.log('Processing answer...');
      await this.rtc.handleAnswer(signal.sdp);
      logger.log('Answer processed');

    } else if (signal.type === 'ice-candidate') {
      logger.log('Processing ICE candidate...');
      if (this.rtc.peerConnection && this.rtc.peerConnection.remoteDescription) {
        await this.rtc.addIceCandidate(signal.candidate);
      } else {
        this.pendingIceCandidates.push(signal.candidate);
      }
    }
  }

  /**
   * Обработка P2P сообщений
   * Только key-exchange (до шифрования) и encrypted-message (всё остальное)
   */
  async handleP2PMessage(data) {
    try {
      const message = JSON.parse(data);

      switch (message.type) {
        case 'key-exchange':
          await this.handleKeyExchange(message.publicKey, message.v);
          break;

        case 'encrypted-message':
          await this.handleEncryptedMessage(message.data);
          break;
      }
    } catch (e) {
      logger.error('Error handling P2P message:', e);
    }
  }

  /**
   * Обмен ключами (v2 Double Ratchet)
   */
  async handleKeyExchange(peerPublicKey, peerVersion) {
    // Accept v2+ (backward compat: v3 iOS ↔ v2/v3 web)
    if (!peerVersion || peerVersion < 2) {
      this.addSystemMessage('Несовместимая версия протокола. Обновите Ghost Chat.');
      return;
    }

    await this.crypto.importPeerPublicKey(peerPublicKey);
    await this.crypto.deriveSharedKey(this.isHost);

    // Генерируем fingerprint для верификации
    const fingerprint = await this.crypto.generateFingerprint();
    this.currentFingerprint = fingerprint;
    this.elements.fingerprint.textContent = fingerprint.substring(0, 19) + '...';
    this.elements.safetyNumberDisplay.textContent = fingerprint;

    // Показываем экран чата
    this.showScreen('chat');
    this.updateConnectionStatus('connected');
    this.addSystemMessage('Защищённое соединение установлено');
    this.addSystemMessage('Нажмите на щит для сверки кодов безопасности');
    this.addSystemMessage('Контакты доступны в приложении Ghost Chat для iOS');

    // Host sends bootstrap message to initialize guest's send chain
    // (guest's Double Ratchet needs to receive at least one message
    // to trigger DH ratchet and initialize the send chain)
    if (this.isHost) {
      await this.sendEncryptedControl({ type: 'ready' });
    }

    // Запрашиваем доступ к микрофону для звонков
    this.requestMicrophonePermission();
  }

  /**
   * Запрос доступа к микрофону для голосовых звонков
   */
  async requestMicrophonePermission() {
    try {
      // Проверяем, поддерживается ли API
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        logger.log('getUserMedia not supported');
        return;
      }

      // Запрашиваем доступ к микрофону
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

      // Сразу останавливаем поток - нам нужно только разрешение
      stream.getTracks().forEach(track => track.stop());

      this.addSystemMessage('Микрофон готов');
    } catch (error) {
      if (error.name === 'NotAllowedError') {
        this.addSystemMessage('Доступ к микрофону запрещён');
      } else if (error.name === 'NotFoundError') {
        this.addSystemMessage('Микрофон не найден');
      } else {
        logger.log('Microphone permission error:', error);
      }
    }
  }

  /**
   * Показать/скрыть панель верификации
   */
  toggleVerifyPanel() {
    this.elements.verifyPanel.classList.toggle('hidden');
  }

  /**
   * Отметить как проверенный/непроверенный
   */
  markAsVerified(verified) {
    this.isVerified = verified;
    this.elements.verifyPanel.classList.add('hidden');

    if (verified) {
      this.elements.verifyBtn.classList.add('verified');
      this.addSystemMessage('Подтверждено! Соединение безопасно.');
    } else {
      this.addSystemMessage('ВНИМАНИЕ: Коды НЕ совпадают! Возможна атака!');
      this.addSystemMessage('Немедленно завершите сессию.');
      this.elements.connectionStatus.classList.add('disconnected');
    }
  }

  /**
   * Обработка security alert от собеседника
   */
  handleSecurityAlert(alert) {
    if (alert === 'screenshot-attempt') {
      this.addSystemMessage('Собеседник сделал скриншот');
    }
  }

  // ============================================
  // VOICE CALL METHODS
  // ============================================

  /**
   * Инициализация voice модуля
   */
  initVoice() {
    if (!this.rtc || !this.rtc.peerConnection) {
      logger.error('Cannot init voice: RTC not ready');
      return;
    }

    this.voice = new GhostVoice(this.rtc.peerConnection, this.rtc.dataChannel);

    // Handle remote audio stream — по умолчанию на ухо (earpiece)
    this.voice.onRemoteStream = (stream) => {
      this._remoteStream = stream;
      this._setRemoteAudioOutput(false); // false = earpiece (по умолчанию)
    };

    // Handle call state changes
    this.voice.onCallStateChange = (state) => {
      logger.log('Call state changed:', state);
      if (state === 'active') {
        this.callState = 'active';
        this.updateCallUI('active');
      } else if (state === 'ended') {
        this.callState = 'idle';
        this.updateCallUI('idle');
      }
    };

    // Handle call timer
    this.voice.onCallTimer = (time) => {
      this.elements.callTimer.textContent = time;
    };

    // Handle security alerts during call — through E2E
    this.voice.onSecurityAlert = (alert) => {
      this.showSecurityAlert(alert);
      this.sendEncryptedControl({ type: 'call-security-alert', alert });
    };
  }

  /**
   * Начать исходящий звонок
   */
  async startCall() {
    if (!this.isConnected) {
      this.addSystemMessage('Нет соединения для звонка');
      return;
    }

    if (this.callState !== 'idle') {
      return;
    }

    // Initialize voice if not already
    if (!this.voice) {
      this.initVoice();
    }

    try {
      this.callState = 'calling';
      this.updateCallUI('calling');

      // Suppress automatic onnegotiationneeded — we'll create the offer manually
      this.rtc._suppressNegotiation = true;

      // Start local audio (addTrack triggers onnegotiationneeded, but it's suppressed)
      await this.voice.startCall();

      // Manually create renegotiation offer with our audio track
      const offer = await this.rtc.peerConnection.createOffer();
      await this.rtc.peerConnection.setLocalDescription(offer);

      // Send call-request FIRST (so callee enters 'ringing' state before offer arrives)
      await this.sendEncryptedControl({ type: 'call-request' });

      // Then send renegotiation offer
      const encrypted = await this.crypto.encrypt(JSON.stringify({
        type: 'renegotiate',
        sdp: this.rtc.peerConnection.localDescription
      }));
      this.rtc.send(JSON.stringify({
        type: 'encrypted-message',
        data: encrypted,
        v: 2
      }));

      // Keep suppression ON until we receive the answer
      // (cleared in handleRenegotiation when answer arrives)

      this.addSystemMessage('Звоним...');

    } catch (error) {
      logger.error('Failed to start call:', error);
      this.addSystemMessage(`Ошибка звонка: ${error.message}`);
      this.rtc._suppressNegotiation = false;
      this.callState = 'idle';
      this.updateCallUI('idle');
    }
  }

  /**
   * Обработка входящего звонка
   */
  handleIncomingCall() {
    if (this.callState !== 'idle') {
      this.sendEncryptedControl({ type: 'call-response', accepted: false });
      return;
    }

    this.callState = 'ringing';
    this.updateCallUI('ringing');
    this.addSystemMessage('Входящий звонок...');

    // Вибрация на мобильных
    if (navigator.vibrate) {
      navigator.vibrate([200, 100, 200, 100, 200]);
    }
  }

  /**
   * Принять входящий звонок
   */
  async acceptCall() {
    if (this.callState !== 'ringing') return;

    // Initialize voice if not already
    if (!this.voice) {
      this.initVoice();
    }

    try {
      // Mark as in call BEFORE processing pending offer
      this.voice.isInCall = true;
      this.voice.callStartTime = Date.now();
      this.voice.startCallTimer();

      // Process pending renegotiation offer if we have one
      // This will add our audio track and send the answer
      if (this.pendingRenegotiationOffer) {
        logger.log('Processing pending renegotiation offer');
        await this.processRenegotiationOffer(this.pendingRenegotiationOffer);
        this.pendingRenegotiationOffer = null;
      } else {
        // No pending offer, add our track normally (will trigger our own renegotiation)
        await this.voice.initializeAudio();
        this.voice.localStream.getAudioTracks().forEach(track => {
          this.voice.audioSender = this.rtc.peerConnection.addTrack(track, this.voice.localStream);
        });
        this.voice.startSecurityMonitoring();
      }

      // Send acceptance through E2E
      await this.sendEncryptedControl({ type: 'call-response', accepted: true });

      this.callState = 'active';
      this.updateCallUI('active');
      this.addSystemMessage('Звонок подключён');

    } catch (error) {
      logger.error('Failed to accept call:', error);
      this.addSystemMessage(`Ошибка: ${error.message}`);

      await this.sendEncryptedControl({ type: 'call-response', accepted: false });

      this.voice.isInCall = false;
      this.voice.stopCallTimer();
      this.callState = 'idle';
      this.updateCallUI('idle');
    }
  }

  /**
   * Отклонить входящий звонок
   */
  declineCall() {
    if (this.callState !== 'ringing') return;

    // Notify peer through E2E
    this.sendEncryptedControl({ type: 'call-response', accepted: false });

    // Clean up voice if it was initialized
    if (this.voice) {
      this.voice.destroy();
      this.voice = null;
    }

    this._cleanupRemoteAudio();
    this._remoteStream = null;

    // Always update UI state
    this.callState = 'idle';
    this.pendingRenegotiationOffer = null;
    if (this.rtc) this.rtc._suppressNegotiation = false;
    this.updateCallUI('idle');
    this.addSystemMessage('Звонок отклонён');
  }

  /**
   * Обработка ответа на звонок
   */
  handleCallResponse(accepted) {
    if (this.callState !== 'calling') return;

    if (accepted) {
      // Таймер начинается только когда собеседник принял звонок
      if (this.voice) {
        this.voice.callStartTime = Date.now();
        this.voice.startCallTimer();
      }
      this.callState = 'active';
      this.updateCallUI('active');
      this.addSystemMessage('Звонок начат');
    } else {
      if (this.voice) {
        this.voice.endCall();
        this.voice.destroy();
        this.voice = null;
      }
      this._cleanupRemoteAudio();
      this._remoteStream = null;
      this.callState = 'idle';
      if (this.rtc) this.rtc._suppressNegotiation = false;
      this.updateCallUI('idle');
      this.addSystemMessage('Звонок отклонён');
    }
  }

  /**
   * Завершить звонок
   */
  endCall() {
    if (this.callState === 'idle') return;

    // End the call first (stops audio, timers, etc.)
    if (this.voice) {
      this.voice.endCall();
      // Destroy voice object so a fresh one is created for next call
      this.voice.destroy();
      this.voice = null;
    }

    this._cleanupRemoteAudio();
    this._remoteStream = null;

    // Notify peer through E2E
    this.sendEncryptedControl({ type: 'call-end' });

    // Always update UI state
    this.callState = 'idle';
    this.pendingRenegotiationOffer = null;
    if (this.rtc) this.rtc._suppressNegotiation = false;
    this.updateCallUI('idle');
    this.addSystemMessage('Звонок завершён');
  }

  /**
   * Обработка завершения звонка от собеседника
   */
  handleCallEnded() {
    try {
      if (this.voice) {
        this.voice.endCall();
        // Destroy voice object so a fresh one is created for next call
        this.voice.destroy();
        this.voice = null;
      }
    } catch (e) {
      logger.error('Error ending voice call:', e);
    }

    this._cleanupRemoteAudio();
    this._remoteStream = null;

    // Always update UI state
    this.callState = 'idle';
    this.pendingRenegotiationOffer = null;
    if (this.rtc) this.rtc._suppressNegotiation = false;
    this.updateCallUI('idle');
    this.addSystemMessage('Собеседник завершил звонок');
  }

  /**
   * Переключить mute
   */
  toggleMute() {
    if (!this.voice || !this.voice.isInCall) return;

    const isMuted = this.voice.toggleMute();

    // Update UI
    if (isMuted) {
      this.elements.muteBtn.classList.add('muted');
      this.elements.muteIconOn.classList.add('hidden');
      this.elements.muteIconOff.classList.remove('hidden');
    } else {
      this.elements.muteBtn.classList.remove('muted');
      this.elements.muteIconOn.classList.remove('hidden');
      this.elements.muteIconOff.classList.add('hidden');
    }
  }

  /**
   * Определить платформу для выбора стратегии аудиовыхода
   */
  _getAudioPlatform() {
    const ua = navigator.userAgent;
    if (/iPad|iPhone|iPod/.test(ua) && !window.MSStream) return 'ios';
    if (/android/i.test(ua)) return 'android';
    return 'desktop';
  }

  /**
   * Управление аудио-выходом для remote stream
   *
   * Стратегия (как Telegram Web):
   * - По умолчанию: earpiece (AudioContext route на мобильных)
   * - При переключении на динамик: <audio> element
   *
   * iOS: AudioContext при активном getUserMedia → voice processing → earpiece.
   *      <audio> элемент на iOS ВСЕГДА идёт через громкоговоритель.
   *
   * Android: AudioContext тоже роутит через earpiece при активном mic.
   *          setSinkId('communications') как дополнительный fallback.
   *
   * Desktop: <audio> + setSinkId для выбора устройства.
   */
  _setRemoteAudioOutput(speakerMode) {
    const stream = this._remoteStream;
    if (!stream) return;

    this._cleanupRemoteAudio();

    const platform = this._getAudioPlatform();

    if (platform === 'desktop') {
      // Desktop: всегда через <audio>, выбор устройства через setSinkId
      this.elements.remoteAudio.srcObject = stream;
      this.elements.remoteAudio.play().catch(() => {});
      return;
    }

    // Мобильные (iOS + Android)
    if (speakerMode) {
      // ДИНАМИК: <audio> элемент на мобильных играет через громкоговоритель
      this.elements.remoteAudio.srcObject = stream;
      this.elements.remoteAudio.play().catch(() => {});
    } else {
      // УХО: AudioContext при активном getUserMedia → voice route → earpiece
      // Это работает потому что при активном микрофоне OS переводит аудио
      // в "voice call" режим, и AudioContext.destination роутится на earpiece
      try {
        const AudioCtx = window.AudioContext || window.webkitAudioContext;
        this._remoteAudioCtx = new AudioCtx({ sampleRate: 48000 });

        // resume() обязателен — браузер блокирует AudioContext до user gesture
        const resumeCtx = () => {
          if (this._remoteAudioCtx && this._remoteAudioCtx.state === 'suspended') {
            this._remoteAudioCtx.resume();
          }
        };
        resumeCtx();
        // Повторная попытка через небольшую задержку (iOS иногда не сразу разблокирует)
        setTimeout(resumeCtx, 100);
        setTimeout(resumeCtx, 500);

        this._remoteAudioSource = this._remoteAudioCtx.createMediaStreamSource(stream);
        this._remoteAudioSource.connect(this._remoteAudioCtx.destination);

        logger.log(`Audio output: earpiece via AudioContext (${platform})`);
      } catch (e) {
        logger.warn('AudioContext earpiece failed, fallback to <audio>:', e);
        // Fallback: <audio> element + setSinkId на Android
        this.elements.remoteAudio.srcObject = stream;
        this.elements.remoteAudio.play().catch(() => {});
        if (platform === 'android') {
          this._setAudioToEarpiece();
        }
      }
    }
  }

  /**
   * Очистка аудио-выхода
   */
  _cleanupRemoteAudio() {
    if (this._remoteAudioCtx) {
      try {
        if (this._remoteAudioSource) this._remoteAudioSource.disconnect();
        this._remoteAudioCtx.close();
      } catch {}
      this._remoteAudioCtx = null;
      this._remoteAudioSource = null;
    }
    this.elements.remoteAudio.pause();
    this.elements.remoteAudio.srcObject = null;
  }

  /**
   * setSinkId для earpiece на Android (fallback)
   */
  async _setAudioToEarpiece() {
    const audio = this.elements.remoteAudio;
    if (!audio || typeof audio.setSinkId !== 'function') return;

    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const outputs = devices.filter(d => d.kind === 'audiooutput');
      const earpiece = outputs.find(d => d.deviceId === 'communications')
        || outputs.find(d => /earpiece|телефон|receiver/i.test(d.label));

      if (earpiece) {
        await audio.setSinkId(earpiece.deviceId);
      } else {
        await audio.setSinkId('communications');
      }
    } catch {
      // setSinkId не поддерживается на данном устройстве
    }
  }

  /**
   * Переключить динамик/ухо
   */
  async toggleSpeaker() {
    if (!this.voice || !this.voice.isInCall) return;

    this.isSpeakerOn = !this.isSpeakerOn;

    const platform = this._getAudioPlatform();

    if (platform !== 'desktop') {
      // Мобильные: переключаем AudioContext (ухо) ↔ <audio> (динамик)
      this._setRemoteAudioOutput(this.isSpeakerOn);
    } else {
      // Desktop: setSinkId для выбора устройства
      const audio = this.elements.remoteAudio;
      if (audio && typeof audio.setSinkId === 'function') {
        try {
          const devices = await navigator.mediaDevices.enumerateDevices();
          const outputs = devices.filter(d => d.kind === 'audiooutput');

          if (this.isSpeakerOn) {
            const speaker = outputs.find(d => /speaker|динамик/i.test(d.label))
              || outputs.find(d => d.deviceId === 'default');
            if (speaker) await audio.setSinkId(speaker.deviceId);
          } else {
            await audio.setSinkId('default');
          }
        } catch {
          // setSinkId fallback
        }
      }
    }

    this._updateSpeakerUI();
    this.showToast(this.isSpeakerOn ? 'Динамик' : 'На ухо');
  }

  /**
   * Обновление UI кнопки динамика
   */
  _updateSpeakerUI() {
    if (this.isSpeakerOn) {
      this.elements.speakerBtn.classList.add('speaker-on');
      this.elements.speakerIconOff.classList.add('hidden');
      this.elements.speakerIconOn.classList.remove('hidden');
    } else {
      this.elements.speakerBtn.classList.remove('speaker-on');
      this.elements.speakerIconOff.classList.remove('hidden');
      this.elements.speakerIconOn.classList.add('hidden');
    }

    const label = this.elements.speakerBtn.parentElement?.querySelector('.btn-label');
    if (label) {
      label.textContent = this.isSpeakerOn ? 'Динамик' : 'На ухо';
    }
  }

  /**
   * Обновление UI звонка
   */
  updateCallUI(state) {
    // Hide all call overlays
    this.elements.callOverlay.classList.add('hidden');
    this.elements.incomingCall.classList.add('hidden');

    // Reset call button
    this.elements.callBtn.classList.remove('calling');
    this.elements.callBtn.disabled = false;

    // Reset mute button
    this.elements.muteBtn.classList.remove('muted');
    this.elements.muteIconOn.classList.remove('hidden');
    this.elements.muteIconOff.classList.add('hidden');

    // Reset speaker button
    this.isSpeakerOn = false;
    this._updateSpeakerUI();

    switch (state) {
      case 'calling':
        this.elements.callBtn.classList.add('calling');
        this.elements.callBtn.disabled = true;
        this.elements.callOverlay.classList.remove('hidden');
        this.elements.callTimer.textContent = 'Звоним...';
        break;

      case 'ringing':
        this.elements.callBtn.disabled = true;
        this.elements.incomingCall.classList.remove('hidden');
        break;

      case 'active':
        this.elements.callBtn.disabled = true;
        this.elements.callOverlay.classList.remove('hidden');
        break;

      case 'idle':
      default:
        // Reset timer
        this.elements.callTimer.textContent = '00:00';
        break;
    }
  }

  /**
   * Показать security alert
   */
  showSecurityAlert(alert) {
    const alertEl = document.createElement('div');
    alertEl.className = `security-alert severity-${alert.severity || 'medium'}`;

    const icons = {
      high: '🚨',
      medium: '⚠️',
      low: 'ℹ️'
    };

    // Используем DOM API вместо innerHTML для защиты от XSS
    const headerEl = document.createElement('div');
    headerEl.className = 'security-alert-header';

    const iconEl = document.createElement('span');
    iconEl.className = 'security-alert-icon';
    iconEl.textContent = icons[alert.severity] || icons.medium;

    const titleEl = document.createElement('span');
    titleEl.className = 'security-alert-title';
    titleEl.textContent = 'Предупреждение безопасности';

    const messageEl = document.createElement('div');
    messageEl.className = 'security-alert-message';
    messageEl.textContent = alert.message; // textContent безопасен от XSS

    headerEl.appendChild(iconEl);
    headerEl.appendChild(titleEl);
    alertEl.appendChild(headerEl);
    alertEl.appendChild(messageEl);

    this.elements.securityAlerts.appendChild(alertEl);

    // Auto remove after 5 seconds
    setTimeout(() => {
      alertEl.remove();
    }, 5000);

    // Also add to chat
    this.addSystemMessage(`⚠️ ${alert.message}`);
  }

  /**
   * Обработка зашифрованного сообщения
   * Все управляющие сообщения (звонки, алерты, renegotiation) идут через E2E
   */
  async handleEncryptedMessage(encryptedData) {
    try {
      const plaintext = await this.crypto.decrypt(encryptedData);

      // Проверяем, управляющее ли это сообщение
      try {
        const msg = JSON.parse(plaintext);
        if (msg.type) {
          await this.handleControlMessage(msg);
          return;
        }
      } catch {
        // Не JSON — обычное текстовое сообщение
      }

      this.addMessage(plaintext, 'received');
      // Подтверждение доставки
      this.sendEncryptedControl({ type: 'message-ack', c: this.crypto.peerMessageCounter });
    } catch (e) {
      logger.error('Error decrypting message:', e);
      this.addSystemMessage('Ошибка расшифровки');
    }
  }

  /**
   * Маршрутизация управляющих сообщений
   */
  async handleControlMessage(msg) {
    switch (msg.type) {
      case 'renegotiate':
        await this.handleRenegotiation(msg.sdp);
        break;
      case 'call-request':
        this.handleIncomingCall();
        break;
      case 'call-response':
        this.handleCallResponse(msg.accepted);
        break;
      case 'call-end':
        this.handleCallEnded();
        break;
      case 'call-security-alert':
        this.showSecurityAlert(msg.alert);
        break;
      case 'security-alert':
        this.handleSecurityAlert(msg.alert);
        break;
      case 'message-ack':
        this.handleMessageAck(msg.c);
        break;
      case 'ready':
        // Bootstrap from host — decryption already triggered DH ratchet
        break;
    }
  }

  /**
   * Обработка подтверждения доставки
   */
  handleMessageAck(counter) {
    const el = this.sentMessages.get(counter);
    if (el) {
      const timeEl = el.querySelector('.message-time');
      if (timeEl && !timeEl.textContent.includes('✓')) {
        timeEl.textContent += ' ✓';
      }
      this.sentMessages.delete(counter);
    }
  }

  /**
   * Обработка renegotiation для добавления audio tracks
   */
  async handleRenegotiation(sdp) {
    logger.log('Handling renegotiation:', sdp.type, 'callState:', this.callState);

    try {
      if (sdp.type === 'offer') {
        // If we're waiting to accept a call, store the offer for later
        if (this.callState === 'ringing') {
          logger.log('Storing renegotiation offer until call is accepted');
          this.pendingRenegotiationOffer = sdp;
          return;
        }

        // Process the offer (add our audio track if in a call)
        await this.processRenegotiationOffer(sdp);

      } else if (sdp.type === 'answer') {
        // We received an answer — clear suppression (caller side)
        await this.rtc.handleAnswer(sdp);
        this.rtc._suppressNegotiation = false;
      }
    } catch (e) {
      logger.error('Renegotiation error:', e);
    }
  }

  /**
   * Process a renegotiation offer - add our audio and send answer
   */
  async processRenegotiationOffer(sdp) {
    // Suppress automatic onnegotiationneeded — addTrack would trigger a conflicting offer
    this.rtc._suppressNegotiation = true;

    try {
      // Add our audio track BEFORE creating the answer
      // This ensures the answer SDP includes our audio as sendrecv
      if (this.voice && !this.voice.localStream) {
        logger.log('Adding our audio track before answering renegotiation');
        try {
          await this.voice.initializeAudio();
          this.voice.localStream.getAudioTracks().forEach(track => {
            this.voice.audioSender = this.rtc.peerConnection.addTrack(track, this.voice.localStream);
          });
          this.voice.startSecurityMonitoring();
        } catch (e) {
          logger.error('Failed to add audio track:', e);
        }
      }

      // Create answer with our audio included
      const answer = await this.rtc.handleOffer(sdp);

      const encrypted = await this.crypto.encrypt(JSON.stringify({
        type: 'renegotiate',
        sdp: answer.sdp
      }));

      this.rtc.send(JSON.stringify({
        type: 'encrypted-message',
        data: encrypted,
        v: 2
      }));
    } finally {
      this.rtc._suppressNegotiation = false;
    }
  }

  /**
   * Отправка сообщения
   */
  async sendMessage() {
    const text = this.elements.messageInput.value.trim();
    if (!text || !this.isConnected) return;

    try {
      const encrypted = await this.crypto.encrypt(text);

      this.rtc.send(JSON.stringify({
        type: 'encrypted-message',
        data: encrypted,
        v: 2
      }));

      const div = this.addMessage(text, 'sent');
      // Tracking доставки по счётчику
      this.sentMessages.set(this.crypto.messageCounter, div);
      this.elements.messageInput.value = '';
    } catch (e) {
      logger.error('Error sending message:', e);
      this.addSystemMessage('Ошибка отправки');
    }
  }

  /**
   * Добавление сообщения в чат с автоудалением
   * Возвращает DOM-элемент сообщения (для tracking доставки)
   */
  addMessage(text, type) {
    const div = document.createElement('div');
    div.className = `message ${type}`;

    const content = document.createElement('div');
    content.className = 'message-content';
    content.textContent = text;

    const time = document.createElement('div');
    time.className = 'message-time';
    time.textContent = new Date().toLocaleTimeString();

    // Индикатор самоуничтожения
    const timer = document.createElement('div');
    timer.className = 'message-timer';
    timer.textContent = '⏱️ 5:00';

    div.appendChild(content);
    div.appendChild(time);
    div.appendChild(timer);

    this.elements.messagesContainer.appendChild(div);
    this.elements.messagesContainer.scrollTop = this.elements.messagesContainer.scrollHeight;

    // Регистрируем в централизованном таймере
    this.activeMessageTimers.push({
      messageEl: div,
      timerEl: timer,
      endTime: Date.now() + this.messageAutoDeleteTime
    });
    this.startMessageTimerLoop();

    return div;
  }

  /**
   * Централизованный таймер самоуничтожения сообщений
   * Один setInterval вместо отдельного rAF на каждое сообщение
   */
  startMessageTimerLoop() {
    if (this.messageTimerInterval) return;
    this.messageTimerInterval = setInterval(() => {
      const now = Date.now();
      this.activeMessageTimers = this.activeMessageTimers.filter(entry => {
        const remaining = Math.max(0, entry.endTime - now);
        const minutes = Math.floor(remaining / 60000);
        const seconds = Math.floor((remaining % 60000) / 1000);
        entry.timerEl.textContent = `⏱️ ${minutes}:${seconds.toString().padStart(2, '0')}`;

        if (remaining <= 0) {
          entry.messageEl.style.opacity = '0';
          entry.messageEl.style.transform = 'scale(0.8)';
          setTimeout(() => entry.messageEl.remove(), 300);
          return false;
        }
        return true;
      });

      if (this.activeMessageTimers.length === 0) {
        clearInterval(this.messageTimerInterval);
        this.messageTimerInterval = null;
      }
    }, 1000);
  }

  /**
   * Тост-уведомление (неблокирующий аналог alert)
   */
  showToast(text) {
    const toast = document.createElement('div');
    toast.className = 'toast-notification';
    toast.textContent = text;
    document.body.appendChild(toast);
    // Плавное исчезновение через 3 секунды
    setTimeout(() => {
      toast.style.opacity = '0';
      setTimeout(() => toast.remove(), 300);
    }, 3000);
  }

  /**
   * Системное сообщение
   */
  addSystemMessage(text) {
    const div = document.createElement('div');
    div.className = 'message system';
    div.textContent = text;
    this.elements.messagesContainer.appendChild(div);
    this.elements.messagesContainer.scrollTop = this.elements.messagesContainer.scrollHeight;
  }

  /**
   * Получить invite ссылку
   */
  getInviteLink() {
    return `${window.location.origin}/?room=${this.roomId}`;
  }

  /**
   * Копирование ссылки в буфер обмена
   */
  async copyRoomId() {
    const inviteLink = this.getInviteLink();
    let copied = false;

    // Метод 1: Clipboard API
    if (navigator.clipboard && navigator.clipboard.writeText) {
      try {
        await navigator.clipboard.writeText(inviteLink);
        copied = true;
      } catch (e) {
        // Clipboard API не сработал — пробуем fallback
      }
    }

    // Метод 2: Fallback через textarea (работает на мобильных)
    if (!copied) {
      const textarea = document.createElement('textarea');
      textarea.value = inviteLink;
      textarea.style.position = 'fixed';
      textarea.style.left = '-9999px';
      textarea.style.top = '-9999px';
      textarea.style.opacity = '0';
      document.body.appendChild(textarea);
      textarea.focus();
      textarea.select();
      textarea.setSelectionRange(0, inviteLink.length);
      try {
        document.execCommand('copy');
        copied = true;
      } catch (e) {
        // Тоже не сработало
      }
      document.body.removeChild(textarea);
    }

    // Visual feedback
    if (copied) {
      this.elements.copyBtn.classList.add('copied');
      const spanEl = this.elements.copyBtn.querySelector('span');
      if (spanEl) spanEl.textContent = 'Скопировано!';
      const feedback = document.getElementById('copy-feedback');
      if (feedback) feedback.style.display = 'block';
      setTimeout(() => {
        this.elements.copyBtn.classList.remove('copied');
        if (spanEl) spanEl.textContent = 'Скопировать ссылку';
        if (feedback) feedback.style.display = 'none';
      }, 2000);
    } else {
      alert(inviteLink);
    }
  }

  /**
   * Поделиться ссылкой через нативный шаринг (мобильные)
   */
  async shareRoomId() {
    const inviteLink = this.getInviteLink();
    try {
      await navigator.share({
        title: 'Ghost Chat',
        text: 'Присоединяйся к приватному чату',
        url: inviteLink
      });
    } catch (e) {
      // Пользователь отменил или API недоступен — копируем вместо этого
      if (e.name !== 'AbortError') {
        this.copyRoomId();
      }
    }
  }

  /**
   * Переключение экранов
   */
  showScreen(name) {
    Object.values(this.screens).forEach(screen => screen.classList.add('hidden'));
    this.screens[name].classList.remove('hidden');

    // Таймаут подключения (30 секунд)
    if (name === 'connecting') {
      if (this.connectionTimeout) clearTimeout(this.connectionTimeout);
      this.connectionTimeout = setTimeout(() => {
        if (!this.isConnected) {
          this.addSystemMessage('Не удалось подключиться (таймаут)');
          this.leave();
        }
      }, 30000);
    }
  }

  /**
   * Обновление статуса соединения
   */
  updateConnectionStatus(status) {
    if (status === 'connected') {
      this.elements.connectionStatus.classList.remove('disconnected');
    } else {
      this.elements.connectionStatus.classList.add('disconnected');
    }
  }

  /**
   * Показать состояние отключения
   */
  showDisconnected() {
    this.isConnected = false;
    this.updateConnectionStatus('disconnected');
    this.elements.sendBtn.disabled = true;
    this.elements.messageInput.disabled = true;
  }

  // ============================================
  // SESSION PERSISTENCE (переживает переключение приложений)
  // ============================================

  /**
   * Сохранить состояние сессии в sessionStorage
   * Позволяет восстановить сессию после переключения приложений на мобильных
   */
  saveSession() {
    try {
      sessionStorage.setItem('ghost-room', JSON.stringify({
        roomId: this.roomId,
        isHost: this.isHost,
        ts: Date.now()
      }));
    } catch {
      // sessionStorage недоступен — работаем без persistence
    }
  }

  /**
   * Восстановить сессию из sessionStorage
   * Вызывается при загрузке страницы (если нет invite link)
   */
  async restoreSession() {
    try {
      const saved = sessionStorage.getItem('ghost-room');
      if (!saved) return;

      const { roomId, isHost, ts } = JSON.parse(saved);
      if (!roomId) return;

      // Сессия старше 10 минут — комната уже удалена на сервере
      const SESSION_TTL = 10 * 60 * 1000;
      const age = ts ? Date.now() - ts : Infinity;
      if (!ts || age > SESSION_TTL) {
        this.clearSession();
        return;
      }

      this.roomId = roomId;
      this.isHost = isHost;

      // Показываем экран ожидания (хост) или подключения
      if (isHost) {
        this.elements.roomIdDisplay.textContent = roomId;
        this.showScreen('waiting');
      } else {
        this.showScreen('connecting');
      }

      // Инициализируем крипто и WebRTC
      this.crypto = new GhostCrypto();
      await this.crypto.generateKeyPair();

      this.rtc = new GhostRTC();
      this.rtc.setPrivacyMode(this.privacyMode);
      this.setupRTCHandlers();

      // Подключаем WS и делаем rejoin
      await this.connectWebSocket();
      this.ws.send(JSON.stringify({
        type: 'rejoin-room',
        roomId: this.roomId,
        role: isHost ? 'host' : 'guest'
      }));
    } catch (e) {
      logger.error('Failed to restore session:', e);
      this.clearSession();
      this.showScreen('welcome');
    }
  }

  /**
   * Очистить сохранённую сессию
   */
  clearSession() {
    try {
      sessionStorage.removeItem('ghost-room');
    } catch {
      // sessionStorage недоступен
    }
  }

  /**
   * Выход из комнаты
   */
  leave() {
    this.clearSession();
    this.destroy();
    this.showScreen('welcome');
    this.elements.messagesContainer.replaceChildren();
    this.elements.messageInput.value = '';
    this.elements.messageInput.disabled = false;
    this.elements.sendBtn.disabled = false;
    this.elements.joinInput.value = '';
    // Сброс кнопок
    this.elements.createBtn.disabled = false;
    const createSpan = this.elements.createBtn.querySelector('span');
      if (createSpan) createSpan.textContent = 'Новый чат';
    this.elements.joinBtn.disabled = false;
    this.elements.joinBtn.textContent = 'Войти';
  }

  /**
   * Полная очистка и уничтожение всех данных
   */
  destroy() {
    // Останавливаем автопереподключение
    this._reconnecting = false;
    this.roomId = null;

    // Очищаем таймеры
    if (this.connectionTimeout) {
      clearTimeout(this.connectionTimeout);
      this.connectionTimeout = null;
    }
    if (this.messageTimerInterval) {
      clearInterval(this.messageTimerInterval);
      this.messageTimerInterval = null;
    }
    this.activeMessageTimers = [];
    this.sentMessages.clear();

    // End any active call
    if (this.voice) {
      this.voice.destroy();
      this.voice = null;
    }
    this.callState = 'idle';
    this.updateCallUI('idle');

    // Уведомляем сервер
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: 'leave-room' }));
    }
    if (this.ws) {
      this.ws.onclose = null; // Убираем обработчик чтобы не триггерить reconnect
      this.ws.close();
    }
    this.ws = null;

    // Уничтожаем WebRTC
    if (this.rtc) {
      this.rtc.destroy();
      this.rtc = null;
    }

    // Уничтожаем криптографические ключи
    if (this.crypto) {
      this.crypto.destroy();
      this.crypto = null;
    }

    this._cleanupRemoteAudio();
    this._remoteStream = null;

    this.isHost = false;
    this.isConnected = false;
    this.pendingIceCandidates = [];
    this.guestInitPromise = null;
  }
}

// Unregister any previously registered service workers
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then(registrations => {
    registrations.forEach(r => r.unregister());
  });
}

// Suppress PWA install prompt
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
});

// Platform detection — show the right app promo
function detectPlatform() {
  const ua = navigator.userAgent || '';
  const androidEl = document.getElementById('app-promo-android');
  const iosEl = document.getElementById('app-promo-ios');
  const desktopEl = document.getElementById('app-promo-desktop');

  if (/android/i.test(ua)) {
    if (androidEl) {
      androidEl.style.display = '';
      androidEl.addEventListener('click', () => {
        window.location.href = '/GhostChat.apk';
      });
    }
  } else if (/iPhone|iPad|iPod/i.test(ua)) {
    if (iosEl) iosEl.style.display = '';
  } else {
    if (desktopEl) desktopEl.style.display = '';
  }
}

// Инициализация приложения
window.addEventListener('DOMContentLoaded', () => {
  window.ghostChat = new GhostChat();
  detectPlatform();
});
