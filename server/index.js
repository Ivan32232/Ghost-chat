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
import { createHash, createHmac, randomBytes, createSign, createPrivateKey } from 'crypto';
import http2 from 'node:http2';
import dnsCallback from 'node:dns';
import { readFileSync, appendFileSync, mkdirSync, existsSync } from 'fs';

// CRITICAL: Docker bridge network has no IPv6. Without this, Node.js resolves
// hostnames preferring AAAA first → "Network unreachable" on APNs/FCM/OAuth2.
// Forces IPv4-first resolution for ALL DNS (http2.connect, fetch, etc.).
dnsCallback.setDefaultResultOrder('ipv4first');

// === Error logging to file (temporary — remove when stable) ===
const LOG_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '../logs');
if (!existsSync(LOG_DIR)) mkdirSync(LOG_DIR, { recursive: true });
const ERROR_LOG = join(LOG_DIR, 'errors.log');

function logError(prefix, err) {
  const ts = new Date().toISOString();
  const msg = err instanceof Error
    ? `${err.message}\n${err.stack}`
    : String(err);
  const line = `[${ts}] ${prefix}: ${msg}\n`;
  try { appendFileSync(ERROR_LOG, line); } catch {}
  console.error(`${prefix}:`, msg);
}

// === Verbose debug logging (temporary) — writes to file ALWAYS, console in dev ===
function logDebug(...args) {
  const ts = new Date().toISOString();
  const msg = `[${ts}] ${args.join(' ')}\n`;
  try { appendFileSync(join(LOG_DIR, 'debug.log'), msg); } catch {}
  if (!IS_PRODUCTION) console.log(...args);
}

process.on('uncaughtException', (err) => {
  logError('[FATAL] Uncaught exception', err);
  // Let Docker restart the process
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  logError('[WARN] Unhandled rejection', reason);
  // Don't crash — log and continue
});

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;

// SRI (Subresource Integrity) — computed at startup, injected into index.html
// Prevents tampering with JS/CSS files (CDN compromise, cache poisoning)
const sriHashes = new Map();
async function computeSRI() {
  const clientDir = resolve(__dirname, '../client');
  const files = [
    'css/style.css',
    'js/background.js',
    'js/app.js'
  ];
  for (const file of files) {
    try {
      const content = await readFile(join(clientDir, file));
      const hash = createHash('sha384').update(content).digest('base64');
      sriHashes.set(file, `sha384-${hash}`);
    } catch {
      // File may not exist yet
    }
  }
}
// Compute on startup
computeSRI().catch(err => logError('[SRI] Failed', err));

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

// APNs VoIP Push configuration (optional — enables offline call notifications)
const APNS_KEY_ID = process.env.APNS_KEY_ID;
const APNS_TEAM_ID = process.env.APNS_TEAM_ID;
const APNS_KEY_PATH = process.env.APNS_KEY_PATH;
const APNS_BUNDLE_ID = process.env.APNS_BUNDLE_ID || 'com.ivanpokhvalitov.ghostchat';
// APNs host is now determined dynamically with sandbox fallback (see getApnsClientForHost)

// FCM Push configuration (v1 API — uses service account JSON)
const FCM_SA_PATH = process.env.FCM_SA_PATH;  // path to service-account.json
// Legacy key kept as fallback env var name but unused
const FCM_SERVER_KEY = process.env.FCM_SERVER_KEY;  // deprecated, not used

// Conditional logging - в production логируем только критичное
const log = {
  info: (...args) => { if (!IS_PRODUCTION) console.log('[INFO]', ...args); },
  debug: (...args) => { if (!IS_PRODUCTION) console.log('[DEBUG]', ...args); },
  warn: (...args) => console.warn('[WARN]', ...args),
  error: (...args) => console.error('[ERROR]', ...args),
  security: (...args) => console.log('[SECURITY]', ...args) // Всегда логируем security events
};

// Load APNs auth key if configured
let apnsPrivateKey = null;
let apnsJwtToken = null;
let apnsJwtIssuedAt = 0;

if (APNS_KEY_ID && APNS_TEAM_ID && APNS_KEY_PATH) {
  try {
    apnsPrivateKey = createPrivateKey(readFileSync(APNS_KEY_PATH));
    log.info('APNs push configured:', { keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID });
  } catch (err) {
    log.error('Failed to load APNs key:', err.message);
  }
}

// FCM v1 API — load service account and generate OAuth2 tokens
let fcmServiceAccount = null;
let fcmProjectId = null;
let fcmAccessToken = null;
let fcmTokenExpiry = 0;

if (FCM_SA_PATH) {
  try {
    fcmServiceAccount = JSON.parse(readFileSync(FCM_SA_PATH, 'utf-8'));
    fcmProjectId = fcmServiceAccount.project_id;
    log.info('FCM v1 push configured:', { projectId: fcmProjectId });
  } catch (err) {
    log.error('Failed to load FCM service account:', err.message);
  }
}

/**
 * Generate FCM v1 OAuth2 access token using service account JWT
 * Cached until 5 min before expiry
 */
async function getFcmAccessToken() {
  const now = Math.floor(Date.now() / 1000);
  if (fcmAccessToken && now < fcmTokenExpiry - 300) {
    return fcmAccessToken;
  }

  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({
    iss: fcmServiceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600
  })).toString('base64url');

  const signingInput = `${header}.${claims}`;
  const sign = createSign('RSA-SHA256');
  sign.update(signingInput);
  const signature = sign.sign(fcmServiceAccount.private_key, 'base64url');
  const jwt = `${signingInput}.${signature}`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
    signal: controller.signal
  });
  clearTimeout(timeout);

  if (!tokenRes.ok) {
    throw new Error(`OAuth2 token error: ${tokenRes.status}`);
  }

  const tokenData = await tokenRes.json();
  fcmAccessToken = tokenData.access_token;
  fcmTokenExpiry = now + (tokenData.expires_in || 3600);
  return fcmAccessToken;
}

/**
 * Send FCM v1 push notification
 */
