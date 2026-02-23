/**
 * Ghost Chat - Secure Voice Module
 *
 * БЕЗОПАСНОСТЬ:
 * - DTLS-SRTP шифрование (обязательно в WebRTC)
 * - Никаких логов звонков
 * - Детекция попыток записи
 * - Безопасные аудио constraints
 * - Мониторинг аудио-устройств
 */

import { SecurityMonitor } from './security-monitor.js';
import { logger } from './logger.js';

export class GhostVoice {
  constructor(peerConnection, dataChannel) {
    this.peerConnection = peerConnection;
    this.dataChannel = dataChannel;
    this.localStream = null;
    this.remoteStream = null;
    this.audioSender = null;
    this.isMuted = false;
    this.isInCall = false;
    this.callStartTime = null;
    this.callTimerInterval = null;

    // Security monitor
    this.securityMonitor = new SecurityMonitor();

    // Audio context для обработки
    this.audioContext = null;

    // Callbacks
    this.onCallStateChange = null;
    this.onSecurityAlert = null;
    this.onRemoteStream = null;
    this.onCallTimer = null;
  }

  /**
   * Безопасные аудио constraints
   * - echoCancellation: убирает эхо (защита от утечки через динамики)
   * - noiseSuppression: маскирует фоновые звуки
   * - autoGainControl: отключено для предотвращения acoustic fingerprinting
   * - channelCount: 1 (mono) - нет пространственной информации
   */
  getSecureAudioConstraints() {
    return {
      audio: {
        echoCancellation: { ideal: true },
        noiseSuppression: { ideal: true },
        autoGainControl: { ideal: false },
        sampleRate: { ideal: 48000 },
        channelCount: { exact: 1 },
        latency: { ideal: 0.01 }
      },
      video: false
    };
  }

