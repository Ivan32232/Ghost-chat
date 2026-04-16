import { createHmac, randomBytes } from 'node:crypto';

const IS_PRODUCTION = process.env.NODE_ENV === 'production';
const DEV_SECRET = 'ghost-dev-secret-NOT-FOR-PRODUCTION';

// In dev mode: use a hardcoded secret so the server starts without .env
// In production: TURN_SECRET env var is REQUIRED — server exits without it
const TURN_SECRET = process.env.TURN_SECRET || (IS_PRODUCTION ? '' : DEV_SECRET);
const TURN_DOMAIN = process.env.TURN_DOMAIN ?? 'localhost';
const TURN_TTL = 3600;

export interface TurnCredentials {
  username: string;
  credential: string;
  ttl: number;
  urls: string[];
  pushAuth?: string;
}

export function isTurnConfigured(): boolean {
  return TURN_SECRET.length > 0;
}

export function requireTurnInProduction(): void {
  if (IS_PRODUCTION && !process.env.TURN_SECRET) {
    console.error('FATAL: TURN_SECRET is required in production');
    process.exit(1);
  }
  if (!IS_PRODUCTION && !process.env.TURN_SECRET) {
    console.warn('[WARN] TURN_SECRET not set — using dev default. DO NOT use in production!');
  }
}

export function generateCredentials(clientIp?: string): TurnCredentials | null {
  if (!TURN_SECRET) return null;

  const expiry = Math.floor(Date.now() / 1000) + TURN_TTL;
  const username = `${expiry}:ghost${randomBytes(16).toString('hex')}`;
  const credential = createHmac('sha1', TURN_SECRET)
    .update(username)
    .digest('base64');

  const result: TurnCredentials = {
    username,
    credential,
    ttl: TURN_TTL,
    urls: [
      `turn:${TURN_DOMAIN}:3478`,
      `turn:${TURN_DOMAIN}:5349?transport=tcp`,
      `turns:${TURN_DOMAIN}:5349`,
    ],
  };

  // Push auth token — clients use it to authenticate push requests
  // HMAC(TURN_SECRET, "push:" + clientIP + ":" + 5minWindow)
  if (clientIp) {
    const window = Math.floor(Date.now() / 300_000);
    result.pushAuth = createHmac('sha256', TURN_SECRET)
      .update(`push:${clientIp}:${window}`)
      .digest('hex');
  }

  return result;
}

/**
 * Two auth methods — both check current + previous 5-min window:
 * 1. Token+identifier: HMAC(secret, token + identifier + window)
 * 2. IP-based: HMAC(secret, "push:" + ip + ":" + window)
 */
export function verifyPushAuth(
  token: string,
  identifier: string,
  auth: string,
  clientIp?: string,
): boolean {
  if (!TURN_SECRET || !auth || typeof auth !== 'string') return false;
  const window = Math.floor(Date.now() / 300_000);

  for (const w of [window, window - 1]) {
    const expected = createHmac('sha256', TURN_SECRET)
      .update(token + identifier + w)
      .digest('hex');
    if (auth === expected) return true;
  }

  if (clientIp) {
    for (const w of [window, window - 1]) {
      const expected = createHmac('sha256', TURN_SECRET)
        .update(`push:${clientIp}:${w}`)
        .digest('hex');
      if (auth === expected) return true;
    }
  }

  return false;
}