async function sendFcmPush(token, dataPayload) {
  const accessToken = await getFcmAccessToken();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  const fcmRes = await fetch(
    `https://fcm.googleapis.com/v1/projects/${fcmProjectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        message: {
          token: token,
          android: { priority: 'high' },
          data: dataPayload
        }
      }),
      signal: controller.signal
    }
  );
  clearTimeout(timeout);
  return { ok: fcmRes.ok, status: fcmRes.status, text: fcmRes.ok ? '' : await fcmRes.text() };
}

/**
 * Generate APNs JWT token (ES256)
 * Cached for 50 minutes (tokens valid for 60 min)
 */
function getApnsJwt() {
  const now = Math.floor(Date.now() / 1000);
  if (apnsJwtToken && (now - apnsJwtIssuedAt) < 3000) {
    return apnsJwtToken;
  }

  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: APNS_KEY_ID })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ iss: APNS_TEAM_ID, iat: now })).toString('base64url');
  const signingInput = `${header}.${claims}`;

  // Sign with ieee-p1363 encoding — gives raw r||s directly (no DER parsing needed)
  const sign = createSign('SHA256');
  sign.update(signingInput);
  const rawSig = sign.sign({ key: apnsPrivateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');

  apnsJwtToken = `${signingInput}.${rawSig}`;
  apnsJwtIssuedAt = now;
  return apnsJwtToken;
}

// Persistent HTTP/2 connections to APNs (production + sandbox)
const apnsClients = { production: null, sandbox: null };
const APNS_HOSTS = {
  production: 'api.push.apple.com:2197',
  sandbox: 'api.sandbox.push.apple.com:2197'
};

// IPv4-forced DNS lookup for http2.connect (container has no IPv6 → hostname
// resolution picks AAAA first and silently fails with "Network unreachable").
function ipv4Lookup(hostname, options, callback) {
  if (typeof options === 'function') { callback = options; options = {}; }
  return dnsCallback.lookup(hostname, { ...options, family: 4 }, callback);
}

function getApnsClientForHost(env, forceNew = false) {
  const existing = apnsClients[env];
  // Strong validity check — any "going away" / closing state => new connection
  if (!forceNew && existing &&
      !existing.closed &&
      !existing.destroyed &&
      existing.connecting === false &&
      !existing.receivedGoAway) {
    return existing;
  }
  if (existing) {
    try { existing.close(); } catch {}
    apnsClients[env] = null;
  }
  const client = http2.connect(`https://${APNS_HOSTS[env]}`, { lookup: ipv4Lookup });
  client.receivedGoAway = false;
  client.on('error', (err) => {
    logDebug('[APNs] client error env=', env, err.message);
    if (apnsClients[env] === client) apnsClients[env] = null;
  });
  client.on('goaway', () => {
    logDebug('[APNs] client GOAWAY env=', env);
    client.receivedGoAway = true;
    if (apnsClients[env] === client) apnsClients[env] = null;
  });
  client.on('close', () => {
    logDebug('[APNs] client closed env=', env);
    if (apnsClients[env] === client) apnsClients[env] = null;
  });
  apnsClients[env] = client;
  return client;
}

// Primary APNs host based on NODE_ENV, fallback is the other
const APNS_PRIMARY = IS_PRODUCTION ? 'production' : 'sandbox';
const APNS_FALLBACK = IS_PRODUCTION ? 'sandbox' : 'production';

/**
 * Single-attempt APNs request via HTTP/2 (returns a Promise).
 * Errors (stream cancelled, etc.) propagate to the caller for retry handling.
 */
function sendApnsAttempt(env, deviceToken, headers, body, forceNew = false) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer;
    const client = getApnsClientForHost(env, forceNew);

    function settleResolve(val) { if (!settled) { settled = true; clearTimeout(timer); resolve(val); } }
    function settleReject(err) { if (!settled) { settled = true; clearTimeout(timer); reject(err); } }

    let req;
    try {
      req = client.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        ...headers,
      });
    } catch (err) {
      // session.request throws synchronously if session is dead
      settleReject(err);
      return;
    }

    req.on('error', (err) => settleReject(err));
    req.on('response', (h) => {
      const status = h[':status'];
      let data = '';
      req.on('data', (chunk) => { data += chunk; });
      req.on('end', () => settleResolve({ status, data }));
    });

    req.write(body);
    req.end();

    timer = setTimeout(() => {
      try { req.close(); } catch {}
      settleReject(new Error('APNs timeout'));
    }, 10000);
  });
}

/**
 * Send APNs push with retry on transient HTTP/2 errors.
 * On "stream cancelled" / GOAWAY / connection-reset, we invalidate the pooled
 * client and retry ONCE with a fresh HTTP/2 connection. This is the fix for
 * the production issue where the long-lived HTTP/2 session silently dies
 * (idle timeout, GOAWAY) and the first request after that always fails.
 */
async function sendApnsToHost(env, deviceToken, headers, body) {
  try {
    return await sendApnsAttempt(env, deviceToken, headers, body, false);
  } catch (err) {
    const msg = (err && err.message) || String(err);
    const isTransient =
      msg.includes('stream has been canceled') ||
      msg.includes('GOAWAY') ||
      msg.includes('ERR_HTTP2_GOAWAY_SESSION') ||
      msg.includes('ERR_HTTP2_STREAM_CANCEL') ||
      msg.includes('ERR_HTTP2_INVALID_SESSION') ||
      msg.includes('ENOTFOUND') ||
      msg.includes('ECONNRESET') ||
      msg.includes('socket hang up') ||
      msg.includes('Session closed');
    if (!isTransient) throw err;
    logDebug('[APNs] Transient error on', env, ':', msg, '— retrying with fresh client');
    // Force a brand-new HTTP/2 session for the retry
    return await sendApnsAttempt(env, deviceToken, headers, body, true);
  }
}

/**
 * Send VoIP push — tries primary APNs. Sandbox fallback is DEV-ONLY
 * (in production, BadDeviceToken means the token is actually dead).
 */
async function sendApnsPush(deviceToken, payload) {
  const body = JSON.stringify(payload);
  const headers = {
    'authorization': `bearer ${getApnsJwt()}`,
    'apns-topic': `${APNS_BUNDLE_ID}.voip`,
    'apns-push-type': 'voip',
    'apns-priority': '10',
    'apns-expiration': '0',
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body),
  };

  const result = await sendApnsToHost(APNS_PRIMARY, deviceToken, headers, body);

  // DEV-only: allow cross-env fallback for local testing
  if (!IS_PRODUCTION && result.status === 400 && result.data.includes('BadDeviceToken')) {
    logDebug('[APNs] DEV fallback', APNS_PRIMARY, '→', APNS_FALLBACK);
    return sendApnsToHost(APNS_FALLBACK, deviceToken, headers, body);
  }

  return result;
}

/**
 * Send regular APNs alert push (for chat invites)
 * Tries primary, falls back on BadDeviceToken
 */
async function sendApnsAlert(deviceToken, payload) {
  const body = JSON.stringify(payload);
  const headers = {
    'authorization': `bearer ${getApnsJwt()}`,
    'apns-topic': APNS_BUNDLE_ID,
    'apns-push-type': 'alert',
    'apns-priority': '10',
    'apns-expiration': '86400',
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body),
  };

  const result = await sendApnsToHost(APNS_PRIMARY, deviceToken, headers, body);

  // DEV-only: cross-env fallback (production uses only production endpoint)
  if (!IS_PRODUCTION && result.status === 400 && result.data.includes('BadDeviceToken')) {
    logDebug('[APNs] alert DEV fallback', APNS_PRIMARY, '→', APNS_FALLBACK);
    return sendApnsToHost(APNS_FALLBACK, deviceToken, headers, body);
  }

  return result;
}

// Validate required secrets in production
if (IS_PRODUCTION && !TURN_SECRET) {
  console.error('FATAL: TURN_SECRET environment variable is required in production');
  process.exit(1);
}

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
  const username = `${expiry}:ghost${randomBytes(16).toString('hex')}`;
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
const MAX_ROOMS = 10000; // Защита от исчерпания памяти

// Pending rooms — maps peerHash → { roomId, creatorHash, createdAt }
// Used for offline contact reconnection: A creates room, registers for B's hash.
// When B comes online, B queries by A's hash, gets roomId, joins.
const pendingRooms = new Map();
const PENDING_ROOM_TTL = 5 * 60 * 1000; // 5 min TTL

// IP salt — производный от TURN_SECRET через HMAC (не используем TURN_SECRET напрямую!)
const IP_SALT = TURN_SECRET
  ? createHmac('sha256', TURN_SECRET).update('ghost-chat-ip-salt').digest('hex')
  : randomBytes(32).toString('hex');

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
    logDebug('[RATE] Blocked', anonymizeIp(ip), 'attempts:', record.attempts);
    log.security(`${anonymizeIp(ip)} blocked for brute force attempt`);
    return false;
  }

  return true;
}

