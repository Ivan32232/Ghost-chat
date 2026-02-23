/**
 * Ghost Chat - Security Monitor
 *
 * Детекция потенциальных попыток записи во время звонков.
 *
 * ВАЖНО: Полностью предотвратить запись невозможно (проблема "analog hole").
 * Этот модуль только ДЕТЕКТИРУЕТ подозрительную активность и оповещает
 * обоих участников.
 *
 * Мониторит:
 * - Изменение аудио-устройств (новые виртуальные устройства = софт для записи)
 * - Picture-in-Picture (может использоваться для записи)
 * - Screen capture API
 */

import { logger } from './logger.js';

export class SecurityMonitor {
  constructor() {
    this.isMonitoring = false;
    this.onAlert = null;

    this.deviceChangeHandler = null;
    this._originalGetDisplayMedia = null;

    // Состояние
    this.lastAudioDevices = null;
    this.checkInterval = null;

    // Счётчики для предотвращения спама
    this.alertCooldowns = new Map();
    this.ALERT_COOLDOWN = 10000; // 10 секунд между одинаковыми алертами
  }

  /**
   * Начать мониторинг
   */
  startMonitoring() {
    if (this.isMonitoring) return;
    this.isMonitoring = true;

    // Мониторинг аудио-устройств
    this.deviceChangeHandler = () => this.checkAudioDevices();
    if (navigator.mediaDevices) {
      navigator.mediaDevices.addEventListener('devicechange', this.deviceChangeHandler);
    }

    // Начальный снимок устройств
    this.snapshotAudioDevices();

    // Перехват Screen Capture API
    this.setupScreenCaptureDetection();

    // Периодическая проверка
    this.checkInterval = setInterval(() => {
      this.periodicSecurityCheck();
    }, 5000);

    logger.log('[SecurityMonitor] Started');
  }

  /**
   * Снимок текущих аудио-устройств
   */
  async snapshotAudioDevices() {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      this.lastAudioDevices = devices
        .filter(d => d.kind === 'audioinput' || d.kind === 'audiooutput')
        .map(d => ({
          id: d.deviceId,
          kind: d.kind,
          label: d.label
        }));
    } catch (e) {
      logger.error('[SecurityMonitor] Failed to enumerate devices:', e);
    }
  }

  /**
   * Проверка изменения аудио-устройств
   * Новые виртуальные устройства могут указывать на софт для записи
   */
  async checkAudioDevices() {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const currentDevices = devices
        .filter(d => d.kind === 'audioinput' || d.kind === 'audiooutput')
        .map(d => ({
          id: d.deviceId,
          kind: d.kind,
          label: d.label
        }));

      if (this.lastAudioDevices) {
        const lastIds = new Set(this.lastAudioDevices.map(d => d.id));
        const newDevices = currentDevices.filter(d => !lastIds.has(d.id));

        if (newDevices.length > 0) {
          // Проверяем на подозрительные названия (виртуальные микшеры)
          const suspiciousKeywords = [
            'virtual', 'cable', 'voicemeeter', 'obs', 'stereo mix',
            'what u hear', 'wave', 'soundflower', 'blackhole', 'loopback'
          ];

          for (const device of newDevices) {
            const label = (device.label || '').toLowerCase();
            const isSuspicious = suspiciousKeywords.some(kw => label.includes(kw));

            if (isSuspicious) {
              this.triggerAlert(
                'suspicious-audio-device',
                `Suspicious audio device detected: ${device.label || 'Unknown'}`
              );
            } else {
              this.triggerAlert(
                'audio-device-change',
                'New audio device detected'
              );
            }
          }
        }
      }

      this.lastAudioDevices = currentDevices;
    } catch (e) {
      logger.error('[SecurityMonitor] Device check failed:', e);
    }
  }

  /**
   * Перехват Screen Capture API
   */
  setupScreenCaptureDetection() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
      return;
    }

    this._originalGetDisplayMedia = navigator.mediaDevices.getDisplayMedia.bind(
      navigator.mediaDevices
    );

    const original = this._originalGetDisplayMedia;
    const self = this;

    navigator.mediaDevices.getDisplayMedia = async (...args) => {
      self.triggerAlert('screen-capture-attempt', 'Screen capture detected');
      return original(...args);
    };
  }

  /**
   * Периодическая проверка безопасности
   */
  periodicSecurityCheck() {
    // Проверка Picture-in-Picture
    if (document.pictureInPictureElement) {
      this.triggerAlert('pip-active', 'Picture-in-Picture активен');
    }

    // Проверка MediaRecorder (если кто-то записывает)
    // Это ограничено, т.к. мы не можем отследить все MediaRecorder'ы
  }

  /**
   * Вызов security alert с cooldown
   */
  triggerAlert(type, message) {
    // Проверяем cooldown
    const lastAlert = this.alertCooldowns.get(type);
    const now = Date.now();

    if (lastAlert && now - lastAlert < this.ALERT_COOLDOWN) {
      return; // Ещё в cooldown
    }

    this.alertCooldowns.set(type, now);

    logger.warn(`[SecurityMonitor] ALERT: ${type} - ${message}`);

    if (this.onAlert) {
      this.onAlert({
        type,
        message,
        timestamp: now,
        severity: this.getAlertSeverity(type)
      });
    }
  }

  /**
   * Определение серьёзности алерта
   */
  getAlertSeverity(type) {
    const highSeverity = ['suspicious-audio-device', 'screen-capture-attempt'];
    const mediumSeverity = ['audio-device-change', 'pip-active'];

    if (highSeverity.includes(type)) return 'high';
    if (mediumSeverity.includes(type)) return 'medium';
    return 'low';
  }

  /**
   * Остановить мониторинг
   */
  stopMonitoring() {
    if (!this.isMonitoring) return;

    if (this.deviceChangeHandler && navigator.mediaDevices) {
      navigator.mediaDevices.removeEventListener('devicechange', this.deviceChangeHandler);
      this.deviceChangeHandler = null;
    }

    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = null;
    }

    // Восстанавливаем оригинальный getDisplayMedia
    if (this._originalGetDisplayMedia && navigator.mediaDevices) {
      navigator.mediaDevices.getDisplayMedia = this._originalGetDisplayMedia;
      this._originalGetDisplayMedia = null;
    }

    this.isMonitoring = false;
    logger.log('[SecurityMonitor] Stopped');
  }

  /**
   * Очистка
   */
  destroy() {
    this.stopMonitoring();
    this.onAlert = null;
    this.lastAudioDevices = null;
    this.alertCooldowns.clear();
  }
}
