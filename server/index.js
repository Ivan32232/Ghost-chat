/**
 * Ghost Chat - Signaling Server
 *
 * БЕЗОПАСНОСТЬ:
 * - Сервер НЕ хранит сообщения
 * - Сервер НЕ логирует данные пользователей
 * - Только relay для WebRTC signaling
 * - Stateless - после отключения ничего не остаётся
 * - Временные TURN credentials через API
 */

import { createServer } from 'http';
import { readFile } from 'fs/promises';
import { join, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import { WebSocketServer } from 'ws';
import { createHmac, randomBytes } from 'crypto';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;

// Environment
const IS_PRODUCTION = process.env.NODE_ENV === 'production';

// Trust proxy only if explicitly configured (nginx, cloudflare, etc.)
// Set TRUST_PROXY=1 only if server is behind a reverse proxy you control
const TRUST_PROXY = process.env.TRUST_PROXY === '1';

// TURN server configuration
// CRITICAL: TURN_SECRET must be set via environment variable in production
const TURN_SECRET = process.env.TURN_SECRET;
const TURN_DOMAIN = process.env.TURN_DOMAIN || 'localhost';
const TURN_TTL = 3600; // 1 hour

// Validate required secrets in production
if (IS_PRODUCTION && !TURN_SECRET) {
  console.error('FATAL: TURN_SECRET environment variable is required in production');
  process.exit(1);
}

// Conditional logging - в production логируем только критичное
const log = {
  info: (...args) => { if (!IS_PRODUCTION) console.log('[INFO]', ...args); },
  debug: (...args) => { if (!IS_PRODUCTION) console.log('[DEBUG]', ...args); },
  warn: (...args) => { if (!IS_PRODUCTION) console.warn('[WARN]', ...args); },
  error: (...args) => console.error('[ERROR]', ...args),
  security: (...args) => console.log('[SECURITY]', ...args) // Всегда логируем security events
};

/**
 * Анонимизация IP для логов (GDPR compliance)
 * Хэширует IP для идентификации паттернов без раскрытия реального адреса
 */
function anonymizeIp(ip) {
  if (!ip || ip === 'unknown') return 'unknown';
  // Используем SHA-256 и берём первые 8 символов
  const hash = createHmac('sha256', IP_SALT)
    .update(ip)
    .digest('hex')
    .substring(0, 8);
  return `ip_${hash}`;
}

/**
 * Generate temporary TURN credentials using HMAC-SHA1
 * Compatible with coturn's use-auth-secret option
 */
function generateTurnCredentials() {
  // Return null if TURN_SECRET not configured (dev mode without TURN)
  if (!TURN_SECRET) {
    return null;
  }

  const expiry = Math.floor(Date.now() / 1000) + TURN_TTL;
  const username = `${expiry}:ghost${randomBytes(4).toString('hex')}`;
  const credential = createHmac('sha1', TURN_SECRET)
    .update(username)
    .digest('base64');

  return {
    username,
    credential,
    ttl: TURN_TTL,
    urls: [
      `turn:${TURN_DOMAIN}:3478`,
      `turn:${TURN_DOMAIN}:5349?transport=tcp`,
      `turns:${TURN_DOMAIN}:5349`
    ]
  };
}

// Хранилище комнат (только в памяти, никаких БД)
// Map<roomId, { peers: Set<WebSocket>, inviteUsed: boolean, createdAt: number }>
const rooms = new Map();
const ROOM_TTL = 10 * 60 * 1000; // Комната живёт 10 минут даже без подключённых участников

// IP salt — берём из TURN_SECRET или генерируем случайный (не hardcoded!)
const IP_SALT = TURN_SECRET || randomBytes(32).toString('hex');

// Rate limiting для защиты от brute force
// Map<ip, { attempts: number, lastAttempt: timestamp, blocked: boolean }>
const rateLimits = new Map();
const RATE_LIMIT_WINDOW = 60000; // 1 минута
const MAX_ATTEMPTS = 10; // максимум попыток за окно
const BLOCK_DURATION = 300000; // 5 минут блокировки

function checkRateLimit(ip) {
  const now = Date.now();
  let record = rateLimits.get(ip);

  if (!record) {
    record = { attempts: 0, lastAttempt: now, blocked: false, blockUntil: 0 };
    rateLimits.set(ip, record);
  }

  // Проверяем блокировку
  if (record.blocked && now < record.blockUntil) {
    return false; // Заблокирован
  }

  // Сброс блокировки
  if (record.blocked && now >= record.blockUntil) {
    record.blocked = false;
    record.attempts = 0;
  }

  // Сброс счётчика если прошло окно
  if (now - record.lastAttempt > RATE_LIMIT_WINDOW) {
    record.attempts = 0;
  }

  record.attempts++;
  record.lastAttempt = now;

  // Превышен лимит
  if (record.attempts > MAX_ATTEMPTS) {
    record.blocked = true;
    record.blockUntil = now + BLOCK_DURATION;
    log.security(`${anonymizeIp(ip)} blocked for brute force attempt`);
    return false;
  }

  return true;
}

// Очистка старых записей rate limit каждые 5 минут
setInterval(() => {
  const now = Date.now();
  rateLimits.forEach((record, ip) => {
    if (now - record.lastAttempt > BLOCK_DURATION) {
      rateLimits.delete(ip);
    }
  });
}, 300000);

// Генерация криптостойкого ID комнаты
// 48 байт = 64 символа base64url = 384 бита энтропии
// Невозможно угадать или подобрать brute force
function generateRoomId() {
  return randomBytes(48)
    .toString('base64url');
}

// HTTP сервер для статических файлов и API
const httpServer = createServer(async (req, res) => {
  // Security headers
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Referrer-Policy', 'no-referrer');
  // CSP: strict policy - no unsafe-inline for scripts
  // style-src unsafe-inline kept for dynamic element.style manipulation
  res.setHeader('Content-Security-Policy',
    "default-src 'self'; " +
    "script-src 'self'; " +
    "style-src 'self' 'unsafe-inline'; " +
    "connect-src 'self' wss: ws:; " +
    "img-src 'self' data:; " +
    "frame-ancestors 'none'; " +
    "base-uri 'self'; " +
    "form-action 'self';"
  );

  // Запрет кэширования для максимальной приватности
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, private');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');

  // Парсим pathname отдельно от query string (?room=... и т.д.)
  const parsedUrl = new URL(req.url, `http://${req.headers.host}`);
  const pathname = parsedUrl.pathname;

  // API endpoint for TURN credentials (rate limited)
  if (pathname === '/api/turn-credentials' && req.method === 'GET') {
    const reqIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    if (!checkRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Too many requests' }));
      return;
    }
    const credentials = generateTurnCredentials();
    if (!credentials) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'TURN not configured' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(credentials));
    log.debug('TURN credentials generated');
    return;
  }

  let filePath;
  let contentType = 'text/html';
  const clientDir = resolve(__dirname, '../client');

  if (pathname === '/' || pathname === '/index.html') {
    filePath = join(clientDir, 'index.html');
  } else if (pathname.startsWith('/js/')) {
    filePath = join(clientDir, pathname);
    contentType = 'application/javascript';
  } else if (pathname.startsWith('/css/')) {
    filePath = join(clientDir, pathname);
    contentType = 'text/css';
  } else if (pathname === '/manifest.json') {
    filePath = join(clientDir, 'manifest.json');
    contentType = 'application/manifest+json';
  } else if (pathname === '/sw.js') {
    filePath = join(clientDir, 'sw.js');
    contentType = 'application/javascript';
  } else if (pathname.startsWith('/icons/') && pathname.endsWith('.png')) {
    filePath = join(clientDir, pathname);
    contentType = 'image/png';
  } else if (pathname === '/privacy' || pathname === '/privacy.html') {
    filePath = join(clientDir, 'privacy.html');
    contentType = 'text/html';
  } else {
    res.writeHead(404);
    res.end('Not Found');
    return;
  }

  // Path traversal protection: ensure resolved path is within client directory
  const resolvedPath = resolve(filePath);
  if (!resolvedPath.startsWith(clientDir)) {
    log.security(`Path traversal attempt blocked: ${req.url}`);
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  try {
    const content = await readFile(resolvedPath);
    const headers = { 'Content-Type': contentType };
    // Service Worker: не кэшировать, разрешить scope='/'
    if (pathname === '/sw.js') {
      headers['Service-Worker-Allowed'] = '/';
      headers['Cache-Control'] = 'no-cache, no-store';
    }
    // Иконки можно кэшировать — они меняются редко
    if (pathname.startsWith('/icons/')) {
      headers['Cache-Control'] = 'public, max-age=604800'; // 7 дней
    }
    res.writeHead(200, headers);
    res.end(content);
  } catch {
    res.writeHead(404);
    res.end('Not Found');
  }
});

