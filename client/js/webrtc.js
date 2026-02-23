/**
 * Ghost Chat - WebRTC P2P Module
 *
 * Устанавливает прямое P2P соединение между браузерами
 * После установки соединения - сервер больше не нужен!
 */

import { logger } from './logger.js';

export class GhostRTC {
  constructor() {
    this.peerConnection = null;
    this.dataChannel = null;
    this.onMessage = null;
    this.onConnected = null;
    this.onDisconnected = null;
    this.onError = null;
    this._connected = false;

    // Voice call support
    this.onTrack = null;              // Callback для входящих audio/video tracks
    this.onRenegotiationNeeded = null; // Callback для renegotiation при добавлении tracks
    this._negotiating = false;         // Флаг для предотвращения race conditions

    // Конфигурация ICE серверов
    // Для localhost не нужны STUN серверы - прямое соединение
    this.isLocalhost = window.location.hostname === 'localhost' ||
                       window.location.hostname === '127.0.0.1';

    // Режим приватности: relay-only скрывает реальный IP
    this.privacyMode = false;

    // TURN credentials будут загружены асинхронно
    this.turnCredentials = null;

    // Базовый конфиг (TURN добавится после загрузки credentials)
    this.config = {
      iceServers: this.isLocalhost ? [] : [
        // STUN для определения публичного IP
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun.cloudflare.com:3478' }
      ],
      iceCandidatePoolSize: 0,
      iceTransportPolicy: 'all'
    };
  }

  /**
   * Загрузка временных TURN credentials с сервера
   */
  async fetchTurnCredentials() {
    if (this.isLocalhost) {
      logger.log('Localhost mode - skipping TURN credentials');
      return null;
    }

    try {
      const response = await fetch('/api/turn-credentials');
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const credentials = await response.json();
      logger.log('TURN credentials fetched, TTL:', credentials.ttl);

      this.turnCredentials = credentials;

      // Добавляем TURN серверы в конфиг
      const turnServers = credentials.urls.map(url => ({
        urls: url,
        username: credentials.username,
        credential: credentials.credential
      }));

      this.config.iceServers = [
        ...this.config.iceServers,
        ...turnServers
      ];

      return credentials;
    } catch (e) {
      logger.error('Failed to fetch TURN credentials:', e.message);
      // Продолжаем без TURN - будет работать только в локальных сетях
      return null;
    }
  }

  /**
   * Инициализация как хост (создатель комнаты)
   */
  async initAsHost() {
    // Загружаем TURN credentials перед созданием соединения
    await this.fetchTurnCredentials();
    await this.createPeerConnection();

    // Хост создаёт DataChannel
    this.dataChannel = this.peerConnection.createDataChannel('ghost-chat', {
      ordered: true // Гарантируем порядок сообщений
    });

    this.setupDataChannel();

    // Создаём offer и сразу отправляем (trickle ICE)
    const offer = await this.peerConnection.createOffer();
    await this.peerConnection.setLocalDescription(offer);

    // Возвращаем offer сразу, ICE candidates отправятся отдельно
    return {
      type: 'offer',
      sdp: offer
    };
  }

  /**
   * Инициализация как гость (присоединяющийся)
   */
  async initAsGuest() {
    // Загружаем TURN credentials перед созданием соединения
    await this.fetchTurnCredentials();
    await this.createPeerConnection();

    // Гость ждёт DataChannel от хоста
    this.peerConnection.ondatachannel = (event) => {
      this.dataChannel = event.channel;
      this.setupDataChannel();
    };
  }

  /**
   * Атомарный вызов onConnected — предотвращает двойной вызов из параллельных событий
   */
  _fireConnected() {
    if (this._connected) return;
    // Проверяем что DataChannel реально открыт
    if (!this.dataChannel || this.dataChannel.readyState !== 'open') return;
    this._connected = true;
    if (this.onConnected) this.onConnected();
  }

