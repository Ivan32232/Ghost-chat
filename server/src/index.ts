// Force IPv4 — Docker bridge networks lack IPv6, Node.js prefers AAAA
// and silently fails on APNs/FCM HTTP/2 connections without this.
import dns from 'node:dns';
dns.setDefaultResultOrder('ipv4first');

import { createServer } from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import helmet from 'helmet';
import {
  setupSignaling, getClientIp,
  setPendingRoom, getPendingRoom, deletePendingRoom,
} from './signaling.js';
import {
  generateCredentials, verifyPushAuth,
  requireTurnInProduction, isTurnConfigured,
} from './turn.js';
import {
  initPush, isApnsReady, isFcmReady,
  sendVoipPush, sendAlertPush, sendFcmPush, closePush,
} from './push.js';
import { checkConnectionRate, checkPushRate } from './rate-limiter.js';

const PORT = Number(process.env.PORT) || 3000;
const IS_PRODUCTION = process.env.NODE_ENV === 'production';

// --- Startup checks ---
requireTurnInProduction();
initPush();

// --- Security headers (helmet works with raw http — same req/res interface) ---
const secure = helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'"],
      connectSrc: ["'self'", 'wss:', 'ws:'],
      imgSrc: ["'self'", 'data:'],
      fontSrc: ["'self'"],
      objectSrc: ["'none'"],
      frameAncestors: ["'none'"],
      baseUri: ["'self'"],
      formAction: ["'self'"],
    },
  },
  hsts: { maxAge: 63072000, includeSubDomains: true, preload: true },
  crossOriginOpenerPolicy: { policy: 'same-origin' },
  crossOriginResourcePolicy: { policy: 'same-origin' },
});

// --- Helpers ---

function json(res: ServerResponse, status: number, data: object): void {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function parseBody<T = any>(req: IncomingMessage, maxSize = 1024): Promise<T> {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk: string) => {
      body += chunk;
      if (body.length > maxSize) { req.destroy(); reject(new Error('Payload too large')); }
    });
    req.on('end', () => {
      try { resolve(JSON.parse(body) as T); }
      catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

// --- HTTP Server ---

const server = createServer((req: IncomingMessage, res: ServerResponse) => {
  (secure as any)(req, res, () => handleRequest(req, res));
});

async function handleRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url!, `http://${req.headers.host}`);
  const path = url.pathname;
  const method = req.method!;
  const ip = getClientIp(req);

  // Path traversal defense
  if (path.includes('..') || path.includes('\0')) {
    res.writeHead(400); res.end('Bad Request'); return;
  }

  try {
    // --- Health ---
    if (path === '/health' && method === 'GET') {
      json(res, 200, { status: 'ok', uptime: Math.floor(process.uptime()) });
      return;
    }

    // --- TURN credentials ---
    if (path === '/api/turn-credentials' && method === 'GET') {
      if (!(await checkConnectionRate(ip))) { json(res, 429, { error: 'Too many requests' }); return; }
      const creds = generateCredentials(ip);
      if (!creds) { json(res, 503, { error: 'TURN not configured' }); return; }
      json(res, 200, creds);
      return;
    }

    // --- Pending room (POST/GET/DELETE) ---
    if (path === '/api/pending-room') {
      await handlePendingRoom(method, url, req, res);
      return;
    }

    // --- Push routes (all POST) ---
    if (method === 'POST') {
      const pushPaths = new Set(['/api/send-push', '/api/send-push-android', '/api/send-invite', '/api/push/notify']);
      if (pushPaths.has(path)) {
        await handlePush(path, req, res, ip);
        return;
      }
    }

    // --- 404 ---
    res.writeHead(404); res.end('Not Found');
  } catch (e) {
    const msg = (e as Error).message;
    if (msg === 'Payload too large') { res.writeHead(413); res.end('Payload Too Large'); }
    else if (msg === 'Invalid JSON') { json(res, 400, { error: 'Bad request' }); }
    else { json(res, 500, { error: 'Internal error' }); }
  }
}