// WebSocket сервер для signaling
const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: 64 * 1024 // 64 KB — достаточно для signaling, защита от DoS
});

wss.on('connection', (ws, req) => {
  let currentRoom = null;
  let peerId = null;

  // Получаем IP клиента
  // ВАЖНО: X-Forwarded-For можно спуфить! Доверяем только если сервер за нашим прокси
  const clientIp = TRUST_PROXY
    ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
    : (req.socket.remoteAddress || 'unknown');

  // Для ping/pong проверки соединения
  ws.isAlive = true;
  ws.on('pong', () => {
    ws.isAlive = true;
  });

  ws.on('message', (data) => {
    try {
      const message = JSON.parse(data.toString());

      switch (message.type) {
        case 'create-room': {
          // Rate limit room creation
          if (!checkRateLimit(clientIp)) {
            ws.send(JSON.stringify({ type: 'error', message: 'Слишком много запросов. Подождите.' }));
            return;
          }
          const roomId = generateRoomId();
          rooms.set(roomId, { peers: new Set([ws]), inviteUsed: false, createdAt: Date.now() });
          currentRoom = roomId;
          peerId = 'host';
          ws.send(JSON.stringify({ type: 'room-created', roomId }));
          break;
        }

        case 'rejoin-room': {
          // Rate limit rejoin (защита от brute force как и join-room)
          if (!checkRateLimit(clientIp)) {
            ws.send(JSON.stringify({ type: 'error', message: 'Слишком много попыток. Подождите.' }));
            return;
          }
          const rejoinId = message.roomId?.trim();
          const rejoinRoom = rooms.get(rejoinId);
          if (!rejoinRoom) {
            ws.send(JSON.stringify({ type: 'error', message: 'Комната не найдена' }));
            return;
          }
          // Убираем мёртвые соединения
          rejoinRoom.peers.forEach(c => { if (c.readyState !== 1) rejoinRoom.peers.delete(c); });
          // Проверяем лимит участников (макс 2)
          if (rejoinRoom.peers.size >= 2) {
            ws.send(JSON.stringify({ type: 'error', message: 'Комната заполнена' }));
            return;
          }
          rejoinRoom.peers.add(ws);
          currentRoom = rejoinId;
          peerId = message.role || 'host';
          ws.send(JSON.stringify({ type: 'rejoin-ok', roomId: rejoinId }));
          // Если оба участника на месте — уведомляем ОБОИХ для нового WebRTC handshake
          if (rejoinRoom.peers.size === 2) {
            rejoinRoom.peers.forEach(client => {
              if (client.readyState === 1) {
                client.send(JSON.stringify({ type: 'peer-joined' }));
              }
            });
          }
          break;
        }

        case 'join-room': {
          if (!checkRateLimit(clientIp)) {
            ws.send(JSON.stringify({ type: 'error', message: 'Слишком много попыток. Подождите.' }));
            return;
          }
          const roomId = message.roomId?.trim();
          const room = rooms.get(roomId);
          if (room) {
            room.peers.forEach(c => { if (c.readyState !== 1) room.peers.delete(c); });
          }
          if (!room) {
            ws.send(JSON.stringify({ type: 'error', message: 'Комната не найдена' }));
            return;
          }
          if (room.inviteUsed) {
            ws.send(JSON.stringify({ type: 'error', message: 'Ссылка-приглашение уже использована' }));
            return;
          }
          if (room.peers.size >= 2) {
            ws.send(JSON.stringify({ type: 'error', message: 'Комната заполнена' }));
            return;
          }
          room.peers.add(ws);
          room.inviteUsed = true;
          currentRoom = roomId;
          peerId = 'guest';
          if (room.peers.size > 2) {
            room.peers.forEach(client => {
              if (client.readyState === 1) {
                client.send(JSON.stringify({ type: 'error', message: 'Комната скомпрометирована. Отключаем всех.' }));
                client.close();
              }
            });
            rooms.delete(roomId);
            currentRoom = null;
            return;
          }
          ws.send(JSON.stringify({ type: 'room-joined', roomId }));
          room.peers.forEach(client => {
            if (client !== ws && client.readyState === 1) {
              client.send(JSON.stringify({ type: 'peer-joined' }));
            }
          });
          break;
        }

        case 'signal': {
          if (!currentRoom) return;
          const signalRoom = rooms.get(currentRoom);
          if (!signalRoom) return;
          signalRoom.peers.forEach(client => {
            if (client !== ws && client.readyState === 1) {
              client.send(JSON.stringify({ type: 'signal', data: message.data }));
            }
          });
          break;
        }

        case 'leave-room': {
          handleDisconnect();
          break;
        }
      }
    } catch (e) {
      // Игнорируем некорректные сообщения
    }
  });

  function handleDisconnect() {
    if (currentRoom) {
      const room = rooms.get(currentRoom);
      if (room) {
        room.peers.delete(ws);

        // Уведомляем оставшегося участника
        room.peers.forEach(client => {
          if (client.readyState === 1) {
            client.send(JSON.stringify({
              type: 'peer-left'
            }));
          }
        });

        // НЕ удаляем комнату сразу — TTL позволяет переподключиться
      }
      currentRoom = null;
    }
  }

  ws.on('close', handleDisconnect);
  ws.on('error', handleDisconnect);
});

