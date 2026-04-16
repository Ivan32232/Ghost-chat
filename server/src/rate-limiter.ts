import { RateLimiterMemory } from 'rate-limiter-flexible';

// Layer 1: Per-IP connection rate — 5 new connections per minute
const connLimiter = new RateLimiterMemory({ points: 5, duration: 60 });

// Layer 2: Per-connection message rate — 40 messages per 60 seconds
const msgLimiter = new RateLimiterMemory({ points: 40, duration: 60 });

// Layer 3: Per-IP simultaneous connections — max 3
const activeConns = new Map<string, number>();

// Push endpoint rate limit — 20 requests per minute per IP
const pushLimiter = new RateLimiterMemory({ points: 20, duration: 60 });

export async function checkConnectionRate(ip: string): Promise<boolean> {
  try {
    await connLimiter.consume(ip);
    return true;
  } catch {
    return false;
  }
}

export async function checkMessageRate(connId: string): Promise<boolean> {
  try {
    await msgLimiter.consume(connId);
    return true;
  } catch {
    return false;
  }
}

export function addConnection(ip: string): boolean {
  const count = activeConns.get(ip) ?? 0;
  if (count >= 3) return false;
  activeConns.set(ip, count + 1);
  return true;
}

export function removeConnection(ip: string): void {
  const count = activeConns.get(ip) ?? 1;
  if (count <= 1) activeConns.delete(ip);
  else activeConns.set(ip, count - 1);
}

export async function checkPushRate(ip: string): Promise<boolean> {
  try {
    await pushLimiter.consume(ip);
    return true;
  } catch {
    return false;
  }
}