// --- Push route handler ---

async function handlePush(
  path: string, req: IncomingMessage, res: ServerResponse, ip: string,
): Promise<void> {
  if (!(await checkPushRate(ip))) { json(res, 429, { error: 'Too many requests' }); return; }
  const data = await parseBody(req);

  switch (path) {
    case '/api/send-push': {
      if (!isApnsReady()) { json(res, 503, { error: 'Push not configured' }); return; }
      const { token, payload, auth } = data;
      if (!token || !/^[0-9a-f]{64}$/i.test(token)) { json(res, 400, { error: 'Invalid token' }); return; }
      if (!payload?.roomId) { json(res, 400, { error: 'Invalid payload' }); return; }
      if (IS_PRODUCTION && !verifyPushAuth(token, payload.roomId, auth, ip)) {
        json(res, 403, { error: 'Unauthorized' }); return;
      }
      const name = (payload.callerName || 'Ghost Chat').substring(0, 50);
      const result = await sendVoipPush(token, { aps: {}, roomId: payload.roomId, callerName: name });
      if (result.ok) json(res, 200, { success: true });
      else if (result.status === 410) json(res, 410, { error: 'token-invalid', action: 'drop-token' });
      else json(res, 502, { error: 'Push delivery failed', apnsStatus: result.status });
      break;
    }

    case '/api/send-push-android': {
      if (!isFcmReady()) { json(res, 503, { error: 'FCM not configured' }); return; }
      const { token, payload, auth } = data;
      if (!token || token.length < 50 || token.length > 300) { json(res, 400, { error: 'Invalid token' }); return; }
      if (!payload?.roomId) { json(res, 400, { error: 'Invalid payload' }); return; }
      if (IS_PRODUCTION && !verifyPushAuth(token, payload.roomId, auth, ip)) {
        json(res, 403, { error: 'Unauthorized' }); return;
      }
      const name = (payload.callerName || 'Ghost Chat').substring(0, 50);
      const result = await sendFcmPush(token, { type: 'incoming_call', roomId: payload.roomId, callerName: name });
      json(res, result.ok ? 200 : 502, result.ok ? { success: true } : { error: 'Push delivery failed' });
      break;
    }

    case '/api/send-invite': {
      const { token, platform, payload, auth } = data;
      if (!token || !payload?.roomId) { json(res, 400, { error: 'Invalid params' }); return; }
      if (IS_PRODUCTION && !verifyPushAuth(token, payload.roomId, auth, ip)) {
        json(res, 403, { error: 'Unauthorized' }); return;
      }
      const name = (payload.inviterName || 'Ghost Chat').substring(0, 50);

      if (platform === 'android') {
        if (!isFcmReady()) { json(res, 503, { error: 'FCM not configured' }); return; }
        const r = await sendFcmPush(token, { type: 'chat-invite', roomId: payload.roomId, inviterName: name });
        json(res, r.ok ? 200 : 502, r.ok ? { success: true } : { error: 'FCM error' });
      } else {
        if (!isApnsReady()) { json(res, 503, { error: 'Push not configured' }); return; }
        if (!/^[0-9a-f]{64}$/i.test(token)) { json(res, 400, { error: 'Invalid APNs token' }); return; }
        const r = await sendAlertPush(token, {
          aps: { alert: { title: 'Ghost Chat', body: `Chat invite from ${name}` }, sound: 'default', 'mutable-content': 1 },
          type: 'chat-invite', roomId: payload.roomId, inviterName: name,
        });
        json(res, r.ok ? 200 : 502, r.ok ? { success: true } : { error: 'Push delivery failed' });
      }
      break;
    }

    case '/api/push/notify': {
      const { token, platform, senderName, type: notifyType, auth } = data;
      if (!notifyType || !['new-message', 'missed-call'].includes(notifyType)) {
        json(res, 400, { error: 'Invalid type' }); return;
      }
      if (!token) { json(res, 400, { error: 'Invalid token' }); return; }
      if (IS_PRODUCTION && !verifyPushAuth(token, senderName || '', auth, ip)) {
        json(res, 403, { error: 'Unauthorized' }); return;
      }

      const name = (senderName || 'Ghost Chat').substring(0, 50);
      const locKeys: Record<string, { titleKey: string; bodyKey: string }> = {
        'new-message': { titleKey: 'push.newMessage.title', bodyKey: 'push.newMessage.body' },
        'missed-call': { titleKey: 'push.missedCall.title', bodyKey: 'push.missedCall.body' },
      };

      if (platform === 'android') {
        if (!isFcmReady()) { json(res, 503, { error: 'FCM not configured' }); return; }
        const r = await sendFcmPush(token, {
          type: notifyType, senderName: name,
          title: 'Ghost Chat',
          body: notifyType === 'new-message' ? `New message from ${name}` : `Missed call from ${name}`,
        });
        json(res, r.ok ? 200 : 502, r.ok ? { success: true } : { error: 'FCM error' });
      } else {
        if (!isApnsReady()) { json(res, 503, { error: 'Push not configured' }); return; }
        if (!/^[0-9a-f]{64}$/i.test(token)) { json(res, 400, { error: 'Invalid APNs token' }); return; }
        const keys = locKeys[notifyType];
        const r = await sendAlertPush(token, {
          aps: {
            alert: { 'title-loc-key': keys.titleKey, 'loc-key': keys.bodyKey, 'loc-args': [name] },
            sound: 'default', 'mutable-content': 1,
          },
          type: notifyType, senderName: name,
        });
        if (r.ok) json(res, 200, { success: true });
        else if (r.status === 410) json(res, 410, { error: 'token-invalid', action: 'drop-token' });
        else json(res, 502, { error: 'Push delivery failed', apnsStatus: r.status });
      }
      break;
    }

    default:
      json(res, 404, { error: 'Not found' });
  }
}