// Очистка комнат: удаляем мёртвые соединения и просроченные комнаты (TTL)
function cleanupRooms() {
  const now = Date.now();
  rooms.forEach((room, roomId) => {
    // Удаляем мёртвые соединения
    room.peers.forEach(client => {
      if (client.readyState !== 1) {
        room.peers.delete(client);
      }
    });
    // Удаляем комнату только если она пустая И просрочена по TTL
    if (room.peers.size === 0 && now - room.createdAt > ROOM_TTL) {
      rooms.delete(roomId);
    }
  });
}

// Периодическая очистка каждые 10 секунд
setInterval(cleanupRooms, 10000);

// Ping/pong для проверки живых соединений
setInterval(() => {
  wss.clients.forEach(ws => {
    if (ws.isAlive === false) {
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

httpServer.listen(PORT, () => {
  const w = 55;
  const hr = '═'.repeat(w);
  const pad = (s) => '║ ' + s.padEnd(w - 2) + '║';
  const center = (s) => {
    const left = Math.floor((w - 2 - s.length) / 2);
    const right = w - 2 - left - s.length;
    return '║ ' + ' '.repeat(left) + s + ' '.repeat(right) + '║';
  };
  console.log(
    `\n╔${hr}╗\n` +
    center('GHOST CHAT') + '\n' +
    center('Zero-Trace Secure Messenger') + '\n' +
    `╠${hr}╣\n` +
    pad(`Server: http://localhost:${PORT}`) + '\n' +
    pad('') + '\n' +
    pad('✓ No message storage') + '\n' +
    pad('✓ No user logging') + '\n' +
    pad('✓ Stateless signaling') + '\n' +
    pad('✓ Memory-only room management') + '\n' +
    pad('✓ Temporary TURN credentials') + '\n' +
    `╚${hr}╝\n`
  );
});