  /**
   * Создание PeerConnection
   */
  async createPeerConnection() {
    // Закрываем старое соединение если есть (при rejoin/восстановлении сессии)
    if (this.peerConnection) {
      try { this.peerConnection.close(); } catch {}
      this.peerConnection = null;
    }
    if (this.dataChannel) {
      try { this.dataChannel.close(); } catch {}
      this.dataChannel = null;
    }
    this._connected = false;

    // Очищаем таймеры от предыдущего соединения
    if (this._disconnectTimer) {
      clearTimeout(this._disconnectTimer);
      this._disconnectTimer = null;
    }

    // Применяем privacy mode к конфигу
    this.config.iceTransportPolicy = this.privacyMode ? 'relay' : 'all';

    this.peerConnection = new RTCPeerConnection(this.config);

    // Обработка ICE кандидатов - отправляем сразу (trickle ICE)
    this.peerConnection.onicecandidate = (event) => {
      if (event.candidate && this.onIceCandidate) {
        // Фильтрация для защиты приватности
        if (this.shouldFilterCandidate(event.candidate)) {
          logger.log('Filtered out local IP candidate for privacy');
          return;
        }
        this.onIceCandidate(event.candidate);
      }
    };

    // ICE state tracking with delayed disconnect (transient disconnects during renegotiation)
    this._disconnectTimer = null;

    this.peerConnection.oniceconnectionstatechange = () => {
      if (!this.peerConnection) return;
      const state = this.peerConnection.iceConnectionState;
      logger.log('ICE state:', state);

      // Clear any pending disconnect timer on state change
      if (this._disconnectTimer) {
        clearTimeout(this._disconnectTimer);
        this._disconnectTimer = null;
      }

      if (state === 'connected' || state === 'completed') {
        this._fireConnected();
      } else if (state === 'failed') {
        if (this.onError) this.onError('ICE connection failed');
        if (this._connected) {
          this._connected = false;
          if (this.onDisconnected) this.onDisconnected();
        }
      } else if (state === 'disconnected' && this._connected) {
        // Delay disconnect — ICE may reconnect during renegotiation
        this._disconnectTimer = setTimeout(() => {
          if (this.peerConnection?.iceConnectionState === 'disconnected') {
            this._connected = false;
            if (this.onDisconnected) this.onDisconnected();
          }
        }, 5000);
      } else if (state === 'closed' && this._connected) {
        this._connected = false;
        if (this.onDisconnected) this.onDisconnected();
      }
    };

    // Connection state для определения готовности
    this.peerConnection.onconnectionstatechange = () => {
      if (!this.peerConnection) return;
      const state = this.peerConnection.connectionState;
      logger.log('Connection state:', state);

      if ((state === 'failed' || state === 'closed') && this._connected) {
        this._connected = false;
        if (this.onDisconnected) this.onDisconnected();
      } else if (state === 'connected' && !this._connected) {
        this._fireConnected();
      }
    };

    // Обработка входящих media tracks (для голосовых звонков)
    this.peerConnection.ontrack = (event) => {
      logger.log('Received remote track:', event.track.kind);
      if (this.onTrack) {
        this.onTrack(event);
      }
    };

    // Renegotiation при добавлении новых tracks (например, аудио для звонка)
    this.peerConnection.onnegotiationneeded = async () => {
      if (this._negotiating) {
        logger.log('Already negotiating, skipping...');
        return;
      }

      // Проверяем, что соединение установлено
      if (!this._connected || !this.peerConnection) {
        return;
      }

      this._negotiating = true;
      logger.log('Renegotiation needed (adding audio track)');

      try {
        const offer = await this.peerConnection.createOffer();
        await this.peerConnection.setLocalDescription(offer);

        if (this.onRenegotiationNeeded) {
          this.onRenegotiationNeeded({
            type: 'offer',
            sdp: this.peerConnection.localDescription
          });
        }
      } catch (e) {
        logger.error('Renegotiation error:', e);
      } finally {
        this._negotiating = false;
      }
    };
  }