// Очистка старых записей rate limit каждые 60 секунд
// Max size protection — при переполнении очищаем всё (предотвращение memory exhaustion)
const RATE_LIMIT_MAX_ENTRIES = 100000;
setInterval(() => {
  if (rateLimits.size > RATE_LIMIT_MAX_ENTRIES) {
    const cutoff = Date.now() - BLOCK_DURATION;
    for (const [ip, record] of rateLimits) {
      if (record.lastAttempt < cutoff) rateLimits.delete(ip);
    }
    if (rateLimits.size > RATE_LIMIT_MAX_ENTRIES) rateLimits.clear(); // fallback
    return;
  }
  const now = Date.now();
  rateLimits.forEach((record, ip) => {
    if (now - record.lastAttempt > BLOCK_DURATION) {
      rateLimits.delete(ip);
    }
  });
}, 60000);

// Push-specific rate limiting — stricter: 5 push requests per minute per IP
const pushRateLimits = new Map();
const PUSH_RATE_WINDOW = 60000; // 1 minute
const PUSH_MAX_REQUESTS = 20;  // Per IP per minute — raised from 5 to handle shared-NAT users

function checkPushRateLimit(ip) {
  const now = Date.now();
  let record = pushRateLimits.get(ip);
  if (!record) {
    record = { count: 0, windowStart: now };
    pushRateLimits.set(ip, record);
  }
  if (now - record.windowStart > PUSH_RATE_WINDOW) {
    record.count = 0;
    record.windowStart = now;
  }
  record.count++;
  return record.count <= PUSH_MAX_REQUESTS;
}

// Cleanup push rate limits
setInterval(() => {
  if (pushRateLimits.size > RATE_LIMIT_MAX_ENTRIES) {
    pushRateLimits.clear();
    return;
  }
  const now = Date.now();
  pushRateLimits.forEach((record, ip) => {
    if (now - record.windowStart > PUSH_RATE_WINDOW * 2) {
      pushRateLimits.delete(ip);
    }
  });
}, 60000);

/**
 * HMAC-аутентификация push-запросов
 * Генерирует HMAC-SHA256(TURN_SECRET, token + identifier + timeWindow)
 * Окно: 5 минут (300 секунд)
 */
function generatePushAuthToken(token, identifier) {
  const window = Math.floor(Date.now() / 300000);
  return createHmac('sha256', TURN_SECRET)
    .update(token + identifier + window)
    .digest('hex');
}

/**
 * Проверяет push auth — текущее и предыдущее временное окно
 */
function verifyPushAuth(token, identifier, auth, reqIp) {
  if (!auth || typeof auth !== 'string') return false;
  const window = Math.floor(Date.now() / 300000);

  // Method 1: Token + identifier auth (legacy web)
  const current = createHmac('sha256', TURN_SECRET)
    .update(token + identifier + window)
    .digest('hex');
  if (auth === current) return true;
  const previous = createHmac('sha256', TURN_SECRET)
    .update(token + identifier + (window - 1))
    .digest('hex');
  if (auth === previous) return true;

  // Method 2: IP-based auth (from /api/turn-credentials pushAuth field)
  if (reqIp) {
    const ipCurrent = createHmac('sha256', TURN_SECRET)
      .update('push:' + reqIp + ':' + window)
      .digest('hex');
    if (auth === ipCurrent) return true;
    const ipPrevious = createHmac('sha256', TURN_SECRET)
      .update('push:' + reqIp + ':' + (window - 1))
      .digest('hex');
    if (auth === ipPrevious) return true;
  }

  return false;
}

/**
 * Zero-out sensitive data in memory after use
 * Uses Buffer.fill(0) for actual memory erasure where possible.
 * For strings: converts to Buffer, zeros the buffer, then overwrites the reference.
 * V8 strings are immutable so the original string may persist until GC,
 * but this is the best we can do without native addons.
 */