  /**
   * Инициализация локального аудио потока
   */
  async initializeAudio() {
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia(
        this.getSecureAudioConstraints()
      );

      logger.log('Audio stream initialized');
      return true;
    } catch (error) {
      logger.error('Failed to get audio:', error);

      if (error.name === 'NotAllowedError') {
        throw new Error('Microphone access denied');
      } else if (error.name === 'NotFoundError') {
        throw new Error('Microphone not found');
      }

      throw error;
    }
  }

  /**
   * Начать исходящий звонок
   */
  async startCall() {
    if (this.isInCall) return false;

    try {
      await this.initializeAudio();

      // Добавляем аудио треки к существующему PeerConnection
      this.localStream.getAudioTracks().forEach(track => {
        this.audioSender = this.peerConnection.addTrack(track, this.localStream);
        logger.log('Audio track added to PeerConnection');
      });

      // Запускаем мониторинг безопасности
      this.startSecurityMonitoring();

      this.isInCall = true;

      if (this.onCallStateChange) {
        this.onCallStateChange('calling');
      }

      return true;
    } catch (error) {
      logger.error('Failed to start call:', error);
      this.cleanup();
      throw error;
    }
  }

  /**
   * Принять входящий звонок
   */
  async acceptCall() {
    if (this.isInCall) return false;

    try {
      await this.initializeAudio();

      this.localStream.getAudioTracks().forEach(track => {
        this.audioSender = this.peerConnection.addTrack(track, this.localStream);
        logger.log('Audio track added (accepting call)');
      });

      this.startSecurityMonitoring();

      this.isInCall = true;
      this.callStartTime = Date.now();
      this.startCallTimer();

      if (this.onCallStateChange) {
        this.onCallStateChange('active');
      }

      return true;
    } catch (error) {
      logger.error('Failed to accept call:', error);
      this.cleanup();
      throw error;
    }
  }

  /**
   * Обработка входящего remote track
   */
  handleRemoteTrack(event) {
    if (event.track.kind === 'audio') {
      logger.log('Remote audio track received');
      this.remoteStream = event.streams[0];

      if (this.onRemoteStream) {
        this.onRemoteStream(this.remoteStream);
      }

      // Если звонок активен, обновляем состояние
      if (this.isInCall && this.onCallStateChange) {
        this.onCallStateChange('active');
      }
    }
  }

  /**
   * Переключить mute
   */
  toggleMute() {
    if (!this.localStream) return this.isMuted;

    this.isMuted = !this.isMuted;
    this.localStream.getAudioTracks().forEach(track => {
      track.enabled = !this.isMuted;
    });

    logger.log(`Microphone ${this.isMuted ? 'muted' : 'unmuted'}`);
    return this.isMuted;
  }

  /**
   * Установить mute
   */
  setMuted(muted) {
    if (!this.localStream) return;

    this.isMuted = muted;
    this.localStream.getAudioTracks().forEach(track => {
      track.enabled = !this.isMuted;
    });
  }

  /**
   * Таймер звонка
   */
  startCallTimer() {
    this.callTimerInterval = setInterval(() => {
      if (this.callStartTime && this.onCallTimer) {
        const elapsed = Math.floor((Date.now() - this.callStartTime) / 1000);
        const minutes = Math.floor(elapsed / 60);
        const seconds = elapsed % 60;
        this.onCallTimer(`${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`);
      }
    }, 1000);
  }

  /**
   * Остановить таймер
   */
  stopCallTimer() {
    if (this.callTimerInterval) {
      clearInterval(this.callTimerInterval);
      this.callTimerInterval = null;
    }
  }

  /**
   * Запуск мониторинга безопасности
   */
  startSecurityMonitoring() {
    this.securityMonitor.onAlert = (alert) => {
      logger.warn('[VOICE SECURITY]', alert.type, alert.message);

      if (this.onSecurityAlert) {
        this.onSecurityAlert(alert);
      }
    };

    this.securityMonitor.startMonitoring();
  }

  /**
   * Остановка мониторинга безопасности
   */
  stopSecurityMonitoring() {
    this.securityMonitor.stopMonitoring();
  }

  /**
   * Завершить звонок - безопасная очистка
   */
  endCall() {
    logger.log('Ending call...');

    this.stopCallTimer();
    this.stopSecurityMonitoring();

    // Удаляем track из PeerConnection
    if (this.audioSender && this.peerConnection) {
      try {
        this.peerConnection.removeTrack(this.audioSender);
      } catch (e) {
        logger.log('Track already removed');
      }
      this.audioSender = null;
    }

    // Останавливаем и очищаем локальный stream
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => {
        track.stop();
      });
      this.localStream = null;
    }

    // Очищаем ссылку на remote stream
    this.remoteStream = null;

    // Закрываем audio context
    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }

    this.isInCall = false;
    this.isMuted = false;
    this.callStartTime = null;

    if (this.onCallStateChange) {
      this.onCallStateChange('ended');
    }

    logger.log('Call ended and cleaned up');
  }

  /**
   * Очистка при ошибке
   */
  cleanup() {
    this.stopCallTimer();
    this.stopSecurityMonitoring();

    if (this.localStream) {
      this.localStream.getTracks().forEach(track => track.stop());
      this.localStream = null;
    }

    this.remoteStream = null;
    this.audioSender = null;
    this.isInCall = false;
    this.isMuted = false;
  }

  /**
   * Получить длительность звонка
   */
  getCallDuration() {
    if (!this.callStartTime) return 0;
    return Math.floor((Date.now() - this.callStartTime) / 1000);
  }

  /**
   * Проверка статуса
   */
  getStatus() {
    return {
      isInCall: this.isInCall,
      isMuted: this.isMuted,
      hasLocalStream: !!this.localStream,
      hasRemoteStream: !!this.remoteStream,
      duration: this.getCallDuration()
    };
  }

  /**
   * Полное уничтожение
   */
  destroy() {
    this.endCall();

    this.securityMonitor.destroy();

    this.onCallStateChange = null;
    this.onSecurityAlert = null;
    this.onRemoteStream = null;
    this.onCallTimer = null;
    this.peerConnection = null;
    this.dataChannel = null;

    logger.log('GhostVoice destroyed');
  }
}