  /**
   * Настройка DataChannel
   */
  setupDataChannel() {
    this.dataChannel.onopen = () => {
      logger.log('DataChannel opened');
      this._fireConnected();
    };

    this.dataChannel.onclose = () => {
      logger.log('DataChannel closed');
      if (this._connected && this.onDisconnected) {
        this._connected = false;
        this.onDisconnected();
      }
    };

    this.dataChannel.onerror = (error) => {
      logger.error('DataChannel error:', error);
      if (this.onError) this.onError(error);
    };

    this.dataChannel.onmessage = (event) => {
      if (this.onMessage) {
        this.onMessage(event.data);
      }
    };
  }

  /**
   * Обработка входящего offer (для гостя)
   */
  async handleOffer(offer) {
    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(offer));

    const answer = await this.peerConnection.createAnswer();
    await this.peerConnection.setLocalDescription(answer);

    // Возвращаем answer сразу (trickle ICE)
    return {
      type: 'answer',
      sdp: answer
    };
  }

  /**
   * Обработка входящего answer (для хоста)
   */
  async handleAnswer(answer) {
    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(answer));
  }

  /**
   * Добавление ICE кандидата
   */
  async addIceCandidate(candidate) {
    try {
      await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate));
    } catch (e) {
      logger.error('Error adding ICE candidate:', e);
    }
  }

  /**
   * Отправка сообщения через P2P
   */
  send(data) {
    if (this.dataChannel && this.dataChannel.readyState === 'open') {
      this.dataChannel.send(data);
      return true;
    }
    return false;
  }

  /**
   * Проверка готовности соединения
   */
  isConnected() {
    return this.dataChannel && this.dataChannel.readyState === 'open';
  }

  /**
   * Получение статистики соединения (для отладки)
   */
  async getConnectionStats() {
    if (!this.peerConnection) return null;

    const stats = await this.peerConnection.getStats();
    const result = {
      connectionType: 'unknown',
      localAddress: null,
      remoteAddress: null
    };

    stats.forEach(report => {
      if (report.type === 'candidate-pair' && report.state === 'succeeded') {
        result.localAddress = report.localCandidateId;
        result.remoteAddress = report.remoteCandidateId;
      }
      if (report.type === 'local-candidate') {
        result.connectionType = report.candidateType; // 'host', 'srflx', 'relay'
      }
    });

    return result;
  }

  /**
   * Фильтрация ICE кандидатов для защиты приватности
   * В обычном режиме — без фильтрации (браузер сам скрывает IP через mDNS)
   * В privacy mode — пропускаем только relay кандидаты (полное скрытие IP)
   */
  shouldFilterCandidate(candidate) {
    if (!candidate || !candidate.candidate) return false;

    // В режиме приватности пропускаем только relay кандидаты
    if (this.privacyMode) {
      return !candidate.candidate.includes('typ relay');
    }

    // В обычном режиме не фильтруем — браузер использует mDNS для защиты
    return false;
  }

  /**
   * Включение/выключение режима приватности
   * В режиме приватности используется только TURN relay
   */
  setPrivacyMode(enabled) {
    this.privacyMode = enabled;
    // Обновляем конфиг - это должно быть сделано ДО createPeerConnection
    this.config.iceTransportPolicy = enabled ? 'relay' : 'all';
    logger.log(`Privacy mode: ${enabled ? 'ON (relay only)' : 'OFF'}`);
  }

  /**
   * Закрытие соединения и очистка
   */
  destroy() {
    // Очищаем таймер отложенного disconnect
    if (this._disconnectTimer) {
      clearTimeout(this._disconnectTimer);
      this._disconnectTimer = null;
    }

    if (this.dataChannel) {
      this.dataChannel.close();
      this.dataChannel = null;
    }

    if (this.peerConnection) {
      this.peerConnection.close();
      this.peerConnection = null;
    }

    this.onMessage = null;
    this.onConnected = null;
    this.onDisconnected = null;
    this.onError = null;
    this.onIceCandidate = null;
    this.onTrack = null;
    this.onRenegotiationNeeded = null;
    this._connected = false;
    this._negotiating = false;
    this.turnCredentials = null;
  }
}
