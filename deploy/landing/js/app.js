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
  // File transfer: 2KB chunks, matches iOS FileTransferService chunk size.
  // After base64 + JSON + encryption overhead each DataChannel send stays under ~6KB.
  static FILE_CHUNK_SIZE = 2 * 1024;

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
    this._ringingTimeout = null; // Auto-decline after 45s of ringing
    this._callingTimeout = null; // Auto-cancel call after 45s of no answer

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

    // Typing indicator — unified timings (same on iOS/Android)
    this._lastTypingSentAt = 0;
    this._typingCancelTimer = null;
    this._peerTypingCancelTimer = null;

    this.initUI();
    this.checkInviteLink();
    // Если нет invite link — пробуем восстановить сохранённую сессию
    if (!this._hasInviteLink) {
      this.restoreSession();
    }
  }

  /**
   * Check URL for invite link and auto-join
   * L5: Support both fragment (#room=ID) and query (?room=ID) for backward compat
   * Fragment is preferred — it's never sent to the server (privacy)
   */
  checkInviteLink() {
    // Try fragment first (preferred — not sent to server)
    let roomId = null;
    const hash = window.location.hash;
    if (hash) {
      const hashParams = new URLSearchParams(hash.substring(1));
      roomId = hashParams.get('room');
    }
    // Fallback to query param (backward compat with existing links / deep links)
    if (!roomId) {
      const params = new URLSearchParams(window.location.search);
      roomId = params.get('room');
    }
    if (!roomId) return;

    this._hasInviteLink = true;

    // On mobile: show choice — open in app or continue in browser
    const isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
    if (isMobile) {
      this._showAppRedirect(roomId);
      return;
    }

    // Clear URL so refresh doesn't retry
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
      connectionStatus: document.getElementById('connection-status'),
      privacyToggle: document.getElementById('privacy-mode-toggle'),
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
      shareBtn: document.getElementById('share-room-btn'),
      // File + reply UI
      attachBtn: document.getElementById('attach-btn'),
      fileInput: document.getElementById('file-input'),
      replyPreview: document.getElementById('reply-preview'),
      replyPreviewText: document.getElementById('reply-preview-text'),
      replyCancelBtn: document.getElementById('reply-cancel-btn')
    };

    // Reply / quote state
    this.replyingTo = null; // { id: senderMessageId, text: previewText }

    // Режим приватности (скрывает IP через relay) — ON по умолчанию (max security)
    this.privacyMode = false; // TURN relay disabled for now
    this.isVerified = false;
    this.isSpeakerOn = false;

    // Показываем кнопку "Поделиться" если Web Share API доступен (мобильные)
    if (navigator.share && this.elements.shareBtn) {
      this.elements.shareBtn.classList.add('visible');
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

    // Keyboard shortcuts
    this.elements.messageInput.addEventListener('keydown', (e) => {
      // Esc — cancel reply
      if (e.key === 'Escape' && this.replyingTo) {
        e.preventDefault();
        this.cancelReply();
        return;
      }
      // ↑ Arrow with empty input — edit last sent message
      if (e.key === 'ArrowUp' && !this.elements.messageInput.value.trim()) {
        e.preventDefault();
        const sentMsgs = [...document.querySelectorAll('.message.sent[data-sender-id]')];
        const last = sentMsgs[sentMsgs.length - 1];
        if (last) {
          const sid = last.getAttribute('data-sender-id');
          const text = last.querySelector('.message-content')?.textContent || '';
          this.elements.messageInput.value = text;
          this._editingMessageId = sid;
          this._editingOriginalEl = last;
          this.elements.messageInput.placeholder = 'Редактирование... (Esc для отмены)';
        }
        return;
      }
      // Esc while editing — cancel edit
      if (e.key === 'Escape' && this._editingMessageId) {
        e.preventDefault();
        this.elements.messageInput.value = '';
        this.elements.messageInput.placeholder = 'Сообщение...';
        this._editingMessageId = null;
        this._editingOriginalEl = null;
        return;
      }
    });

    // Typing indicator — send on input
    this.elements.messageInput.addEventListener('input', () => {
      if (this.elements.messageInput.value.length > 0) {
        this.userIsTyping();
      } else {
        this.stopTyping();
      }
    });

    // Privacy mode toggle
    this.elements.privacyToggle.addEventListener('change', (e) => {
      this.privacyMode = e.target.checked;
      logger.log(`Privacy mode: ${this.privacyMode ? 'ON' : 'OFF'}`);
    });

    // Verification panel
    // Security codes verification removed — nobody uses it

    // File attachment
    if (this.elements.attachBtn && this.elements.fileInput) {
      this.elements.attachBtn.addEventListener('click', () => {
        if (!this.isConnected) {
          this.showToast('Нет соединения');
          return;
        }
        this.elements.fileInput.click();
      });
      this.elements.fileInput.addEventListener('change', (e) => {
        const file = e.target.files && e.target.files[0];
        if (file) this.sendFile(file);
        e.target.value = ''; // reset so same file can be re-picked
      });
    }

    // Reply cancel
    if (this.elements.replyCancelBtn) {
      this.elements.replyCancelBtn.addEventListener('click', () => this.cancelReply());
    }

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
    this.messageAutoDeleteTime = 0; // Автоудаление отключено по умолчанию
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
      message._ctrl = true;
      const encrypted = await this.crypto.encrypt(JSON.stringify(message));
      return this.rtc.send(JSON.stringify({ type: 'encrypted-message', data: encrypted, v: 2 }));
    } catch (e) {
      logger.error('Failed to send encrypted control:', e);
      return false;
    }
  }

  // MARK: - Typing Indicator

  /** Called on every keystroke in input */
  userIsTyping() {
    if (!this.isConnected) return;
    const now = Date.now();
    // Throttle: send at most every 3 seconds
    if (now - this._lastTypingSentAt >= 3000) {
      this._lastTypingSentAt = now;
      this.sendEncryptedControl({ type: 'typing', isTyping: true });
    }
    // Auto-cancel after 5 seconds of no typing
    clearTimeout(this._typingCancelTimer);
    this._typingCancelTimer = setTimeout(() => this.stopTyping(), 5000);
  }

  /** Send typing:false immediately */
  stopTyping() {
    clearTimeout(this._typingCancelTimer);
    this._typingCancelTimer = null;
    // Не отправляем typing:false если typing:true не был отправлен (throttled)
    if (this._lastTypingSentAt === 0) return;
    this._lastTypingSentAt = 0;
    if (this.isConnected) {
      this.sendEncryptedControl({ type: 'typing', isTyping: false });
    }
  }

  /** Handle peer typing indicator */
  handlePeerTyping(isTyping) {
    const el = document.getElementById('typing-indicator');
    if (!el) return;
    if (isTyping) {
      el.classList.remove('hidden');
      // Auto-clear after 6 seconds without update
      clearTimeout(this._peerTypingCancelTimer);
      this._peerTypingCancelTimer = setTimeout(() => {
        el.classList.add('hidden');
      }, 6000);
    } else {
      el.classList.add('hidden');
      clearTimeout(this._peerTypingCancelTimer);
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
        try {
          this.handleSignalingMessage(JSON.parse(event.data));
        } catch (e) {
          logger.error('Invalid WS message:', e);
        }
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
          try {
            this.handleSignalingMessage(JSON.parse(event.data));
          } catch (e) {
            logger.error('Invalid WS message:', e);
          }
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
        // Отправляем буферизованный ICE restart offer если есть
        if (this._pendingIceRestartOffer) {
          const offer = this._pendingIceRestartOffer;
          this._pendingIceRestartOffer = null;
          if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify({ type: 'signal', data: offer }));
            logger.log('Buffered ICE restart offer sent after rejoin');
          }
        } else if (this.rtc && !this.rtc._connected) {
          // Нет буферизованного offer, но ICE до сих пор не восстановлен — повторяем restart
          this.rtc._iceRestartAttempted = false;
          this.rtc._attemptIceRestart();
          logger.log('Re-attempting ICE restart after rejoin');
        }
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
        // Пир вернулся — отменяем таймаут ожидания
        this.showDisconnectBanner(false);
        if (this._peerLeftTimeout) {
          clearTimeout(this._peerLeftTimeout);
          this._peerLeftTimeout = null;
        }
        // Сброс отложенных ICE кандидатов от предыдущего соединения
        this.pendingIceCandidates = [];
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
        // Собеседник потерял WS или вышел
        this.isConnected = false;
        this.handlePeerTyping(false);
        this.showDisconnectBanner(true);
        this.addSystemMessage('Собеседник отключился');
        // Таймаут: если пир не вернулся за 60 секунд — выходим
        if (this._peerLeftTimeout) clearTimeout(this._peerLeftTimeout);
        this._peerLeftTimeout = setTimeout(() => {
          this._peerLeftTimeout = null;
          if (this.roomId) {
            this.addSystemMessage('Собеседник не вернулся');
            this.leave();
          }
        }, 60000);
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
      // CRITICAL FIX: Don't enable send UI until crypto is ready
      // isConnected = true only AFTER key exchange completes (see handleKeyExchange)
      this.updateConnectionStatus('connected');

      if (!wasConnected) {
        // First connection — exchange keys (v2 Double Ratchet)
        // Send button stays disabled until key exchange completes
        // C1: Include DTLS fingerprint for transport binding
        const publicKey = await this.crypto.exportPublicKey();
        let dtlsFingerprint = null;
        try {
          const localDesc = this.rtc.peerConnection?.localDescription;
          if (localDesc?.sdp) {
            const match = localDesc.sdp.match(/a=fingerprint:sha-256\s+([^\r\n]+)/i);
            if (match) dtlsFingerprint = match[1].trim();
          }
        } catch {}
        this.rtc.send(JSON.stringify({
          type: 'key-exchange',
          publicKey: publicKey,
          identityKey: publicKey,
          platform: 'web',
          v: GhostCrypto.PROTOCOL_VERSION,
          dtls: dtlsFingerprint
        }));
      } else {
        // Reconnected after temporary disconnect — crypto already established
        this.isConnected = true;
        this.elements.sendBtn.disabled = false;
        this.elements.messageInput.disabled = false;
        this.addSystemMessage('Соединение восстановлено');
      }
    };

    this.rtc.onDisconnected = () => {
      this.addSystemMessage('Соединение потеряно');
      this.showDisconnected();
      // End call if active — suppress renegotiation during cleanup
      if (this.voice) {
        if (this.rtc) this.rtc._suppressNegotiation = true;
        this.voice.destroy();
        this.voice = null;
        if (this.rtc) this.rtc._suppressNegotiation = false;
      }
      this._cleanupRemoteAudio();
      this._remoteStream = null;
      this.callState = 'idle';
      this.updateCallUI('idle');
    };

    this.rtc.onMessage = async (data) => {
      await this.handleP2PMessage(data);
    };

    // Voice call support — buffer track if voice not yet initialized
    this.rtc.onTrack = (event) => {
      if (this.voice) {
        this.voice.handleRemoteTrack(event);
      } else {
        logger.log('Buffering remote track (voice not initialized yet)');
        this._pendingRemoteTrack = event;
      }
    };

    this.rtc.onRenegotiationNeeded = async (offer) => {
      // Send renegotiation offer through encrypted channel
      try {
        const encrypted = await this.crypto.encrypt(JSON.stringify({
          type: 'renegotiate',
          sdp: offer.sdp,
          _ctrl: true
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

    // ICE restart offer goes through signaling server (not DataChannel!)
    // DataChannel rides on the same ICE transport that just broke
    this.rtc.onIceRestartNeeded = (offer) => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({
          type: 'signal',
          data: offer
        }));
        logger.log('ICE restart offer sent via signaling server');
      } else {
        // WS не подключен — буферизуем offer для отправки после reconnect
        this._pendingIceRestartOffer = offer;
        logger.log('ICE restart offer buffered — WS not connected');
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
          // M3: Validate types before passing to handler
          if (typeof message.publicKey !== 'string' || typeof message.v !== 'number') {
            logger.error('Invalid key-exchange message: bad types');
            return;
          }
          // Validate dtls field type before passing
          if (message.dtls !== undefined && typeof message.dtls !== 'string') {
            this.addSystemMessage('БЕЗОПАСНОСТЬ: Некорректный формат DTLS fingerprint.');
            this.leave();
            return;
          }
          await this.handleKeyExchange(message.publicKey, message.v, message.dtls);
          break;

        case 'encrypted-message':
          if (typeof message.data !== 'string') {
            logger.error('Invalid encrypted-message: data must be string');
            return;
          }
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
  async handleKeyExchange(peerPublicKey, peerVersion, peerDtlsFingerprint) {
    // Accept v2+ (backward compat: v3 iOS ↔ v2/v3 web)
    if (!peerVersion || peerVersion < 2) {
      this.addSystemMessage('Несовместимая версия протокола. Обновите Ghost Chat.');
      return;
    }

    // DTLS fingerprint is mandatory for v3+ peers
    if (peerVersion >= 3 && !peerDtlsFingerprint) {
      this.addSystemMessage('БЕЗОПАСНОСТЬ: Отсутствует DTLS fingerprint — возможна MITM атака. Соединение заблокировано.');
      this.leave();
      return;
    }

    // C1: Verify DTLS fingerprint binding (anti-MITM)
    // If peer provided their DTLS fingerprint, verify it matches the remote SDP
    // Mismatch = MITM attack → BLOCK connection (not just warn)
    if (peerDtlsFingerprint && this.rtc?.peerConnection?.remoteDescription?.sdp) {
      try {
        const remoteSdp = this.rtc.peerConnection.remoteDescription.sdp;
        const match = remoteSdp.match(/a=fingerprint:sha-256\s+([^\r\n]+)/i);
        if (match) {
          const expectedFingerprint = match[1].trim();
          if (peerDtlsFingerprint !== expectedFingerprint) {
            logger.error('DTLS fingerprint mismatch — MITM detected, terminating connection');
            this.addSystemMessage('БЕЗОПАСНОСТЬ: DTLS fingerprint не совпадает! Возможна атака MITM.');
            this.addSystemMessage('Соединение заблокировано. Попробуйте другую сеть.');
            this.leave();
            return;
          }
        }
      } catch (e) {
        logger.error('DTLS fingerprint verification failed:', e);
      }
    }

    await this.crypto.importPeerPublicKey(peerPublicKey);
    await this.crypto.deriveSharedKey(this.isHost);

    // Генерируем fingerprint для верификации
    const fingerprint = await this.crypto.generateFingerprint();
    this.currentFingerprint = fingerprint;

    // Показываем экран чата — теперь crypto готов, можно разрешить отправку
    this.isConnected = true;
    this.elements.sendBtn.disabled = false;
    this.elements.messageInput.disabled = false;
    this.showScreen('chat');
    this.updateConnectionStatus('connected');
    this.addSystemMessage('Защищённое соединение установлено');

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
  // toggleVerifyPanel() and markAsVerified() removed — security codes UI removed

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
      this._startAudioHealthCheck();
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

    // Replay buffered remote track if it arrived before voice was initialized
    if (this._pendingRemoteTrack) {
      logger.log('Replaying buffered remote track');
      this.voice.handleRemoteTrack(this._pendingRemoteTrack);
      this._pendingRemoteTrack = null;
    }
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
    if (!this.voice) {
      this.addSystemMessage('Ошибка инициализации звонка');
      return;
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
      const sent = await this.sendEncryptedControl({ type: 'call-request' });
      if (!sent) {
        throw new Error('Не удалось отправить запрос звонка');
      }

      // Then send renegotiation offer
      const encrypted = await this.crypto.encrypt(JSON.stringify({
        type: 'renegotiate',
        sdp: this.rtc.peerConnection.localDescription,
        _ctrl: true
      }));
      this.rtc.send(JSON.stringify({
        type: 'encrypted-message',
        data: encrypted,
        v: 2
      }));

      // Keep suppression ON until we receive the answer
      // (cleared in handleRenegotiation when answer arrives)

      this.addSystemMessage('Звоним...');

      // Caller-side timeout — cancel call after 45s of no answer (matches iOS/Android)
      this._callingTimeout = setTimeout(() => {
        this._callingTimeout = null;
        if (this.callState === 'calling') {
          this.addSystemMessage('Нет ответа');
          this.endCall();
        }
      }, 45000);

    } catch (error) {
      logger.error('Failed to start call:', error);
      this.addSystemMessage(`Ошибка звонка: ${error.message}`);
      // Soft cleanup — keep voice instance for reuse
      if (this.voice) {
        this.voice.endCall();
      }
      this._cleanupRemoteAudio();
      this._remoteStream = null;
      if (this.rtc) this.rtc._suppressNegotiation = false;
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

    // Auto-decline after 45 seconds (matches iOS/Android behavior)
    this._ringingTimeout = setTimeout(() => {
      if (this.callState === 'ringing') {
        this.declineCall();
        this.addSystemMessage('Пропущенный звонок');
      }
    }, 45000);
  }

  /**
   * Принять входящий звонок
   */
  async acceptCall() {
    if (this.callState !== 'ringing') return;

    // Clear ringing timeout
    if (this._ringingTimeout) {
      clearTimeout(this._ringingTimeout);
      this._ringingTimeout = null;
    }

    // Initialize voice if not already
    if (!this.voice) {
      this.initVoice();
    }
    if (!this.voice) {
      this.addSystemMessage('Ошибка инициализации звонка');
      this.sendEncryptedControl({ type: 'call-response', accepted: false });
      this.callState = 'idle';
      this.updateCallUI('idle');
      return;
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
        const track = this.voice.localStream.getAudioTracks()[0];
        // Reuse existing sender if available
        if (this.voice.audioSender) {
          await this.voice.audioSender.replaceTrack(track);
        } else {
          this.voice.audioSender = this.rtc.peerConnection.addTrack(track, this.voice.localStream);
        }
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

      // Soft cleanup — keep voice instance for reuse
      if (this.rtc) this.rtc._suppressNegotiation = true;
      if (this.voice) {
        this.voice.endCall();
      }
      this._cleanupRemoteAudio();
      this._remoteStream = null;
      this.callState = 'idle';
      this.pendingRenegotiationOffer = null;
      if (this.rtc) this.rtc._suppressNegotiation = false;
      this.updateCallUI('idle');
    }
  }

  /**
   * Отклонить входящий звонок
   */
  declineCall() {
    if (this.callState !== 'ringing') return;

    // Clear ringing timeout
    if (this._ringingTimeout) {
      clearTimeout(this._ringingTimeout);
      this._ringingTimeout = null;
    }

    // Notify peer through E2E
    this.sendEncryptedControl({ type: 'call-response', accepted: false });

    // Suppress renegotiation during cleanup
    if (this.rtc) this.rtc._suppressNegotiation = true;

    // Soft cleanup — keep voice instance and transceiver for reuse
    if (this.voice) {
      this.voice.endCall();
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

    // Clear caller-side timeout
    if (this._callingTimeout) {
      clearTimeout(this._callingTimeout);
      this._callingTimeout = null;
    }

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
      // Suppress renegotiation before cleanup
      if (this.rtc) this.rtc._suppressNegotiation = true;
      // Soft cleanup — keep voice instance and transceiver for reuse
      if (this.voice) {
        this.voice.endCall();
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

    // Clear caller-side timeout
    if (this._callingTimeout) {
      clearTimeout(this._callingTimeout);
      this._callingTimeout = null;
    }

    // Notify peer BEFORE cleaning up
    this.sendEncryptedControl({ type: 'call-end' });

    // Suppress renegotiation during cleanup
    if (this.rtc) this.rtc._suppressNegotiation = true;

    // Soft cleanup — keep voice instance and transceiver for reuse
    if (this.voice) {
      this.voice.endCall();
    }

    this._cleanupRemoteAudio();
    this._remoteStream = null;

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
    // Clear ringing timeout (peer may end call while we're ringing)
    if (this._ringingTimeout) {
      clearTimeout(this._ringingTimeout);
      this._ringingTimeout = null;
    }

    // Clear caller-side timeout (peer may end call while we're calling)
    if (this._callingTimeout) {
      clearTimeout(this._callingTimeout);
      this._callingTimeout = null;
    }

    // Suppress renegotiation during cleanup
    if (this.rtc) this.rtc._suppressNegotiation = true;

    try {
      // Soft cleanup — keep voice instance and transceiver for reuse
      if (this.voice) {
        this.voice.endCall();
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

    // Helper: reliable play via <audio> element with autoplay fallback
    const playViaAudioElement = () => {
      this.elements.remoteAudio.srcObject = stream;
      // autoplay attribute handles most cases; explicit play() as backup
      const p = this.elements.remoteAudio.play();
      if (p) p.catch(e => logger.warn('Audio play() failed:', e.message));
    };

    if (platform === 'desktop') {
      // Desktop: всегда через <audio>, выбор устройства через setSinkId
      playViaAudioElement();
      return;
    }

    // Мобильные (iOS + Android)
    if (speakerMode) {
      // ДИНАМИК: <audio> элемент на мобильных играет через громкоговоритель
      playViaAudioElement();
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

        // Safety net: if AudioContext stays suspended, fallback to <audio>
        setTimeout(() => {
          if (this._remoteAudioCtx && this._remoteAudioCtx.state === 'suspended') {
            logger.warn('AudioContext stuck suspended, falling back to <audio>');
            this._cleanupRemoteAudio();
            playViaAudioElement();
          }
        }, 1500);

        logger.log(`Audio output: earpiece via AudioContext (${platform})`);
      } catch (e) {
        logger.warn('AudioContext earpiece failed, fallback to <audio>:', e);
        // Fallback: <audio> element + setSinkId на Android
        playViaAudioElement();
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
    this._stopAudioHealthCheck();
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
   * Периодическая проверка здоровья аудио — восстановление после suspend
   * Браузеры могут приостановить AudioContext при power management
   */
  _startAudioHealthCheck() {
    this._stopAudioHealthCheck();
    this._audioHealthInterval = setInterval(() => {
      if (!this.voice?.isInCall || !this._remoteStream) return;

      // Проверяем AudioContext
      if (this._remoteAudioCtx && this._remoteAudioCtx.state === 'suspended') {
        logger.warn('AudioContext suspended — resuming');
        this._remoteAudioCtx.resume().catch(() => {});
      }

      // Проверяем что remote audio track жив
      const remoteTracks = this._remoteStream.getAudioTracks();
      if (remoteTracks.length > 0 && remoteTracks[0].readyState === 'ended') {
        logger.warn('Remote audio track ended unexpectedly');
      }

      // Проверяем <audio> element
      const audio = this.elements.remoteAudio;
      if (audio && audio.srcObject && audio.paused) {
        logger.warn('Audio element paused — resuming');
        audio.play().catch(() => {});
      }
    }, 3000);
  }

  _stopAudioHealthCheck() {
    if (this._audioHealthInterval) {
      clearInterval(this._audioHealthInterval);
      this._audioHealthInterval = null;
    }
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
        this.elements.callTimer.textContent = '00:00';
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
    const validSeverities = ['high', 'medium', 'low'];
    const sev = validSeverities.includes(alert.severity) ? alert.severity : 'medium';
    alertEl.className = `security-alert severity-${sev}`;

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
      // crypto.decrypt() unwraps {m,t,c,id} meta → returns plaintext (m)
      // crypto.lastDecryptedId has the sender message ID
      const plaintext = await this.crypto.decrypt(encryptedData);

      // Control messages are wrapped with _ctrl=true — check if plaintext is one
      try {
        const msg = JSON.parse(plaintext);
        if (msg._ctrl) {
          if (msg.type) await this.handleControlMessage(msg);
          return;
        }
      } catch {
        // Not JSON control — it's a regular text message
      }

      // Regular message — display with sender ID from crypto meta
      this.handlePeerTyping(false);
      const senderMsgId = this.crypto.lastDecryptedId || null;
      const replyMeta = this.crypto.lastDecryptedReply; // { id, t } or null
      this.addMessage(plaintext, 'received', senderMsgId, replyMeta);

      // ACK + read
      const counter = this.crypto.peerMessageCounter;
      this.sendEncryptedControl({ type: 'message-ack', c: counter });
      this.sendEncryptedControl({ type: 'message-read', c: counter });
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
      case 'message-read':
        // Mark message as read (ignore on web for now)
        break;
      case 'ready':
        // Bootstrap from host — decryption already triggered DH ratchet
        break;
      case 'push-token':
      case 'notify-token':
        // Mobile peer's push token — ignore on web
        break;
      case 'typing':
        this.handlePeerTyping(msg.isTyping);
        break;
      case 'capabilities':
        // Mobile peer's capabilities — track file-transfer support
        this._peerSupportsFiles = msg.features?.includes('file-transfer') ?? false;
        break;
      case 'file-start':
        this.handleFileStart(msg);
        break;
      case 'file-chunk':
        this.handleFileChunk(msg);
        break;
      case 'file-complete':
        this.handleFileComplete(msg);
        break;
      case 'file-retransmit':
        this.handleFileRetransmit(msg);
        break;
      case 'room-rotate':
        // Room rotation — ignore on web
        break;
      case 'message-delete':
        // Mobile peer deleted a message — remove from DOM
        if (msg.messageId) this.handleRemoteMessageDelete(msg.messageId);
        break;
      case 'message-edit':
        // Mobile peer edited a message — update text + show "edited"
        if (msg.messageId && msg.newText) this.handleRemoteMessageEdit(msg.messageId, msg.newText);
        break;
      case 'message-pin':
        // Pinned messages — web displays but doesn't persist (no DB)
        break;
    }
  }

  /**
   * Remove a message from chat by sender's message ID
   */
  handleRemoteMessageDelete(senderMessageId) {
    const el = document.querySelector(`[data-sender-id="${CSS.escape(senderMessageId)}"]`);
    if (el) el.remove();
  }

  /**
   * Update message text and show "edited" label
   */
  handleRemoteMessageEdit(senderMessageId, newText) {
    const el = document.querySelector(`[data-sender-id="${CSS.escape(senderMessageId)}"]`);
    if (el) {
      const textEl = el.querySelector('.message-content');
      if (textEl) textEl.innerHTML = this.formatMessageText(newText);
      // Add "edited" label if not already present
      if (!el.querySelector('.edited-label')) {
        const label = document.createElement('span');
        label.className = 'edited-label';
        label.textContent = ' (edited)';
        label.style.cssText = 'font-size:10px;color:#777;margin-left:4px;';
        const meta = el.querySelector('.message-meta') || el.querySelector('.msg-time');
        if (meta) meta.appendChild(label);
      }
    }
  }

  // MARK: - File Transfer (receive from mobile)

  handleFileStart(msg) {
    const { fileId, name, size, mimeType, totalChunks } = msg;
    if (!fileId || !name || size > 100 * 1024 * 1024) return; // 100MB max
    this._incomingFiles = this._incomingFiles || {};
    this._incomingFiles[fileId] = {
      name: name.replace(/[\/\\]/g, '_').replace(/\.\./g, '_'),
      size, mimeType, totalChunks,
      chunks: {},
      receivedCount: 0
    };
    this.addSystemMessage(`📎 Получение файла: ${name} (${this._formatSize(size)})...`);
  }

  handleFileChunk(msg) {
    const { fileId, index, data } = msg;
    if (!this._incomingFiles?.[fileId]) return;
    const transfer = this._incomingFiles[fileId];
    transfer.chunks[index] = data; // base64 chunk
    transfer.receivedCount++;
  }

  handleFileRetransmit(msg) {
    const { fileId, indices } = msg;
    const transfer = this._outgoingFiles?.[fileId];
    if (!transfer || !transfer.data) return;
    logger.log(`[FileTransfer] Retransmit ${indices.length} chunks for ${fileId}`);
    const CHUNK = GhostChat.FILE_CHUNK_SIZE;
    for (const i of indices) {
      const start = i * CHUNK;
      const end = Math.min(start + CHUNK, transfer.data.byteLength);
      if (start >= transfer.data.byteLength) continue;
      const chunk = transfer.data.slice(start, end);
      const b64 = this._uint8ToBase64(new Uint8Array(chunk));
      this.sendEncryptedControl({ type: 'file-chunk', fileId, index: i, data: b64 });
    }
    this.sendEncryptedControl({ type: 'file-complete', fileId });
  }

  handleFileComplete(msg) {
    const { fileId } = msg;
    const transfer = this._incomingFiles?.[fileId];
    if (!transfer) return;

    // Check for missing chunks → request retransmit
    const missing = [];
    for (let i = 0; i < transfer.totalChunks; i++) {
      if (!transfer.chunks[i]) missing.push(i);
    }
    if (missing.length > 0) {
      transfer.retryCount = (transfer.retryCount || 0) + 1;
      if (transfer.retryCount <= 2) {
        logger.log(`[FileTransfer] Requesting retransmit: ${missing.length} chunks`);
        this.sendEncryptedControl({ type: 'file-retransmit', fileId, indices: missing });
        return; // Wait for retransmitted chunks + another file-complete
      }
      this.addSystemMessage('⚠️ Ошибка получения файла');
      delete this._incomingFiles[fileId];
      return;
    }

    delete this._incomingFiles[fileId];

    // Собираем из base64 chunks
    try {
      const parts = [];
      for (let i = 0; i < transfer.totalChunks; i++) {
        const b64 = transfer.chunks[i];
        if (!b64) { this.addSystemMessage('⚠️ Ошибка получения файла: пропущен чанк'); return; }
        const binary = atob(b64);
        const bytes = new Uint8Array(binary.length);
        for (let j = 0; j < binary.length; j++) bytes[j] = binary.charCodeAt(j);
        parts.push(bytes);
      }
      const blob = new Blob(parts, { type: transfer.mimeType || 'application/octet-stream' });
      const url = URL.createObjectURL(blob);

      // Отображаем файл в чате
      if (transfer.mimeType?.startsWith('image/')) {
        this._addFileMessage(url, transfer.name, transfer.size, transfer.mimeType, 'image');
      } else if (transfer.mimeType?.startsWith('video/')) {
        this._addFileMessage(url, transfer.name, transfer.size, transfer.mimeType, 'video');
      } else {
        this._addFileMessage(url, transfer.name, transfer.size, transfer.mimeType, 'file');
      }
    } catch (e) {
      this.addSystemMessage('⚠️ Ошибка сборки файла');
    }
  }

  _addFileMessage(url, name, size, mimeType, fileType) {
    const container = this.elements.messagesContainer;
    const wrapper = document.createElement('div');
    wrapper.className = 'message received';

    if (fileType === 'image') {
      const img = document.createElement('img');
      img.src = url;
      img.alt = name;
      img.style.maxWidth = '280px';
      img.style.maxHeight = '280px';
      img.style.borderRadius = '12px';
      img.style.cursor = 'pointer';
      img.onclick = () => window.open(url, '_blank');
      wrapper.appendChild(img);
    } else if (fileType === 'video') {
      const video = document.createElement('video');
      video.src = url;
      video.controls = true;
      video.style.maxWidth = '280px';
      video.style.borderRadius = '12px';
      wrapper.appendChild(video);
    } else {
      const link = document.createElement('a');
      link.href = url;
      link.download = name;
      link.textContent = `📎 ${name} (${this._formatSize(size)})`;
      link.style.color = '#f0f0f0';
      link.style.textDecoration = 'underline';
      wrapper.appendChild(link);
    }

    const time = document.createElement('span');
    time.className = 'message-time';
    time.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    wrapper.appendChild(time);

    container.appendChild(wrapper);
    container.scrollTop = container.scrollHeight;
  }

  _formatSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  /** Sanitize filename for safe display (strip path + control chars, cap length) */
  _sanitizeFilename(name) {
    if (!name) return 'file';
    let clean = String(name).replace(/[\/\\]/g, '_').replace(/\.\./g, '_');
    clean = clean.replace(/[\x00-\x1f\x7f]/g, '');
    if (clean.length > 120) clean = clean.slice(0, 117) + '...';
    return clean || 'file';
  }

  /** Efficient Uint8Array → base64 (chunked to avoid call-stack issues on large data) */
  _uint8ToBase64(bytes) {
    let binary = '';
    const len = bytes.byteLength;
    const CHUNK = 0x8000; // 32KB slices for String.fromCharCode.apply
    for (let i = 0; i < len; i += CHUNK) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(binary);
  }

  /**
   * Send a file over the encrypted DataChannel.
   * Protocol: file-start control → file-chunk controls → file-complete control.
   * Uses bufferedAmount backpressure to prevent SCTP overflow.
   */
  async sendFile(file) {
    if (!file || !this.isConnected) {
      this.showToast('Нет соединения');
      return;
    }
    // Max file size — aligned with iOS/Android (100 MB)
    const MAX_SIZE = 100 * 1024 * 1024;
    if (file.size > MAX_SIZE) {
      this.showToast(`Файл слишком большой (макс. ${this._formatSize(MAX_SIZE)})`);
      return;
    }
    if (file.size === 0) {
      this.showToast('Пустой файл');
      return;
    }
    // Check peer capability — mobile peers advertise file-transfer; web peers we treat as supported
    if (this._peerSupportsFiles === false) {
      this.showToast('Собеседник не поддерживает отправку файлов');
      return;
    }

    const fileId = (crypto.randomUUID ? crypto.randomUUID() : (Date.now() + '-' + Math.random()));
    const cleanName = this._sanitizeFilename(file.name);
    const mimeType = file.type || 'application/octet-stream';

    // Read file fully into ArrayBuffer
    let buffer;
    try {
      buffer = await file.arrayBuffer();
    } catch (e) {
      logger.error('Failed to read file:', e);
      this.showToast('Не удалось прочитать файл');
      return;
    }
    const data = new Uint8Array(buffer);
    const CHUNK = GhostChat.FILE_CHUNK_SIZE;
    const totalChunks = Math.max(1, Math.ceil(data.byteLength / CHUNK));

    // Track outgoing transfer (used by retransmit path)
    this._outgoingFiles = this._outgoingFiles || {};
    this._outgoingFiles[fileId] = { data, name: cleanName, size: file.size, mimeType, totalChunks };

    // Build placeholder "sending" bubble with progress
    const placeholder = this._createFileSendingPlaceholder(cleanName, file.size, mimeType);
    this.elements.messagesContainer.appendChild(placeholder.root);
    this.elements.messagesContainer.scrollTop = this.elements.messagesContainer.scrollHeight;

    try {
      // 1) file-start
      const startOk = await this.sendEncryptedControl({
        type: 'file-start',
        fileId,
        name: cleanName,
        size: file.size,
        mimeType,
        totalChunks
      });
      if (!startOk) throw new Error('file-start send failed');

      // 2) file-chunks with backpressure
      const BACKPRESSURE_LIMIT = 256 * 1024; // 256KB high-water mark (task spec)
      const BACKPRESSURE_TIMEOUT = 30000;
      const dc = this.rtc?.dataChannel;

      for (let i = 0; i < totalChunks; i++) {
        // Wait for bufferedAmount to drain below threshold
        if (dc) {
          const waitStart = Date.now();
          while (dc.readyState === 'open' && dc.bufferedAmount > BACKPRESSURE_LIMIT) {
            if (Date.now() - waitStart > BACKPRESSURE_TIMEOUT) {
              throw new Error('Backpressure timeout');
            }
            await new Promise(r => setTimeout(r, 25));
          }
          if (dc.readyState !== 'open') throw new Error('DataChannel closed');
        }

        const start = i * CHUNK;
        const end = Math.min(start + CHUNK, data.byteLength);
        const b64 = this._uint8ToBase64(data.subarray(start, end));
        const ok = await this.sendEncryptedControl({
          type: 'file-chunk', fileId, index: i, data: b64
        });
        if (!ok) throw new Error(`Chunk ${i} send failed`);

        // Update progress bar
        const pct = Math.round(((i + 1) / totalChunks) * 100);
        placeholder.setProgress(pct);
      }

      // 3) file-complete
      await this.sendEncryptedControl({ type: 'file-complete', fileId });

      // Replace placeholder with final rendered message
      placeholder.root.remove();
      const url = URL.createObjectURL(new Blob([data], { type: mimeType }));
      if (mimeType.startsWith('image/')) {
        this._addOutgoingFileBubble(url, cleanName, file.size, mimeType, 'image');
      } else if (mimeType.startsWith('video/')) {
        this._addOutgoingFileBubble(url, cleanName, file.size, mimeType, 'video');
      } else {
        this._addOutgoingFileBubble(url, cleanName, file.size, mimeType, 'file');
      }
    } catch (e) {
      logger.error('[FileTransfer] send failed:', e);
      placeholder.setError('Ошибка отправки');
      this.showToast('Ошибка отправки файла');
      // Leave transfer state around in case retransmit arrives; auto-cleanup after 5 min
      setTimeout(() => { if (this._outgoingFiles) delete this._outgoingFiles[fileId]; }, 5 * 60 * 1000);
      return;
    }

    // Keep outgoing data around briefly in case peer requests retransmit
    setTimeout(() => { if (this._outgoingFiles) delete this._outgoingFiles[fileId]; }, 60 * 1000);
  }

  /** Build a "sending..." bubble with progress bar. Returns { root, setProgress, setError } */
  _createFileSendingPlaceholder(name, size, mimeType) {
    const root = document.createElement('div');
    root.className = 'message sent';

    const att = document.createElement('div');
    att.className = 'file-attachment';

    const icon = document.createElement('div');
    icon.className = 'file-attachment-icon';
    icon.textContent = mimeType?.startsWith('image/') ? '🖼' : (mimeType?.startsWith('video/') ? '🎬' : '📎');

    const meta = document.createElement('div');
    meta.className = 'file-attachment-meta';

    const nameEl = document.createElement('span');
    nameEl.className = 'file-attachment-name';
    nameEl.textContent = name;

    const sub = document.createElement('span');
    sub.className = 'file-attachment-sub';
    sub.textContent = `${this._formatSize(size)} · отправка 0%`;

    const progress = document.createElement('div');
    progress.className = 'file-progress';
    const fill = document.createElement('div');
    fill.className = 'file-progress-fill';
    progress.appendChild(fill);

    meta.appendChild(nameEl);
    meta.appendChild(sub);
    meta.appendChild(progress);
    att.appendChild(icon);
    att.appendChild(meta);
    root.appendChild(att);

    const time = document.createElement('div');
    time.className = 'message-time';
    time.textContent = new Date().toLocaleTimeString();
    root.appendChild(time);

    return {
      root,
      setProgress: (pct) => {
        fill.style.width = `${pct}%`;
        sub.textContent = `${this._formatSize(size)} · отправка ${pct}%`;
      },
      setError: (msg) => {
        sub.textContent = `${this._formatSize(size)} · ${msg}`;
        fill.style.background = '#ff453a';
      }
    };
  }

  /** Render final outgoing file bubble (after send complete) */
  _addOutgoingFileBubble(url, name, size, mimeType, fileType) {
    const container = this.elements.messages || this.elements.messagesContainer;
    const wrapper = document.createElement('div');
    wrapper.className = 'message sent';

    if (fileType === 'image') {
      const img = document.createElement('img');
      img.src = url;
      img.alt = name;
      img.style.maxWidth = '280px';
      img.style.maxHeight = '280px';
      img.style.borderRadius = '12px';
      img.style.cursor = 'pointer';
      img.addEventListener('click', () => window.open(url, '_blank'));
      wrapper.appendChild(img);
    } else if (fileType === 'video') {
      const video = document.createElement('video');
      video.src = url;
      video.controls = true;
      video.style.maxWidth = '280px';
      video.style.borderRadius = '12px';
      wrapper.appendChild(video);
    } else {
      const link = document.createElement('a');
      link.href = url;
      link.download = name;
      link.textContent = `📎 ${name} (${this._formatSize(size)})`;
      link.style.color = '#0a0a0a';
      link.style.textDecoration = 'underline';
      wrapper.appendChild(link);
    }

    const time = document.createElement('span');
    time.className = 'message-time';
    time.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    wrapper.appendChild(time);

    container.appendChild(wrapper);
    container.scrollTop = container.scrollHeight;
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
    if (!sdp || !['offer', 'answer'].includes(sdp.type)) {
      logger.error('Invalid renegotiation SDP type');
      return;
    }

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
        try {
          await this.rtc.handleAnswer(sdp);
        } catch (answerErr) {
          logger.error('handleAnswer failed:', answerErr);
          // Try to recover: if signaling state is wrong, reset suppression
          this.rtc._suppressNegotiation = false;
          return;
        }
        this.rtc._suppressNegotiation = false;

        // Auto-transition: receiving a renegotiation answer means callee accepted
        // and sent their audio. Don't wait for explicit call-response message
        // (which may be delayed or lost due to ratchet timing)
        if (this.callState === 'calling') {
          this.handleCallResponse(true);
        }
      }
    } catch (e) {
      logger.error('Renegotiation error:', e);
      // Ensure suppression is cleared even on error
      if (this.rtc) this.rtc._suppressNegotiation = false;
    }
  }

  /**
   * Process a renegotiation offer - add our audio and send answer
   *
   * CRITICAL: Order matters for bidirectional audio!
   * 1. setRemoteDescription(offer) — creates transceiver from offer's audio m-line
   * 2. addTrack — reuses existing transceiver (direction becomes sendrecv)
   * 3. createAnswer — includes our audio as sendrecv
   *
   * Wrong order (addTrack before setRemoteDescription) creates a NEW transceiver,
   * and the answer SDP has recvonly — one-way audio (walkie-talkie bug).
   */
  async processRenegotiationOffer(sdp) {
    // Suppress automatic onnegotiationneeded — addTrack would trigger a conflicting offer
    this.rtc._suppressNegotiation = true;

    try {
      // Step 1: Set the remote offer — this creates transceivers for the caller's audio
      await this.rtc.peerConnection.setRemoteDescription(new RTCSessionDescription(sdp));

      // Step 2: Add our audio track — reuses the offer's transceiver (sendrecv)
      if (this.voice && !this.voice.localStream) {
        logger.log('Adding our audio track after setRemoteDescription');
        try {
          await this.voice.initializeAudio();
          const track = this.voice.localStream.getAudioTracks()[0];
          // Reuse existing sender if available (prevents transceiver accumulation)
          if (this.voice.audioSender) {
            await this.voice.audioSender.replaceTrack(track);
            logger.log('Audio track replaced on existing sender (renegotiation)');
          } else {
            this.voice.audioSender = this.rtc.peerConnection.addTrack(track, this.voice.localStream);
            logger.log('Audio track added (renegotiation)');
          }
          this.voice.startSecurityMonitoring();
        } catch (e) {
          logger.error('Failed to add audio track:', e);
        }
      }

      // Step 3: Create answer with our audio included as sendrecv
      const answer = await this.rtc.peerConnection.createAnswer();
      await this.rtc.peerConnection.setLocalDescription(answer);

      // Send the answer back through E2E encrypted channel
      const encrypted = await this.crypto.encrypt(JSON.stringify({
        type: 'renegotiate',
        sdp: this.rtc.peerConnection.localDescription,
        _ctrl: true
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

    // If we're editing an existing message, send edit control instead
    if (this._editingMessageId) {
      const sid = this._editingMessageId;
      const el = this._editingOriginalEl;
      this._editingMessageId = null;
      this._editingOriginalEl = null;
      this.elements.messageInput.value = '';
      this.elements.messageInput.placeholder = 'Сообщение...';
      if (el) {
        const contentEl = el.querySelector('.message-content');
        if (contentEl) contentEl.innerHTML = this.formatMessageText(text);
        if (!el.querySelector('.edited-label')) {
          const label = document.createElement('span');
          label.className = 'edited-label';
          label.textContent = ' (изм.)';
          label.style.cssText = 'font-size:10px;color:#777;margin-left:4px;';
          el.querySelector('.message-time')?.appendChild(label);
        }
      }
      this.sendEncryptedControl({ type: 'message-edit', messageId: sid, newText: text });
      return;
    }

    // Stop typing indicator on send
    this.stopTyping();

    // Capture reply state before clearing UI
    const reply = this.replyingTo;
    this.cancelReply();

    try {
      // crypto.encrypt wraps in {m, t, c, id, r?} — pass raw text + options
      const msgId = crypto.randomUUID();
      const encryptOpts = { id: msgId };
      if (reply && reply.id) {
        encryptOpts.r = { id: reply.id, t: String(reply.text || '').slice(0, 100) };
      }
      const encrypted = await this.crypto.encrypt(text, encryptOpts);

      this.rtc.send(JSON.stringify({
        type: 'encrypted-message',
        data: encrypted,
        v: 2
      }));

      const div = this.addMessage(text, 'sent', msgId, reply ? { id: reply.id, t: reply.text } : null);
      // Tracking доставки по счётчику
      this.sentMessages.set(this.crypto.messageCounter, div);
      this.elements.messageInput.value = '';
    } catch (e) {
      logger.error('Error sending message:', e);
      this.addSystemMessage('Ошибка отправки');
    }
  }

  /**
   * Start replying to a message — shows preview bar above input
   */
  startReply(senderMessageId, previewText) {
    if (!senderMessageId) return;
    this.replyingTo = { id: senderMessageId, text: String(previewText || '').slice(0, 200) };
    if (this.elements.replyPreview && this.elements.replyPreviewText) {
      this.elements.replyPreviewText.textContent = this.replyingTo.text;
      this.elements.replyPreview.classList.remove('hidden');
    }
    // Focus input so user can type immediately
    try { this.elements.messageInput.focus(); } catch {}
  }

  /**
   * Cancel active reply state and hide preview bar
   */
  cancelReply() {
    this.replyingTo = null;
    if (this.elements.replyPreview) {
      this.elements.replyPreview.classList.add('hidden');
    }
    if (this.elements.replyPreviewText) {
      this.elements.replyPreviewText.textContent = '';
    }
  }

  /**
   * Добавление сообщения в чат с автоудалением
   * Возвращает DOM-элемент сообщения (для tracking доставки)
   */
  addMessage(text, type, senderMessageId = null, replyMeta = null) {
    const div = document.createElement('div');
    div.className = `message ${type}`;
    if (senderMessageId) div.setAttribute('data-sender-id', senderMessageId);

    // Inline quoted block (if this message is a reply)
    if (replyMeta && (replyMeta.t || replyMeta.id)) {
      const quote = document.createElement('div');
      quote.className = 'message-quote';
      if (replyMeta.id) quote.setAttribute('data-reply-to', replyMeta.id);
      const qLabel = document.createElement('span');
      qLabel.className = 'message-quote-label';
      qLabel.textContent = 'Ответ';
      const qText = document.createElement('span');
      qText.className = 'message-quote-text';
      qText.textContent = String(replyMeta.t || '').slice(0, 200);
      quote.appendChild(qLabel);
      quote.appendChild(qText);
      // Click quote → scroll to original message
      quote.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!replyMeta.id) return;
        const target = document.querySelector(`[data-sender-id="${CSS.escape(replyMeta.id)}"]`);
        if (target) {
          target.scrollIntoView({ behavior: 'smooth', block: 'center' });
          target.classList.add('message-highlight');
          setTimeout(() => target.classList.remove('message-highlight'), 1200);
        }
      });
      div.appendChild(quote);
    }

    const content = document.createElement('div');
    content.className = 'message-content';
    content.innerHTML = this.formatMessageText(text);

    const time = document.createElement('div');
    time.className = 'message-time';
    time.textContent = new Date().toLocaleTimeString();

    div.appendChild(content);
    div.appendChild(time);

    // Автоудаление только если включено (> 0)
    if (this.messageAutoDeleteTime > 0) {
      const timer = document.createElement('div');
      timer.className = 'message-timer';
      const mins = Math.floor(this.messageAutoDeleteTime / 60000);
      timer.textContent = `⏱️ ${mins}:00`;
      div.appendChild(timer);

      this.activeMessageTimers.push({
        messageEl: div,
        timerEl: timer,
        endTime: Date.now() + this.messageAutoDeleteTime
      });
      this.startMessageTimerLoop();
    }

    // Context menu (right-click, desktop) — copy, delete, edit, reply
    div.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      this.showMessageContextMenu(e, div, type, senderMessageId);
    });

    // Mobile long-press + swipe-to-reply
    this._attachTouchHandlers(div, type, senderMessageId);

    this.elements.messagesContainer.appendChild(div);
    this.elements.messagesContainer.scrollTop = this.elements.messagesContainer.scrollHeight;

    return div;
  }

  /**
   * Attach touch handlers for: long-press (context menu) + horizontal swipe (reply)
   */
  _attachTouchHandlers(el, type, senderMessageId) {
    const LONG_PRESS_MS = 600;
    const MOVE_CANCEL_PX = 10;
    const SWIPE_TRIGGER_PX = 60;
    const SWIPE_MAX_PX = 90;

    let touchStartX = 0;
    let touchStartY = 0;
    let longPressTimer = null;
    let didLongPress = false;
    let swiping = false;
    let currentDX = 0;

    const clearLongPress = () => {
      if (longPressTimer) {
        clearTimeout(longPressTimer);
        longPressTimer = null;
      }
      el.classList.remove('long-pressing');
    };

    el.addEventListener('touchstart', (e) => {
      if (e.touches.length !== 1) return;
      const t = e.touches[0];
      touchStartX = t.clientX;
      touchStartY = t.clientY;
      didLongPress = false;
      swiping = false;
      currentDX = 0;
      el.classList.remove('swipe-snapback');

      longPressTimer = setTimeout(() => {
        didLongPress = true;
        el.classList.add('long-pressing');
        // Haptic feedback if available
        if (navigator.vibrate) { try { navigator.vibrate(12); } catch {} }
        // Show context menu positioned at touch point
        this.showMessageContextMenu(
          { preventDefault: () => {}, clientX: touchStartX, clientY: touchStartY },
          el, type, senderMessageId
        );
        longPressTimer = null;
      }, LONG_PRESS_MS);
    }, { passive: true });

    el.addEventListener('touchmove', (e) => {
      if (e.touches.length !== 1) return;
      const t = e.touches[0];
      const dx = t.clientX - touchStartX;
      const dy = t.clientY - touchStartY;

      // Cancel long-press if moved too much
      if (longPressTimer && (Math.abs(dx) > MOVE_CANCEL_PX || Math.abs(dy) > MOVE_CANCEL_PX)) {
        clearLongPress();
      }

      // Swipe-to-reply: only right-swipes, only if mostly horizontal
      if (!swiping && Math.abs(dx) > MOVE_CANCEL_PX && Math.abs(dx) > Math.abs(dy) * 1.5 && dx > 0) {
        swiping = true;
        el.classList.add('swiping');
      }
      if (swiping) {
        currentDX = Math.max(0, Math.min(dx, SWIPE_MAX_PX));
        el.style.transform = `translateX(${currentDX}px)`;
        // Prevent vertical scroll while swiping horizontally
        if (e.cancelable) e.preventDefault();
      }
    }, { passive: false });

    el.addEventListener('touchend', () => {
      clearLongPress();
      if (swiping) {
        el.classList.remove('swiping');
        el.classList.add('swipe-snapback');
        el.style.transform = '';
        setTimeout(() => el.classList.remove('swipe-snapback'), 260);
        if (currentDX >= SWIPE_TRIGGER_PX) {
          // Trigger reply
          if (navigator.vibrate) { try { navigator.vibrate(8); } catch {} }
          const quoted = el.querySelector('.message-content')?.textContent || '';
          const id = senderMessageId || el.getAttribute('data-sender-id');
          if (id) this.startReply(id, quoted);
        }
      }
    });

    el.addEventListener('touchcancel', () => {
      clearLongPress();
      if (swiping) {
        swiping = false;
        el.classList.remove('swiping');
        el.style.transform = '';
      }
    });
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
          entry.messageEl.classList.add('message-deleting');
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
      toast.classList.add('toast-fading');
      setTimeout(() => toast.remove(), 300);
    }, 3000);
  }

  /**
   * Context menu для сообщений (правый клик)
   */
  showMessageContextMenu(e, msgEl, type, senderMessageId) {
    // Remove existing menu
    document.querySelectorAll('.msg-context-menu').forEach(m => m.remove());

    const menu = document.createElement('div');
    menu.className = 'msg-context-menu';
    menu.style.cssText = `position:fixed;top:${e.clientY}px;left:${e.clientX}px;background:#222;border:1px solid #333;border-radius:8px;padding:4px 0;z-index:1000;min-width:160px;box-shadow:0 4px 16px rgba(0,0,0,0.5);`;

    const textContent = msgEl.querySelector('.message-content')?.textContent || '';

    // Reply — available for any message with a sender ID
    if (senderMessageId) {
      const replyBtn = document.createElement('div');
      replyBtn.textContent = '↩ Ответить';
      replyBtn.style.cssText = 'padding:8px 16px;cursor:pointer;color:#f0f0f0;font-size:13px;';
      replyBtn.onmouseenter = () => replyBtn.style.background = '#333';
      replyBtn.onmouseleave = () => replyBtn.style.background = '';
      replyBtn.onclick = () => {
        this.startReply(senderMessageId, textContent);
        menu.remove();
      };
      menu.appendChild(replyBtn);
    }

    // Copy
    const copyBtn = document.createElement('div');
    copyBtn.textContent = '📋 Копировать';
    copyBtn.style.cssText = 'padding:8px 16px;cursor:pointer;color:#f0f0f0;font-size:13px;';
    copyBtn.onmouseenter = () => copyBtn.style.background = '#333';
    copyBtn.onmouseleave = () => copyBtn.style.background = '';
    copyBtn.onclick = () => { navigator.clipboard.writeText(msgEl.querySelector('.message-content')?.innerText || textContent); menu.remove(); };
    menu.appendChild(copyBtn);

    // Delete for everyone (own messages only)
    if (type === 'sent' && senderMessageId) {
      const delBtn = document.createElement('div');
      delBtn.textContent = '🗑 Удалить для всех';
      delBtn.style.cssText = 'padding:8px 16px;cursor:pointer;color:#ff453a;font-size:13px;';
      delBtn.onmouseenter = () => delBtn.style.background = '#333';
      delBtn.onmouseleave = () => delBtn.style.background = '';
      delBtn.onclick = () => {
        msgEl.remove();
        this.sendEncryptedControl({ type: 'message-delete', messageId: senderMessageId });
        menu.remove();
      };
      menu.appendChild(delBtn);
    }

    // Edit (own messages only)
    if (type === 'sent' && senderMessageId) {
      const editBtn = document.createElement('div');
      editBtn.textContent = '✏️ Редактировать';
      editBtn.style.cssText = 'padding:8px 16px;cursor:pointer;color:#f0f0f0;font-size:13px;';
      editBtn.onmouseenter = () => editBtn.style.background = '#333';
      editBtn.onmouseleave = () => editBtn.style.background = '';
      editBtn.onclick = () => {
        menu.remove();
        const newText = prompt('Редактировать сообщение:', textContent);
        if (newText && newText.trim() !== textContent) {
          const contentEl = msgEl.querySelector('.message-content');
          if (contentEl) contentEl.innerHTML = this.formatMessageText(newText.trim());
          // Add "edited" label
          if (!msgEl.querySelector('.edited-label')) {
            const label = document.createElement('span');
            label.className = 'edited-label';
            label.textContent = ' (изм.)';
            label.style.cssText = 'font-size:10px;color:#777;margin-left:4px;';
            msgEl.querySelector('.message-time')?.appendChild(label);
          }
          this.sendEncryptedControl({ type: 'message-edit', messageId: senderMessageId, newText: newText.trim() });
        }
      };
      menu.appendChild(editBtn);
    }

    document.body.appendChild(menu);

    // Clamp position inside viewport (important for mobile long-press)
    requestAnimationFrame(() => {
      const rect = menu.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      let left = parseFloat(menu.style.left) || rect.left;
      let top = parseFloat(menu.style.top) || rect.top;
      if (left + rect.width > vw - 8) left = Math.max(8, vw - rect.width - 8);
      if (top + rect.height > vh - 8) top = Math.max(8, vh - rect.height - 8);
      menu.style.left = `${left}px`;
      menu.style.top = `${top}px`;
    });

    // Close on click or touch outside
    const closeMenu = (ev) => {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener('click', closeMenu);
        document.removeEventListener('touchstart', closeMenu);
      }
    };
    setTimeout(() => {
      document.addEventListener('click', closeMenu);
      document.addEventListener('touchstart', closeMenu);
    }, 0);
  }

  /**
   * Light Telegram-style text formatting.
   * **bold** → <b>, *italic* → <i>, `code` → <code>, ~~strike~~ → <s>
   * XSS-safe: escapes HTML first, then applies formatting patterns.
   */
  formatMessageText(text) {
    // Step 1: Escape HTML to prevent XSS
    let s = text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
    // Step 2: Apply formatting (order matters — code first to protect inner content)
    // ```block``` → <pre><code>
    s = s.replace(/```([^`]+?)```/g, '<pre class="msg-code-block">$1</pre>');
    // `inline code` → <code>
    s = s.replace(/`([^`\n]+?)`/g, '<code class="msg-code">$1</code>');
    // **bold** → <b>
    s = s.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
    // *italic* → <i> (but not inside **)
    s = s.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, '<i>$1</i>');
    // ~~strikethrough~~ → <s>
    s = s.replace(/~~(.+?)~~/g, '<s>$1</s>');
    // Newlines → <br>
    s = s.replace(/\n/g, '<br>');
    return s;
  }

  /**
   * Disconnect banner — красная полоска "Собеседник отключился"
   */
  showDisconnectBanner(show) {
    let banner = document.getElementById('disconnect-banner');
    if (show) {
      if (!banner) {
        banner = document.createElement('div');
        banner.id = 'disconnect-banner';
        banner.innerHTML = `
          <span>⚡ Собеседник отключился. Ожидание переподключения...</span>
          <button onclick="document.getElementById('disconnect-banner').remove(); app.leave();">Выйти</button>
        `;
        banner.style.cssText = 'position:fixed;top:0;left:0;right:0;padding:12px 16px;background:rgba(255,69,58,0.15);color:#ff453a;display:flex;justify-content:space-between;align-items:center;z-index:999;font-size:13px;backdrop-filter:blur(10px);';
        banner.querySelector('button').style.cssText = 'background:rgba(255,69,58,0.2);color:#ff453a;border:1px solid #ff453a;border-radius:6px;padding:4px 12px;font-size:12px;cursor:pointer;';
        document.body.prepend(banner);
      }
      // Disable input
      if (this.elements.messageInput) this.elements.messageInput.disabled = true;
      if (this.elements.sendBtn) this.elements.sendBtn.disabled = true;
    } else {
      if (banner) banner.remove();
      // Re-enable input
      if (this.elements.messageInput) this.elements.messageInput.disabled = false;
      if (this.elements.sendBtn) this.elements.sendBtn.disabled = false;
    }
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
    // L5: Use query param (?room=) for Universal Links / App Links compatibility
    // Fragment links (#room=) still accepted as fallback (see checkInviteLink)
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
      if (feedback) feedback.classList.add('visible');
      setTimeout(() => {
        this.elements.copyBtn.classList.remove('copied');
        if (spanEl) spanEl.textContent = 'Скопировать ссылку';
        if (feedback) feedback.classList.remove('visible');
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
   * Показать выбор: открыть в приложении, установить или продолжить в браузере.
   * Шаблон: заголовок + truncated room id + primary CTA + 2 store links + fallback.
   * App Store / Play Store ссылки — placeholder до публикации в магазинах.
   */
  _showAppRedirect(roomId) {
    const ua = navigator.userAgent || '';
    const isIOS = /iPhone|iPad|iPod/i.test(ua);
    const isAndroid = /Android/i.test(ua);
    const shortRoom = roomId.length > 12 ? `${roomId.slice(0, 8)}…${roomId.slice(-4)}` : roomId;

    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.95);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:24px;overflow-y:auto;';

    const title = document.createElement('div');
    title.style.cssText = 'font-size:22px;font-weight:700;color:#fff;text-align:center;';
    title.textContent = 'Подключитесь к зашифрованной комнате';

    const roomBadge = document.createElement('div');
    roomBadge.style.cssText = 'font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,monospace;font-size:13px;color:#8e8e93;background:#1c1c1e;padding:8px 14px;border-radius:8px;margin-bottom:8px;user-select:all;';
    roomBadge.textContent = shortRoom;

    const openAppBtn = document.createElement('button');
    openAppBtn.style.cssText = 'width:100%;max-width:320px;padding:16px;background:#0A84FF;color:#fff;border:none;border-radius:14px;font-size:16px;font-weight:600;cursor:pointer;';
    openAppBtn.textContent = 'Открыть в приложении';
    openAppBtn.addEventListener('click', () => {
      // Keep the path-style scheme for backward compat with shipped iOS/Android builds.
      // Both forms (room/X and ?room=X) are handled by the deep-link parser on-device.
      window.location.href = `ghostchat://room/${roomId}`;
    });

    // Store links — href="#" placeholder until the apps are published.
    // Install button for the platform we detected is shown first; the other is secondary.
    const makeStoreBtn = (label, href, emphasized) => {
      const a = document.createElement('a');
      a.href = href;
      a.rel = 'noopener';
      a.style.cssText = `width:100%;max-width:320px;padding:14px;${emphasized ? 'background:#2C2C2E' : 'background:transparent;border:1px solid #3a3a3c'};color:#fff;border-radius:14px;font-size:15px;font-weight:500;text-align:center;text-decoration:none;`;
      a.textContent = label;
      return a;
    };
    const iosStoreBtn = makeStoreBtn('Установить для iOS', '#', isIOS);
    const androidStoreBtn = makeStoreBtn('Установить для Android', '#', isAndroid);

    const webBtn = document.createElement('button');
    webBtn.style.cssText = 'width:100%;max-width:320px;padding:10px;background:transparent;color:#8e8e93;border:none;font-size:14px;font-weight:500;cursor:pointer;margin-top:8px;';
    webBtn.textContent = 'Продолжить в браузере';
    webBtn.addEventListener('click', () => {
      overlay.remove();
      history.replaceState(null, '', window.location.pathname);
      this.elements.joinInput.value = roomId;
      this.joinRoom();
    });

    overlay.append(title, roomBadge, openAppBtn);
    // Emphasized platform first.
    if (isAndroid) {
      overlay.append(androidStoreBtn, iosStoreBtn);
    } else {
      overlay.append(iosStoreBtn, androidStoreBtn);
    }
    overlay.append(webBtn);
    document.body.appendChild(overlay);
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
  // SESSION PERSISTENCE (in-memory only — no sessionStorage for zero-trace)
  // ============================================

  /**
   * Сохранить состояние сессии в памяти (M2: no sessionStorage)
   * Позволяет восстановить сессию при переподключении WS
   */
  saveSession() {
    GhostChat._savedSession = {
      roomId: this.roomId,
      isHost: this.isHost,
      ts: Date.now()
    };
  }

  /**
   * Восстановить сессию из памяти
   * Вызывается при загрузке страницы (если нет invite link)
   */
  async restoreSession() {
    try {
      const saved = GhostChat._savedSession;
      if (!saved) return;

      const { roomId, isHost, ts } = saved;
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
    GhostChat._savedSession = null;
  }

  /**
   * Выход из комнаты
   */
  leave() {
    this.clearSession();
    this.destroy();
    this.cancelReply();
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
    this._pendingIceRestartOffer = null;
    this.roomId = null;

    // Очищаем таймеры
    if (this._peerLeftTimeout) {
      clearTimeout(this._peerLeftTimeout);
      this._peerLeftTimeout = null;
    }
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

    // Clear typing timers
    clearTimeout(this._typingCancelTimer);
    clearTimeout(this._peerTypingCancelTimer);
    this._typingCancelTimer = null;
    this._peerTypingCancelTimer = null;
    this._lastTypingSentAt = 0;
    const typingEl = document.getElementById('typing-indicator');
    if (typingEl) typingEl.classList.add('hidden');

    // Clear ringing timeout
    if (this._ringingTimeout) {
      clearTimeout(this._ringingTimeout);
      this._ringingTimeout = null;
    }

    // Clear caller-side timeout
    if (this._callingTimeout) {
      clearTimeout(this._callingTimeout);
      this._callingTimeout = null;
    }

    // End any active call — suppress renegotiation during cleanup
    if (this.voice) {
      if (this.rtc) this.rtc._suppressNegotiation = true;
      this.voice.destroy();
      this.voice = null;
      if (this.rtc) this.rtc._suppressNegotiation = false;
    }
    this._cleanupRemoteAudio();
    this._remoteStream = null;
    this.callState = 'idle';
    this.pendingRenegotiationOffer = null;
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
      androidEl.classList.remove('hidden');
      androidEl.addEventListener('click', () => {
        window.location.href = '/GhostChat.apk';
      });
    }
  } else if (/iPhone|iPad|iPod/i.test(ua)) {
    if (iosEl) {
      iosEl.classList.remove('hidden');
      // TODO: заменить на реальную ссылку App Store после публикации
    }
  } else {
    if (desktopEl) desktopEl.classList.remove('hidden');
  }
}

// Инициализация приложения
window.addEventListener('DOMContentLoaded', () => {
  window.ghostChat = new GhostChat();
  detectPlatform();
});