// --- Pending room handler ---

async function handlePendingRoom(
  method: string, url: URL, req: IncomingMessage, res: ServerResponse,
): Promise<void> {
  if (method === 'POST') {
    const { peerHash, roomId, creatorHash } = await parseBody(req);
    if (!roomId || !/^[A-Za-z0-9_-]{8,100}$/.test(roomId)) {
      json(res, 400, { error: 'Invalid roomId' }); return;
    }
    if (
      !peerHash || !creatorHash ||
      !/^[0-9a-f]{64}$/.test(peerHash) ||
      !/^[0-9a-f]{64}$/.test(creatorHash)
    ) {
      json(res, 400, { error: 'Invalid params' }); return;
    }
    setPendingRoom(peerHash, roomId, creatorHash);
    json(res, 200, { ok: true });
    return;
  }

  if (method === 'GET') {
    const myHash = url.searchParams.get('myHash');
    if (!myHash || myHash.length !== 64) { json(res, 400, { error: 'Invalid myHash' }); return; }
    const result = getPendingRoom(myHash);
    json(res, 200, result ?? { roomId: null });
    return;
  }

  if (method === 'DELETE') {
    const myHash = url.searchParams.get('myHash');
    if (myHash) deletePendingRoom(myHash);
    json(res, 200, { ok: true });
    return;
  }

  res.writeHead(405); res.end('Method Not Allowed');
}

// --- Setup WebSocket on the same HTTP server ---
setupSignaling(server);

// --- Graceful shutdown ---
function shutdown(): void {
  console.log('[SERVER] Shutting down...');
  closePush();
  server.close();
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

process.on('uncaughtException', (err) => {
  console.error('[FATAL] Uncaught:', err.message);
  process.exit(1);
});
process.on('unhandledRejection', (reason) => {
  console.error('[WARN] Unhandled rejection:', reason);
});

// --- Start ---
server.listen(PORT, () => {
  console.log(`[SERVER] Ghost Chat v2 on :${PORT}`);
  console.log(`[SERVER] env=${IS_PRODUCTION ? 'production' : 'development'} turn=${isTurnConfigured()} apns=${isApnsReady()} fcm=${isFcmReady()}`);
});