function zeroOut(obj, ...keys) {
  for (const key of keys) {
    if (obj[key] && typeof obj[key] === 'string') {
      const buf = Buffer.from(obj[key], 'utf-8');
      buf.fill(0);
      obj[key] = '';
    } else if (Buffer.isBuffer(obj[key])) {
      obj[key].fill(0);
    }
  }
}

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
  res.setHeader('X-DNS-Prefetch-Control', 'off');
  // CSP: strict policy — NO 'unsafe-inline' anywhere (M4)
  // connect-src 'self' — WebSocket to same origin only (prevents exfiltration)
  // font-src 'self' — self-hosted fonts only
  // media-src 'self' — restrict media sources
  // worker-src 'none' — no web workers (attack surface reduction)
  // object-src 'none' — no plugins (Flash, Java, etc.)
  // upgrade-insecure-requests — force HTTPS for all subresources
  res.setHeader('Content-Security-Policy',
    "default-src 'self'; " +
    "script-src 'self'; " +
    "style-src 'self'; " +
    "connect-src 'self'; " +
    "img-src 'self' data:; " +
    "font-src 'self'; " +
    "media-src 'self'; " +
    "worker-src 'none'; " +
    "object-src 'none'; " +
    "frame-ancestors 'none'; " +
    "base-uri 'self'; " +
    "form-action 'self'; " +
    "upgrade-insecure-requests;"
  );
  // HSTS — enforce HTTPS, prevent SSL stripping, preload-ready
  res.setHeader('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload');
  // Permissions-Policy — restrict all unnecessary browser APIs
  res.setHeader('Permissions-Policy',
    'camera=(), microphone=(self), geolocation=(), payment=(), usb=(), ' +
    'accelerometer=(), gyroscope=(), magnetometer=(), ' +
    'ambient-light-sensor=(), autoplay=(), ' +
    'document-domain=(), encrypted-media=(), ' +
    'fullscreen=(self), interest-cohort=()'
  );
  // Cross-Origin-Opener-Policy — isolate browsing context (prevents Spectre-like attacks)
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  // Cross-Origin-Embedder-Policy — prevent loading cross-origin resources without CORS
  // Note: 'credentialless' is less strict than 'require-corp' but allows fonts/images to load
  res.setHeader('Cross-Origin-Embedder-Policy', 'credentialless');
  // Cross-Origin-Resource-Policy — prevent other sites from embedding our resources
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');

  // Запрет кэширования для максимальной приватности
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, private');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');

  // Парсим pathname отдельно от query string (?room=... и т.д.)
  const parsedUrl = new URL(req.url, `http://${req.headers.host}`);
  const pathname = parsedUrl.pathname;

  // Defense-in-depth: блокируем path traversal на раннем этапе
  if (pathname.includes('..') || pathname.includes('\0') || pathname.includes('%00')) {
    res.writeHead(400);
    res.end('Bad Request');
    return;
  }

  // POST /api/send-push — APNs VoIP push proxy (before method check)
  if (pathname === '/api/send-push' && req.method === 'POST') {
    const pushReqIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    logDebug('[PUSH]', pathname, 'from', anonymizeIp(pushReqIp));
    if (!apnsPrivateKey) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Push not configured' }));
      return;
    }

    const reqIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    if (!checkRateLimit(reqIp)) {
      logDebug('[RATE] Blocked push (APNs VoIP) from', anonymizeIp(reqIp));
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Too many requests' }));
      return;
    }
    if (!checkPushRateLimit(reqIp)) {
      logDebug('[RATE] Push rate limit (APNs VoIP) from', anonymizeIp(reqIp));
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Push rate limit exceeded' }));
      return;
    }

    // Read body (max 1KB)
    let body = '';
    let destroyed = false;
    req.on('data', (chunk) => {
      if (destroyed) return;
      body += chunk;
      if (body.length > 1024) {
        destroyed = true;
        res.writeHead(413);
        res.end('Payload Too Large');
        req.destroy();
      }
    });
    req.on('end', async () => {
      if (destroyed) return;
      try {
        const data = JSON.parse(body);
        const { token, payload } = data;

        // Validate token: hex string, 64 chars (32 bytes)
        if (!token || typeof token !== 'string' || !/^[0-9a-f]{64}$/i.test(token)) {
          logDebug('[PUSH] Invalid token format, length:', token?.length, 'pattern:', typeof token === 'string' ? token.substring(0, 10) + '...' : 'not-string');
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid token' }));
          return;
        }

        // Validate payload
        if (!payload || typeof payload !== 'object') {
          logDebug('[PUSH] Invalid payload');
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid payload' }));
          return;
        }

        const { roomId, callerName } = payload;
        if (!roomId || typeof roomId !== 'string' || roomId.length > 100) {
          logDebug('[PUSH] Invalid roomId');
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid roomId' }));
          return;
        }

        // Verify push authentication
        if (IS_PRODUCTION && TURN_SECRET) {
          const auth = data.auth;
          if (!auth || !verifyPushAuth(token, roomId || '', auth, reqIp)) {
            logDebug('[PUSH] Auth failed for', anonymizeIp(reqIp), 'auth:', auth ? 'present' : 'missing');
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Unauthorized' }));
            return;
          }
        }
        logDebug('[PUSH] VoIP push auth OK, sending to APNs, token:', token.substring(0, 8) + '...');

        const safeName = (callerName || 'Ghost Chat').substring(0, 50);

        // Send to APNs
        const apnsPayload = {
          aps: {},
          roomId: roomId,
          callerName: safeName
        };

        const result = await sendApnsPush(token, apnsPayload);

        // Zero out sensitive data
        zeroOut(data, 'token');
        body = '0'.repeat(body.length);

        if (result.status === 200) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: true }));
          logDebug('[PUSH] Sent to APNs VoIP status:', result.status);
        } else if (result.status === 410) {
          // VoIP token is stale — peer reinstalled/revoked. Client should drop it.
          res.writeHead(410, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'token-invalid', action: 'drop-token' }));
          logDebug('[PUSH] APNs VoIP 410 (stale token), data:', result.data);
        } else {
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Push delivery failed', apnsStatus: result.status }));
          logDebug('[PUSH] Failed APNs VoIP status:', result.status, 'data:', result.data);
        }
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Internal error' }));
        logDebug('[PUSH] Failed APNs VoIP error:', err.message);
        logError('[PUSH APNs]', err);
      }
    });
    return;
  }

  // POST /api/send-push-android — FCM v1 push proxy for Android
  if (pathname === '/api/send-push-android' && req.method === 'POST') {
    const pushAndroidIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    logDebug('[PUSH]', pathname, 'from', anonymizeIp(pushAndroidIp));
    if (!fcmServiceAccount) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'FCM not configured' }));
      return;
    }

    const reqIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    if (!checkRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Too many requests' }));
      return;
    }
    if (!checkPushRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Push rate limit exceeded' }));
      return;
    }

    let body = '';
    let destroyed = false;
    req.on('data', (chunk) => {
      if (destroyed) return;
      body += chunk;
      if (body.length > 1024) {
        destroyed = true;
        res.writeHead(413);
        res.end('Payload Too Large');
        req.destroy();
      }
    });
    req.on('end', async () => {
      if (destroyed) return;
      try {
        const data = JSON.parse(body);
        const { token, payload } = data;

        // Validate FCM token (string, 100-300 chars)
        if (!token || typeof token !== 'string' || token.length < 50 || token.length > 300) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid token' }));
          return;
        }

        if (!payload || typeof payload !== 'object') {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid payload' }));
          return;
        }

        const { roomId, callerName } = payload;
        if (!roomId || typeof roomId !== 'string' || roomId.length > 100) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid roomId' }));
          return;
        }

        // Verify push authentication
        if (IS_PRODUCTION && TURN_SECRET) {
          const auth = data.auth;
          if (!auth || !verifyPushAuth(token, roomId || '', auth, reqIp)) {
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Unauthorized' }));
            return;
          }
        }

        const safeName = (callerName || 'Ghost Chat').substring(0, 50);

        const result = await sendFcmPush(token, {
          type: 'incoming_call',
          roomId: roomId,
          callerName: safeName
        });

        // Zero out sensitive data
        zeroOut(data, 'token');
        body = '0'.repeat(body.length);

        if (result.ok) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: true }));
          logDebug('[PUSH] Sent to FCM status:', result.status);
        } else {
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Push delivery failed' }));
          logDebug('[PUSH] Failed FCM status:', result.status, 'text:', result.text);
        }
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Internal error' }));
        logDebug('[PUSH] Failed FCM error:', err.message);
        logError('[PUSH FCM]', err);
      }
    });
    return;
  }

  // POST /api/send-invite — chat invite push (regular APNs alert / FCM notification)
  if (pathname === '/api/send-invite' && req.method === 'POST') {
    {
      const inviteIp = TRUST_PROXY
        ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
        : (req.socket.remoteAddress || 'unknown');
      logDebug('[PUSH]', pathname, 'from', anonymizeIp(inviteIp));
    }
    const reqIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    if (!checkRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Too many requests' }));
      return;
    }
    if (!checkPushRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Push rate limit exceeded' }));
      return;
    }

    let body = '';
    let destroyed = false;
    req.on('data', (chunk) => {
      if (destroyed) return;
      body += chunk;
      if (body.length > 1024) {
        destroyed = true;
        res.writeHead(413);
        res.end('Payload Too Large');
        req.destroy();
      }
    });
    req.on('end', async () => {
      if (destroyed) return;
      try {
        const data = JSON.parse(body);
        const { token, platform, payload } = data;

        if (!token || typeof token !== 'string') {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid token' }));
          return;
        }

        if (!payload || typeof payload !== 'object') {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid payload' }));
          return;
        }

        const { roomId, inviterName } = payload;
        if (!roomId || typeof roomId !== 'string' || roomId.length > 100) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid roomId' }));
          return;
        }

        // Verify push authentication
        if (IS_PRODUCTION && TURN_SECRET) {
          const auth = data.auth;
          if (!auth || !verifyPushAuth(token, roomId || '', auth, reqIp)) {
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Unauthorized' }));
            return;
          }
        }

        const safeName = (inviterName || 'Ghost Chat').substring(0, 50);

        if (platform === 'android') {
          // FCM v1 data message for Android
          if (!fcmServiceAccount) {
            res.writeHead(503, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'FCM not configured' }));
            return;
          }

          if (token.length < 50 || token.length > 300) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Invalid FCM token' }));
            return;
          }

          const result = await sendFcmPush(token, {
            type: 'chat-invite',
            roomId: roomId,
            inviterName: safeName
          });

          zeroOut(data, 'token');
          body = '0'.repeat(body.length);

          if (result.ok) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true }));
            logDebug('[PUSH] Sent to FCM invite status:', result.status);
          } else {
            res.writeHead(502, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'FCM error' }));
            logDebug('[PUSH] Failed FCM invite status:', result.status);
          }
        } else {
          // iOS regular APNs alert
          if (!apnsPrivateKey) {
            res.writeHead(503, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Push not configured' }));
            return;
          }

          if (!/^[0-9a-f]{64}$/i.test(token)) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Invalid APNs token' }));
            return;
          }

          const alertPayload = {
            aps: {
              alert: {
                title: 'Ghost Chat',
                body: `Chat invite from ${safeName}`
              },
              sound: 'default',
              'mutable-content': 1
            },
            type: 'chat-invite',
            roomId: roomId,
            inviterName: safeName
          };

          const result = await sendApnsAlert(token, alertPayload);

          zeroOut(data, 'token');
          body = '0'.repeat(body.length);

          if (result.status === 200) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true }));
            logDebug('[PUSH] Sent to APNs invite status:', result.status);
          } else {
            res.writeHead(502, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Push delivery failed' }));
            logDebug('[PUSH] Failed APNs invite status:', result.status, 'data:', result.data);
          }
        }
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Internal error' }));
        logError('[PUSH Invite]', err);
      }
    });
    return;
  }

  // POST /api/push/notify — universal push notification relay
  // Handles: new-message, missed-call
  // Server is a dumb proxy: receives token → sends push → zeros out all data
  if (pathname === '/api/push/notify' && req.method === 'POST') {
    {
      const notifyIp = TRUST_PROXY
        ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
        : (req.socket.remoteAddress || 'unknown');
      logDebug('[PUSH]', pathname, 'from', anonymizeIp(notifyIp));
    }
    const reqIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    if (!checkRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Too many requests' }));
      return;
    }
    if (!checkPushRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Push rate limit exceeded' }));
      return;
    }

    let body = '';
    let destroyed = false;
    req.on('data', (chunk) => {
      if (destroyed) return;
      body += chunk;
      if (body.length > 1024) {
        destroyed = true;
        res.writeHead(413);
        res.end('Payload Too Large');
        req.destroy();
      }
    });
    req.on('end', async () => {
      if (destroyed) return;
      try {
        const data = JSON.parse(body);
        const { token, platform, senderName } = data;
        // Validate type — only allowed notification types
        const notifyType = data.type;
        logDebug('[PUSH] /api/push/notify parse OK, type=', notifyType, 'platform=', platform, 'tokenLen=', (token || '').length, 'senderNameLen=', (senderName || '').length);
        if (!notifyType || !['new-message', 'missed-call'].includes(notifyType)) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid type' }));
          zeroOut(data, 'token', 'senderName');
          return;
        }

        if (!token || typeof token !== 'string') {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid token' }));
          zeroOut(data, 'token', 'senderName');
          return;
        }

        // Verify push authentication (используем senderName вместо roomId)
        if (IS_PRODUCTION && TURN_SECRET) {
          const auth = data.auth;
          if (!auth || !verifyPushAuth(token, senderName || '', auth, reqIp)) {
            logDebug('[PUSH] notify auth FAILED for', anonymizeIp(reqIp), 'auth=', auth ? auth.substring(0, 8) + '...' : 'missing', 'type=', notifyType);
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Unauthorized' }));
            zeroOut(data, 'token', 'senderName');
            return;
          }
          logDebug('[PUSH] notify auth OK for', anonymizeIp(reqIp), 'type=', notifyType);
        }

        const safeName = (senderName || 'Ghost Chat').substring(0, 50);

        // Localization keys for APNs (resolved by iOS from Localizable.strings)
        const locKeys = {
          'new-message': { titleKey: 'push.newMessage.title', bodyKey: 'push.newMessage.body' },
          'missed-call': { titleKey: 'push.missedCall.title', bodyKey: 'push.missedCall.body' }
        };
        // Fallback text for FCM / Android (localized on client)
        const fallbackText = {
          'new-message': { title: 'Ghost Chat', body: `New message from ${safeName}` },
          'missed-call': { title: 'Ghost Chat', body: `Missed call from ${safeName}` }
        };

        if (platform === 'android') {
          if (!fcmServiceAccount) {
            res.writeHead(503, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'FCM not configured' }));
            zeroOut(data, 'token', 'senderName');
            return;
          }
          if (token.length < 50 || token.length > 300) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Invalid FCM token' }));
            zeroOut(data, 'token', 'senderName');
            return;
          }

          const result = await sendFcmPush(token, {
            type: notifyType,
            senderName: safeName,
            title: fallbackText[notifyType].title,
            body: fallbackText[notifyType].body
          });

          // Zero out ALL sensitive data immediately after sending
          zeroOut(data, 'token', 'senderName');
          body = '0'.repeat(body.length);

          if (result.ok) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true }));
            logDebug('[PUSH] Sent to FCM notify type:', notifyType, 'status:', result.status);
          } else {
            res.writeHead(502, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'FCM error' }));
            logDebug('[PUSH] Failed FCM notify type:', notifyType, 'status:', result.status);
          }
        } else {
          // iOS — regular APNs alert push
          if (!apnsPrivateKey) {
            res.writeHead(503, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Push not configured' }));
            zeroOut(data, 'token', 'senderName');
            return;
          }
          if (!/^[0-9a-f]{64}$/i.test(token)) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Invalid APNs token' }));
            zeroOut(data, 'token', 'senderName');
            return;
          }

          const keys = locKeys[notifyType];
          const alertPayload = {
            aps: {
              alert: {
                'title-loc-key': keys.titleKey,
                'loc-key': keys.bodyKey,
                'loc-args': [safeName]
              },
              sound: 'default',
              'mutable-content': 1
            },
            type: notifyType,
            senderName: safeName
          };

          const result = await sendApnsAlert(token, alertPayload);

          // Zero out ALL sensitive data immediately after sending
          zeroOut(data, 'token', 'senderName');
          body = '0'.repeat(body.length);

          if (result.status === 200) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true }));
            logDebug('[PUSH] Sent to APNs notify type:', notifyType, 'status:', result.status);
          } else if (result.status === 410) {
            // Token is no longer active for this topic — client should drop it
            res.writeHead(410, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'token-invalid', action: 'drop-token' }));
            logDebug('[PUSH] APNs notify 410 (stale token), data:', result.data);
          } else {
            res.writeHead(502, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Push delivery failed', apnsStatus: result.status }));
            logDebug('[PUSH] Failed APNs notify type:', notifyType, 'status:', result.status, 'data:', result.data);
          }
        }
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Internal error' }));
        logDebug('[PUSH] Failed notify error:', err.message);
        logError('[PUSH Notify]', err);
      }
    });
    return;
  }

  // POST /api/pending-room — register a room for an offline contact
  if (pathname === '/api/pending-room' && req.method === 'POST') {
    const pendingIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    logDebug('[PENDING] POST /api/pending-room from', anonymizeIp(pendingIp));
    let body = '';
    req.on('data', c => { body += c; if (body.length > 1024) req.destroy(); });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const { peerHash, roomId, creatorHash } = data;
        logDebug('[PENDING] POST parse OK, peerHash=', (peerHash || '').substring(0, 8), 'roomId=', (roomId || '').substring(0, 8), 'creatorHash=', (creatorHash || '').substring(0, 8));
        if (!roomId || typeof roomId !== 'string' || !/^[A-Za-z0-9_-]{8,100}$/.test(roomId)) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid roomId format' }));
          return;
        }
        if (!peerHash || !creatorHash ||
            typeof peerHash !== 'string' || typeof creatorHash !== 'string' ||
            !/^[0-9a-f]{64}$/.test(peerHash) || !/^[0-9a-f]{64}$/.test(creatorHash)) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Invalid params' }));
          return;
        }
        pendingRooms.set(peerHash, { roomId, creatorHash, createdAt: Date.now() });
        logDebug('[PENDING] Room registered for peer', peerHash.substring(0, 8) + '...', 'room', roomId.substring(0, 8) + '...');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Bad request' }));
      }
    });
    return;
  }

  // GET /api/pending-room — check if anyone created a room for me
  if (pathname === '/api/pending-room' && req.method === 'GET') {
    const pendingGetIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    const myHash = parsedUrl.searchParams.get('myHash');
    logDebug('[PENDING] GET /api/pending-room from', anonymizeIp(pendingGetIp), 'myHash=', (myHash || '').substring(0, 8));
    if (!myHash || myHash.length !== 64) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid myHash' }));
      return;
    }
    const now = Date.now();
    for (const [k, v] of pendingRooms) {
      if (now - v.createdAt > PENDING_ROOM_TTL) pendingRooms.delete(k);
    }
    const pending = pendingRooms.get(myHash);
    if (pending && rooms.has(pending.roomId)) {
      pendingRooms.delete(myHash);
      logDebug('[PENDING] Room found for', myHash.substring(0, 8) + '...', 'room', pending.roomId.substring(0, 8) + '...');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ roomId: pending.roomId, creatorHash: pending.creatorHash }));
    } else {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ roomId: null }));
    }
    return;
  }

  // DELETE /api/pending-room — cleanup
  if (pathname === '/api/pending-room' && req.method === 'DELETE') {
    const pendingDelIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    const myHash = parsedUrl.searchParams.get('myHash');
    logDebug('[PENDING] DELETE /api/pending-room from', anonymizeIp(pendingDelIp), 'myHash=', (myHash || '').substring(0, 8));
    if (myHash) pendingRooms.delete(myHash);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  // Only allow GET and HEAD methods for static files (attack surface reduction)
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { 'Allow': 'GET, HEAD, POST' });
    res.end('Method Not Allowed');
    return;
  }

  // Reject suspiciously long URLs (potential buffer overflow / path traversal)
  if (req.url.length > 2048) {
    res.writeHead(414);
    res.end('URI Too Long');
    return;
  }

  // API endpoint for TURN credentials (rate limited)
  if (pathname === '/api/turn-credentials' && req.method === 'GET') {
    const reqIp = TRUST_PROXY
      ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
      : (req.socket.remoteAddress || 'unknown');
    logDebug('[TURN] GET /api/turn-credentials from', anonymizeIp(reqIp), 'ua:', (req.headers['user-agent'] || '').substring(0, 50));
    if (!checkRateLimit(reqIp)) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Too many requests' }));
      logDebug('[RATE] Blocked TURN request from', anonymizeIp(reqIp));
      return;
    }
    const credentials = generateTurnCredentials();
    if (!credentials) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'TURN not configured' }));
      return;
    }
    // Include push auth token — clients use it to authenticate push requests
    // Auth = HMAC(TURN_SECRET, "push:" + IP + window) — valid for 5 min window
    if (TURN_SECRET) {
      const pushWindow = Math.floor(Date.now() / 300000);
      credentials.pushAuth = createHmac('sha256', TURN_SECRET)
        .update('push:' + reqIp + ':' + pushWindow)
        .digest('hex');
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(credentials));
    logDebug('[TURN] Credentials generated for', anonymizeIp(reqIp));
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
  } else if (pathname === '/.well-known/apple-app-site-association') {
    filePath = join(clientDir, '.well-known', 'apple-app-site-association');
    contentType = 'application/json';
  } else if (pathname === '/.well-known/assetlinks.json') {
    filePath = join(clientDir, '.well-known', 'assetlinks.json');
    contentType = 'application/json';
  } else if (pathname === '/GhostChat.apk') {
    filePath = join(clientDir, 'GhostChat.apk');
    contentType = 'application/vnd.android.package-archive';
  } else if (pathname.startsWith('/fonts/') && (pathname.endsWith('.woff2') || pathname.endsWith('.woff'))) {
    filePath = join(clientDir, pathname);
    contentType = pathname.endsWith('.woff2') ? 'font/woff2' : 'font/woff';
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

    // ETag на основе SHA-256 хеша содержимого файла
    const etag = '"' + createHash('sha256').update(content).digest('hex') + '"';

    // Если браузер прислал If-None-Match и хеш совпадает — 304
    const ifNoneMatch = req.headers['if-none-match'];
    if (ifNoneMatch === etag) {
      res.writeHead(304);
      res.end();
      return;
    }

    const headers = {
      'Content-Type': contentType,
      'ETag': etag
    };

    // HTML, JS, CSS — всегда проверять свежесть (no-cache = revalidate каждый раз)
    if (pathname.endsWith('.html') || pathname.endsWith('.js') || pathname.endsWith('.css') || pathname === '/') {
      headers['Cache-Control'] = 'no-cache';
    }
    // Иконки и шрифты — кэшировать, но тоже с ETag
    else if (pathname.startsWith('/icons/') || pathname.startsWith('/fonts/')) {
      headers['Cache-Control'] = 'public, max-age=604800'; // 7 дней
    }
    // APK — кэшировать на день
    else if (pathname.endsWith('.apk')) {
      headers['Cache-Control'] = 'public, max-age=86400';
    }

    // SRI: Inject integrity attributes into index.html for script/link tags
    if (pathname === '/' || pathname === '/index.html') {
      let html = content.toString();
      // Inject integrity for CSS
      const cssHash = sriHashes.get('css/style.css');
      if (cssHash) {
        html = html.replace(
          'rel="stylesheet" href="css/style.css"',
          `rel="stylesheet" href="css/style.css" integrity="${cssHash}" crossorigin="anonymous"`
        );
      }
      // Inject integrity for scripts (regex handles optional ?v=N cache-bust query strings)
      for (const [file, hash] of sriHashes) {
        if (file.startsWith('js/')) {
          const escaped = file.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          const re = new RegExp(`src="${escaped}(\\?[^"]*)?"`);
          html = html.replace(re, (match) => {
            // Replace closing quote with integrity + crossorigin attrs
            return match.slice(0, -1) + `" integrity="${hash}" crossorigin="anonymous"`;
          });
        }
      }
      // Recompute ETag for modified HTML
      const sriEtag = '"' + createHash('sha256').update(html).digest('hex') + '"';
      headers['ETag'] = sriEtag;
      if (ifNoneMatch === sriEtag) {
        res.writeHead(304);
        res.end();
        return;
      }
      res.writeHead(200, headers);
      res.end(html);
    } else {
      res.writeHead(200, headers);
      res.end(content);
    }
  } catch {
    res.writeHead(404);
    res.end('Not Found');
  }
});

