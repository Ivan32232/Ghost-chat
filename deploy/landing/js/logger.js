/**
 * Ghost Chat - Conditional Logger
 *
 * Логирование только в development режиме.
 * В production все логи отключены для безопасности.
 */

class GhostLogger {
  constructor() {
    // Определяем режим по hostname
    this.isDev = this.detectDevMode();
    this.prefix = '[Ghost]';
  }

  /**
   * Определение режима разработки
   * SECURITY: Не используем URL параметры для включения debug mode
   */
  detectDevMode() {
    if (typeof window === 'undefined') return false;

    const hostname = window.location.hostname;
    return hostname === 'localhost' ||
           hostname === '127.0.0.1' ||
           hostname.endsWith('.local');
  }

  /**
   * Обычный лог (только в dev)
   */
  log(...args) {
    if (this.isDev) {
      console.log(this.prefix, ...args);
    }
  }

  /**
   * Информационный лог (только в dev)
   */
  info(...args) {
    if (this.isDev) {
      console.info(this.prefix, ...args);
    }
  }

  /**
   * Предупреждение (только в dev)
   */
  warn(...args) {
    if (this.isDev) {
      console.warn(this.prefix, ...args);
    }
  }

  /**
   * Ошибка - логируется всегда, но без деталей в production
   */
  error(...args) {
    if (this.isDev) {
      console.error(this.prefix, ...args);
    } else {
      // В production логируем только факт ошибки, без деталей
      console.error(this.prefix, 'An error occurred');
    }
  }

  /**
   * Security-related лог (никогда не логируется в production)
   */
  security(...args) {
    if (this.isDev) {
      console.warn(this.prefix, '[SECURITY]', ...args);
    }
  }

  /**
   * Включить/выключить логирование вручную
   */
  setDebugMode(enabled) {
    this.isDev = enabled;
  }
}

// Singleton instance
export const logger = new GhostLogger();
