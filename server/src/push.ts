/**
 * APNs (raw HTTP/2) + FCM (raw REST) push delivery.
 *
 * No third-party push SDKs — Node.js built-in http2 + fetch.
 * APNs retry logic: persistent HTTP/2 connection, retry once on
 * transient errors (GOAWAY, stream cancelled, connection reset).
 * FCM: OAuth2 JWT from service account → REST v1 API.
 */

import http2 from 'node:http2';
import dns from 'node:dns';
import { createSign, createPrivateKey } from 'node:crypto';
import type { KeyObject } from 'node:crypto';
import { readFileSync } from 'node:fs';

const IS_PRODUCTION = process.env.NODE_ENV === 'production';

// --- APNs state ---
let apnsKey: KeyObject | null = null;
let apnsKeyId = '';
let apnsTeamId = '';
let apnsBundleId = '';
let apnsJwt = '';
let apnsJwtIssuedAt = 0;

// --- FCM state ---
let fcmSA: { client_email: string; private_key: string; project_id: string } | null = null;
let fcmToken = '';
let fcmTokenExpiry = 0;

// --- APNs HTTP/2 client pool ---
const apnsClients: Record<string, http2.ClientHttp2Session | null> = {
  production: null,
  sandbox: null,
};
const APNS_HOSTS: Record<string, string> = {
  production: 'api.push.apple.com:2197',
  sandbox: 'api.sandbox.push.apple.com:2197',
};
const PRIMARY = IS_PRODUCTION ? 'production' : 'sandbox';
const FALLBACK = IS_PRODUCTION ? 'sandbox' : 'production';

// ---------- Init ----------

export function initPush(): void {
  const keyId = process.env.APNS_KEY_ID;
  const teamId = process.env.APNS_TEAM_ID;
  const keyPath = process.env.APNS_KEY_PATH;
  if (keyId && teamId && keyPath) {
    try {
      apnsKey = createPrivateKey(readFileSync(keyPath));
      apnsKeyId = keyId;
      apnsTeamId = teamId;
      apnsBundleId = process.env.APNS_BUNDLE_ID ?? 'com.kordar.ghostchat';
      console.log('[PUSH] APNs configured');
    } catch (e) {
      console.error('[PUSH] APNs key failed:', (e as Error).message);
    }
  }

  const saPath = process.env.FCM_SA_PATH;
  if (saPath) {
    try {
      fcmSA = JSON.parse(readFileSync(saPath, 'utf-8'));
      console.log('[PUSH] FCM configured:', fcmSA!.project_id);
    } catch (e) {
      console.error('[PUSH] FCM init failed:', (e as Error).message);
    }
  }
}

export function isApnsReady(): boolean { return apnsKey !== null; }
export function isFcmReady(): boolean { return fcmSA !== null; }

// ---------- APNs HTTP/2 ----------

// Docker bridge networks lack IPv6 — force IPv4 for all HTTP/2 connections
function ipv4Lookup(hostname: string, options: any, cb: any): void {
  if (typeof options === 'function') { cb = options; options = {}; }
  dns.lookup(hostname, { ...options, family: 4 }, cb);
}

function getApnsJwt(): string {
  const now = Math.floor(Date.now() / 1000);
  // Cache JWT for 50 min (valid 60 min)
  if (apnsJwt && now - apnsJwtIssuedAt < 3000) return apnsJwt;

  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: apnsKeyId })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ iss: apnsTeamId, iat: now })).toString('base64url');
  const input = `${header}.${claims}`;

  const signer = createSign('SHA256');
  signer.update(input);
  // ieee-p1363 gives raw r||s (no DER wrapper) — APNs requires this format
  const sig = signer.sign({ key: apnsKey!, dsaEncoding: 'ieee-p1363' }).toString('base64url');

  apnsJwt = `${input}.${sig}`;
  apnsJwtIssuedAt = now;
  return apnsJwt;
}

function getApnsClient(env: string, forceNew = false): http2.ClientHttp2Session {
  const existing = apnsClients[env];
  if (
    !forceNew && existing &&
    !existing.closed && !existing.destroyed &&
    !(existing as any).receivedGoAway
  ) {
    return existing;
  }

  try { existing?.close(); } catch {}
  apnsClients[env] = null;

  const client = http2.connect(`https://${APNS_HOSTS[env]}`, {
    lookup: ipv4Lookup as unknown as typeof dns.lookup,
  });
  (client as any).receivedGoAway = false;

  client.on('error', () => { if (apnsClients[env] === client) apnsClients[env] = null; });
  client.on('goaway', () => {
    (client as any).receivedGoAway = true;
    if (apnsClients[env] === client) apnsClients[env] = null;
  });
  client.on('close', () => { if (apnsClients[env] === client) apnsClients[env] = null; });

  apnsClients[env] = client;
  return client;
}

export interface PushResult {
  ok: boolean;
  status: number;
  data: string;
}

function apnsRequest(
  env: string, token: string,
  headers: Record<string, string | number>,
  body: string, forceNew = false,
): Promise<PushResult> {
  return new Promise((resolve, reject) => {
    const client = getApnsClient(env, forceNew);
    let done = false;

    const timer = setTimeout(() => {
      if (!done) { done = true; try { req.close(); } catch {} reject(new Error('APNs timeout')); }
    }, 10_000);

    let req: http2.ClientHttp2Stream;
    try {
      req = client.request({ ':method': 'POST', ':path': `/3/device/${token}`, ...headers });
    } catch (e) {
      clearTimeout(timer);
      reject(e);
      return;
    }

    req.on('error', (e) => {
      if (!done) { done = true; clearTimeout(timer); reject(e); }
    });
    req.on('response', (h) => {
      const status = h[':status'] as number;
      let data = '';
      req.on('data', (c: Buffer) => { data += c; });
      req.on('end', () => {
        if (!done) { done = true; clearTimeout(timer); resolve({ ok: status === 200, status, data }); }
      });
    });

    req.write(body);
    req.end();
  });
}