// WebSocket сервер для signaling
const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: 16 * 1024, // 16 KB — достаточно для signaling (SDP ~2KB, ICE <1KB)
  // Validate WebSocket upgrade path — only allow /ws endpoint
  verifyClient: ({ req }) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    return url.pathname === '/ws';
  }
});

// Per-IP WebSocket connection limit — защита от исчерпания ресурсов
const wsConnections = new Map(); // ip -> count
const MAX_WS_PER_IP = 10;

// Per-room join rate limiting (M1) — prevents brute-force room ID guessing
// Map<roomId, { attempts: number, lastAttempt: timestamp }>
const roomJoinLimits = new Map();
const ROOM_JOIN_LIMIT = 5; // max join attempts per room per window
const ROOM_JOIN_WINDOW = 60000; // 1 minute

function checkRoomJoinLimit(roomId) {
  const now = Date.now();
  let record = roomJoinLimits.get(roomId);
  if (!record) {
    record = { attempts: 0, lastAttempt: now };
    roomJoinLimits.set(roomId, record);
  }
  if (now - record.lastAttempt > ROOM_JOIN_WINDOW) {
    record.attempts = 0;
  }
  record.attempts++;
  record.lastAttempt = now;
  if (record.attempts > ROOM_JOIN_LIMIT) {
    logDebug('[RATE] Room join limit for', roomId.substring(0, 8) + '...', 'attempts:', record.attempts);
  }
  return record.attempts <= ROOM_JOIN_LIMIT;
}