// Retry once on transient HTTP/2 errors
const TRANSIENT_RE = /GOAWAY|CANCEL|INVALID_SESSION|ECONNRESET|hang up|Session closed|ENOTFOUND/;

async function apnsSend(
  env: string, token: string,
  headers: Record<string, string | number>,
  body: string,
): Promise<PushResult> {
  try {
    return await apnsRequest(env, token, headers, body);
  } catch (e) {
    if (TRANSIENT_RE.test((e as Error).message ?? '')) {
      return apnsRequest(env, token, headers, body, true);
    }
    throw e;
  }
}

function apnsHeaders(topic: string, pushType: string, expiration: string): Record<string, string | number> {
  return {
    'authorization': `bearer ${getApnsJwt()}`,
    'apns-topic': topic,
    'apns-push-type': pushType,
    'apns-priority': '10',
    'apns-expiration': expiration,
    'content-type': 'application/json',
  };
}

async function sendApnsWithFallback(
  token: string,
  headers: Record<string, string | number>,
  payload: object,
): Promise<PushResult> {
  const body = JSON.stringify(payload);
  (headers as Record<string, string | number>)['content-length'] = Buffer.byteLength(body);

  const result = await apnsSend(PRIMARY, token, headers, body);
  // Dev only: sandbox fallback on BadDeviceToken
  if (!IS_PRODUCTION && result.status === 400 && result.data.includes('BadDeviceToken')) {
    return apnsSend(FALLBACK, token, headers, body);
  }
  return result;
}

export async function sendVoipPush(token: string, payload: object): Promise<PushResult> {
  return sendApnsWithFallback(
    token,
    apnsHeaders(`${apnsBundleId}.voip`, 'voip', '0'),
    payload,
  );
}

export async function sendAlertPush(token: string, payload: object): Promise<PushResult> {
  return sendApnsWithFallback(
    token,
    apnsHeaders(apnsBundleId, 'alert', '86400'),
    payload,
  );
}

// ---------- FCM v1 REST API ----------

// Overridable URLs for testing
let fcmOAuthUrl = 'https://oauth2.googleapis.com/token';
let fcmSendUrlPrefix = 'https://fcm.googleapis.com/v1/projects';

async function getFcmAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (fcmToken && now < fcmTokenExpiry - 300) return fcmToken;

  const sa = fcmSA!;
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: fcmOAuthUrl,
    iat: now,
    exp: now + 3600,
  })).toString('base64url');

  const input = `${header}.${claims}`;
  const signer = createSign('RSA-SHA256');
  signer.update(input);
  const sig = signer.sign(sa.private_key, 'base64url');

  const res = await fetch(fcmOAuthUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${input}.${sig}`,
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`FCM OAuth2 error: ${res.status}`);

  const data = await res.json() as { access_token: string; expires_in?: number };
  fcmToken = data.access_token;
  fcmTokenExpiry = now + (data.expires_in ?? 3600);
  return fcmToken;
}

export async function sendFcmPush(token: string, dataPayload: Record<string, string>): Promise<PushResult> {
  const accessToken = await getFcmAccessToken();
  const res = await fetch(
    `${fcmSendUrlPrefix}/${fcmSA!.project_id}/messages:send`,
    {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: { token, android: { priority: 'high' }, data: dataPayload } }),
      signal: AbortSignal.timeout(10_000),
    },
  );
  return { ok: res.ok, status: res.status, data: res.ok ? '' : await res.text() };
}

// ---------- Cleanup ----------

export function closePush(): void {
  for (const env of Object.keys(apnsClients)) {
    try { apnsClients[env]?.close(); } catch {}
    apnsClients[env] = null;
  }
}

// ---------- Test helpers (used only by test suite) ----------

export const _test = {
  overrideApnsHosts(hosts: Record<string, string>) {
    Object.assign(APNS_HOSTS, hosts);
  },
  resetApnsState() {
    apnsJwt = '';
    apnsJwtIssuedAt = 0;
    closePush();
  },
  resetFcmState() {
    fcmToken = '';
    fcmTokenExpiry = 0;
  },
  initApns(key: KeyObject, keyId: string, teamId: string, bundleId: string) {
    apnsKey = key;
    apnsKeyId = keyId;
    apnsTeamId = teamId;
    apnsBundleId = bundleId;
  },
  initFcm(sa: typeof fcmSA) {
    fcmSA = sa;
  },
  getApnsJwtIssuedAt() { return apnsJwtIssuedAt; },
  getFcmTokenExpiry() { return fcmTokenExpiry; },
  forceExpireApnsJwt() { apnsJwtIssuedAt = 0; },
  forceExpireFcmToken() { fcmTokenExpiry = 0; },
  setFcmUrls(oauthUrl: string, sendPrefix: string) {
    fcmOAuthUrl = oauthUrl;
    fcmSendUrlPrefix = sendPrefix;
  },
  resetFcmUrls() {
    fcmOAuthUrl = 'https://oauth2.googleapis.com/token';
    fcmSendUrlPrefix = 'https://fcm.googleapis.com/v1/projects';
  },
};