// Cleanup room join limits periodically
setInterval(() => {
  if (roomJoinLimits.size > RATE_LIMIT_MAX_ENTRIES) {
    roomJoinLimits.clear();
    return;
  }
  const now = Date.now();
  roomJoinLimits.forEach((record, roomId) => {
    if (now - record.lastAttempt > ROOM_JOIN_WINDOW * 2) {
      roomJoinLimits.delete(roomId);
    }
  });
}, 120000);

// Allowed signal data types (H3)
const ALLOWED_SIGNAL_TYPES = new Set(['offer', 'answer', 'ice-candidate']);

// Allowed WebSocket message types — reject unknown types (attack surface reduction)
const ALLOWED_WS_MESSAGE_TYPES = new Set([
  'create-room', 'join-room', 'rejoin-room', 'signal', 'leave-room'
]);

wss.on('connection', (ws, req) => {
  let currentRoom = null;
  let peerId = null;

  // Per-connection signal rate limiting (M8) — prevents signal message flood
  let signalCount = 0;
  let signalWindowStart = Date.now();
  const SIGNAL_RATE_LIMIT = 10; // max signals per second
  const SIGNAL_RATE_WINDOW = 1000; // 1 second

  // Получаем IP клиента
  // ВАЖНО: X-Forwarded-For можно спуфить! Доверяем только если сервер за нашим прокси
  const clientIp = TRUST_PROXY
    ? (req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress)
    : (req.socket.remoteAddress || 'unknown');

  // Per-IP WebSocket connection limit
  const connCount = wsConnections.get(clientIp) || 0;
  if (connCount >= MAX_WS_PER_IP) {
    logDebug('[WS] Connection limit reached for', anonymizeIp(clientIp));
    ws.close(1008, 'Too many connections');
    return;
  }
  wsConnections.set(clientIp, connCount + 1);
  logDebug('[WS] New connection from', anonymizeIp(clientIp), 'total:', connCount + 1);

  // Guard against double-decrement (close always fires after error)
  let disconnected = false;

  // Для ping/pong проверки соединения
  ws.isAlive = true;
  ws.on('pong', () => {
    ws.isAlive = true;
  });

  ws.on('message', (data) => {
    try {
      // Reject non-string data (binary frames)
      const str = data.toString();
      if (str.length > 16384) return; // 16KB max for signaling messages

      const message = JSON.parse(str);

      // Whitelist message types — reject unknown
      if (!message.type || !ALLOWED_WS_MESSAGE_TYPES.has(message.type)) return;

      logDebug('[WS] Message from', anonymizeIp(clientIp), ':', message.type);

      switch (message.type) {
        case 'create-room': {
          // Rate limit room creation
          if (!checkRateLimit(clientIp)) {
            logDebug('[RATE] Blocked create-room from', anonymizeIp(clientIp));
            ws.send(JSON.stringify({ type: 'error', message: 'Слишком много запросов. Подождите.' }));
            return;
          }
          if (rooms.size >= MAX_ROOMS) {
            ws.send(JSON.stringify({ type: 'error', message: 'Сервер перегружен. Попробуйте позже.' }));
            return;
          }
          const roomId = generateRoomId();
          rooms.set(roomId, { peers: new Set([ws]), inviteUsed: false, createdAt: Date.now(), lastEmptyAt: null });
          currentRoom = roomId;
          peerId = 'host';
          ws.send(JSON.stringify({ type: 'room-created', roomId }));
          logDebug('[ROOM] Created', roomId.substring(0, 8) + '...', 'by', anonymizeIp(clientIp), 'total rooms:', rooms.size);
          break;
        }

        case 'rejoin-room': {
          // Rate limit rejoin (защита от brute force как и join-room)
          if (!checkRateLimit(clientIp)) {
            ws.send(JSON.stringify({ type: 'error', message: 'Слишком много попыток. Подождите.' }));
            return;
          }
          const rejoinId = message.roomId?.trim();
          if (!rejoinId) return;
          // Per-room rate limit (M1)
          if (!checkRoomJoinLimit(rejoinId)) {
            ws.send(JSON.stringify({ type: 'error', message: 'Слишком много попыток входа в эту комнату.' }));
            return;
          }
          const rejoinRoom = rooms.get(rejoinId);
          if (!rejoinRoom) {
            ws.send(JSON.stringify({ type: 'error', message: 'Комната не найдена' }));
            return;
          }
          // Убираем мёртвые соединения
          // Clean dead peers safely (no modification during iteration)
          const deadRejoinPeers = [];
          for (const c of rejoinRoom.peers) { if (c.readyState !== 1) deadRejoinPeers.push(c); }
          for (const c of deadRejoinPeers) rejoinRoom.peers.delete(c);
          // Проверяем лимит участников (макс 2)
          if (rejoinRoom.peers.size >= 2) {
            ws.send(JSON.stringify({ type: 'error', message: 'Комната заполнена' }));
            return;
          }
          rejoinRoom.peers.add(ws);
          currentRoom = rejoinId;
          // H4: Server stores and enforces peer roles — don't trust client-provided role
          // For rejoin, we accept the role only if the room has metadata about roles
          // Since rooms track by ws objects, a reconnecting peer gets a fresh ws — accept role for now
          // but validate it's either 'host' or 'guest'
          const requestedRole = message.role;
          peerId = (requestedRole === 'host' || requestedRole === 'guest') ? requestedRole : 'guest';
          ws.send(JSON.stringify({ type: 'rejoin-ok', roomId: rejoinId }));
          logDebug('[ROOM] Rejoin', rejoinId.substring(0, 8) + '...', 'by', anonymizeIp(clientIp), 'role:', peerId, 'peers:', rejoinRoom.peers.size);
          // Если оба участника на месте — уведомляем ОБОИХ для нового WebRTC handshake
          if (rejoinRoom.peers.size === 2) {
            logDebug('[ROOM] Notifying peer-joined in', rejoinId.substring(0, 8) + '...', '(rejoin, both peers present)');
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
          if (!roomId) return;
          // Per-room rate limit (M1) — prevents brute-force guessing of room IDs
          if (!checkRoomJoinLimit(roomId)) {
            ws.send(JSON.stringify({ type: 'error', message: 'Слишком много попыток входа в эту комнату.' }));
            return;
          }
          const room = rooms.get(roomId);
          if (!room) {
            ws.send(JSON.stringify({ type: 'error', message: 'Комната не найдена' }));
            return;
          }
          // CRITICAL FIX: Set inviteUsed BEFORE any async operations to prevent TOCTOU race
          // Two guests sending join-room simultaneously could both pass the check otherwise
          if (room.inviteUsed) {
            ws.send(JSON.stringify({ type: 'error', message: 'Ссылка-приглашение уже использована' }));
            return;
          }
          room.inviteUsed = true; // Atomically mark BEFORE cleanup/add

          // Clean dead peers — collect first, then delete (avoid Set modification during iteration)
          const deadPeers = [];
          for (const c of room.peers) { if (c.readyState !== 1) deadPeers.push(c); }
          for (const c of deadPeers) room.peers.delete(c);

          if (room.peers.size >= 2) {
            room.inviteUsed = false; // Rollback — room is actually full
            ws.send(JSON.stringify({ type: 'error', message: 'Комната заполнена' }));
            return;
          }
          room.peers.add(ws);
          currentRoom = roomId;
          peerId = 'guest';
          ws.send(JSON.stringify({ type: 'room-joined', roomId }));
          logDebug('[ROOM] Join', roomId.substring(0, 8) + '...', 'by', anonymizeIp(clientIp), 'peers:', room.peers.size);
          room.peers.forEach(client => {
            if (client !== ws && client.readyState === 1) {
              logDebug('[ROOM] Notifying peer-joined in', roomId.substring(0, 8) + '...');
              client.send(JSON.stringify({ type: 'peer-joined' }));
            }
          });
          break;
        }

        case 'signal': {
          if (!currentRoom) return;
          // M8: Per-connection signal rate limit
          const now = Date.now();
          if (now - signalWindowStart > SIGNAL_RATE_WINDOW) {
            signalCount = 0;
            signalWindowStart = now;
          }
          signalCount++;
          if (signalCount > SIGNAL_RATE_LIMIT) return; // silently drop excess

          // H3: Validate signal.data.type — only allow WebRTC signaling types
          if (!message.data || !ALLOWED_SIGNAL_TYPES.has(message.data.type)) return;

          const signalRoom = rooms.get(currentRoom);
          if (!signalRoom) return;

          // Whitelist signal relay fields — пропускаем только разрешённые поля
          // SDP может быть строкой (web) или объектом {type, sdp} (iOS/Android)
          const sanitizedData = { type: message.data.type };
          if (message.data.type === 'offer' || message.data.type === 'answer') {
            if (typeof message.data.sdp === 'string') {
              sanitizedData.sdp = message.data.sdp;
            } else if (message.data.sdp && typeof message.data.sdp === 'object') {
              // iOS/Android: sdp = { type: "offer"|"answer", sdp: "v=0\r\n..." }
              const sdpObj = {};
              if (typeof message.data.sdp.type === 'string') sdpObj.type = message.data.sdp.type;
              if (typeof message.data.sdp.sdp === 'string') sdpObj.sdp = message.data.sdp.sdp;
              if (sdpObj.sdp) sanitizedData.sdp = sdpObj;
            }
          } else if (message.data.type === 'ice-candidate') {
            // candidate может быть строкой (web) или объектом (iOS/Android)
            if (typeof message.data.candidate === 'string') {
              sanitizedData.candidate = message.data.candidate;
            } else if (message.data.candidate && typeof message.data.candidate === 'object') {
              const cObj = {};
              if (typeof message.data.candidate.candidate === 'string') cObj.candidate = message.data.candidate.candidate;
              if (typeof message.data.candidate.sdpMid === 'string') cObj.sdpMid = message.data.candidate.sdpMid;
              if (typeof message.data.candidate.sdpMLineIndex === 'number') cObj.sdpMLineIndex = message.data.candidate.sdpMLineIndex;
              if (cObj.candidate) sanitizedData.candidate = cObj;
            }
            if (typeof message.data.sdpMid === 'string') sanitizedData.sdpMid = message.data.sdpMid;
            if (typeof message.data.sdpMLineIndex === 'number') sanitizedData.sdpMLineIndex = message.data.sdpMLineIndex;
          }

          logDebug('[SIGNAL]', sanitizedData.type, 'in room', currentRoom.substring(0, 8) + '...', 'from', anonymizeIp(clientIp));
          signalRoom.peers.forEach(client => {
            if (client !== ws && client.readyState === 1) {
              client.send(JSON.stringify({ type: 'signal', data: sanitizedData }));
            }
          });
          break;
        }

        case 'leave-room': {
          logDebug('[ROOM] Leave (explicit)', currentRoom ? currentRoom.substring(0, 8) + '...' : 'none', 'by', anonymizeIp(clientIp));
          // НЕ вызываем handleDisconnect() — WS ещё открыт!
          // Только убираем peer из комнаты и уведомляем
          if (currentRoom) {
            const room = rooms.get(currentRoom);
            if (room) {
              room.peers.delete(ws);
              for (const client of room.peers) {
                try {
                  if (client.readyState === 1) {
                    client.send(JSON.stringify({ type: 'peer-left' }));
                  }
                } catch {}
              }
              if (room.peers.size === 0) {
                room.lastEmptyAt = Date.now();
              }
            }
            currentRoom = null;
            peerId = null;
          }
          break;
        }
      }
    } catch (e) {
      // JSON parse errors from garbage data are expected — don't log
      if (!(e instanceof SyntaxError)) {
        logError('[WS Message]', e);
      }
    }
  });

  function handleDisconnect() {
    if (disconnected) return;
    disconnected = true;

    logDebug('[WS] Disconnect from', anonymizeIp(clientIp), 'room:', currentRoom ? currentRoom.substring(0, 8) + '...' : 'none', 'role:', peerId);

    // Уменьшаем счётчик WS-соединений для IP
    const count = wsConnections.get(clientIp) || 1;
    if (count <= 1) wsConnections.delete(clientIp);
    else wsConnections.set(clientIp, count - 1);

    if (currentRoom) {
      const room = rooms.get(currentRoom);
      if (room) {
        room.peers.delete(ws);

        // Уведомляем оставшегося участника (safe send — readyState может измениться между проверкой и отправкой)
        for (const client of room.peers) {
          try {
            if (client.readyState === 1) {
              client.send(JSON.stringify({ type: 'peer-left' }));
            }
          } catch {}
        }

        // Запоминаем момент, когда комната стала пустой (для TTL)
        if (room.peers.size === 0) {
          room.lastEmptyAt = Date.now();
        }

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
    // Запоминаем момент, когда комната стала пустой (для TTL)
    if (room.peers.size === 0 && !room.lastEmptyAt) {
      room.lastEmptyAt = now;
    } else if (room.peers.size > 0) {
      room.lastEmptyAt = null;
    }
    // Удаляем комнату только если она пустая И просрочена по TTL (с момента опустения)
    if (room.peers.size === 0 && room.lastEmptyAt && now - room.lastEmptyAt > ROOM_TTL) {
      rooms.delete(roomId);
      logDebug('[ROOM] Cleanup: deleted', roomId.substring(0, 8) + '...', 'remaining rooms:', rooms.size);
    }
  });

  // Clean expired pending rooms
  const pendingNow = Date.now();
  for (const [k, v] of pendingRooms) {
    if (pendingNow - v.createdAt > PENDING_ROOM_TTL) pendingRooms.delete(k);
  }
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
