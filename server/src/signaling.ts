import { WebSocketServer, WebSocket } from 'ws';
import type { Server as HttpServer, IncomingMessage } from 'node:http';
import { randomBytes } from 'node:crypto';
import {
  checkConnectionRate, checkMessageRate,
  addConnection, removeConnection,
} from './rate-limiter.js';

// --- Types ---

interface Room {
  peers: Set<WebSocket>;
  inviteUsed: boolean;
  createdAt: number;
  lastEmptyAt: number | null;
}

interface PendingRoom {
  roomId: string;
  creatorHash: string;
  createdAt: number;
}

// --- State ---

const rooms = new Map<string, Room>();
const pendingRooms = new Map<string, PendingRoom>();

// --- Constants ---

const ROOM_TTL = 10 * 60_000;       // 10 min empty room lifetime
const MAX_ROOMS = 10_000;
const PENDING_TTL = 5 * 60_000;     // 5 min pending room lifetime
const WS_TYPES = new Set(['create-room', 'join-room', 'rejoin-room', 'signal', 'leave-room']);
const SIGNAL_TYPES = new Set(['offer', 'answer', 'ice-candidate']);

// --- Helpers ---

function generateRoomId(): string {
  return randomBytes(48).toString('base64url');
}

function send(ws: WebSocket, data: object): void {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(data));
}

function broadcast(room: Room, exclude: WebSocket | null, data: object): void {
  const msg = JSON.stringify(data);
  for (const peer of room.peers) {
    if (peer !== exclude && peer.readyState === WebSocket.OPEN) peer.send(msg);
  }
}

function cleanDeadPeers(room: Room): void {
  const dead: WebSocket[] = [];
  for (const p of room.peers) if (p.readyState !== WebSocket.OPEN) dead.push(p);
  for (const p of dead) room.peers.delete(p);
}

/** Whitelist WebRTC signal fields — strip everything unexpected */
function sanitizeSignal(data: any): object | null {
  if (!data?.type || !SIGNAL_TYPES.has(data.type)) return null;
  const out: Record<string, unknown> = { type: data.type };

  if (data.type === 'offer' || data.type === 'answer') {
    if (typeof data.sdp === 'string') {
      out.sdp = data.sdp;
    } else if (data.sdp && typeof data.sdp.sdp === 'string') {
      // iOS/Android send sdp as { type, sdp } object
      out.sdp = { type: data.sdp.type, sdp: data.sdp.sdp };
    } else {
      return null;
    }
  } else {
    // ice-candidate — web sends string, mobile sends object
    if (typeof data.candidate === 'string') {
      out.candidate = data.candidate;
    } else if (data.candidate && typeof data.candidate.candidate === 'string') {
      const c: Record<string, unknown> = { candidate: data.candidate.candidate };
      if (typeof data.candidate.sdpMid === 'string') c.sdpMid = data.candidate.sdpMid;
      if (typeof data.candidate.sdpMLineIndex === 'number') c.sdpMLineIndex = data.candidate.sdpMLineIndex;
      out.candidate = c;
    }
    // Top-level sdpMid/sdpMLineIndex (web format)
    if (typeof data.sdpMid === 'string') out.sdpMid = data.sdpMid;
    if (typeof data.sdpMLineIndex === 'number') out.sdpMLineIndex = data.sdpMLineIndex;
  }

  return out;
}

export function getClientIp(req: IncomingMessage): string {
  if (process.env.TRUST_PROXY === '1') {
    const fwd = req.headers['x-forwarded-for'];
    if (typeof fwd === 'string') return fwd.split(',')[0].trim();
  }
  return req.socket.remoteAddress ?? 'unknown';
}

// --- WebSocket Server ---

export function setupSignaling(server: HttpServer): void {
  const wss = new WebSocketServer({
    server,
    maxPayload: 16 * 1024,
    path: '/ws',
  });

  wss.on('connection', async (ws: WebSocket, req: IncomingMessage) => {
    const ip = getClientIp(req);

    // Rate limit + simultaneous connection check
    if (!(await checkConnectionRate(ip)) || !addConnection(ip)) {
      ws.close(1008, 'Too many connections');
      return;
    }

    let currentRoom: string | null = null;
    let role: string | null = null;
    let disconnected = false;
    const connId = randomBytes(8).toString('hex');

    (ws as any).isAlive = true;
    ws.on('pong', () => { (ws as any).isAlive = true; });

    ws.on('message', async (raw: Buffer) => {
      try {
        const str = raw.toString();
        if (str.length > 16_384) return;
        if (!(await checkMessageRate(connId))) return;

        const msg = JSON.parse(str);
        if (!msg.type || !WS_TYPES.has(msg.type)) return;

        switch (msg.type) {
          case 'create-room': {
            if (rooms.size >= MAX_ROOMS) {
              send(ws, { type: 'error', message: 'Server overloaded' });
              return;
            }
            const id = generateRoomId();
            rooms.set(id, {
              peers: new Set([ws]),
              inviteUsed: false,
              createdAt: Date.now(),
              lastEmptyAt: null,
            });
            currentRoom = id;
            role = 'host';
            send(ws, { type: 'room-created', roomId: id });
            break;
          }

          case 'join-room': {
            const id = msg.roomId?.trim();
            if (!id) return;
            const room = rooms.get(id);
            if (!room) { send(ws, { type: 'error', message: 'Room not found' }); return; }

            // TOCTOU prevention — mark invite used BEFORE cleanup/add
            if (room.inviteUsed) {
              send(ws, { type: 'error', message: 'Invite already used' });
              return;
            }
            room.inviteUsed = true;

            cleanDeadPeers(room);
            if (room.peers.size >= 2) {
              room.inviteUsed = false; // rollback — room genuinely full
              send(ws, { type: 'error', message: 'Room is full' });
              return;
            }

            room.peers.add(ws);
            currentRoom = id;
            role = 'guest';
            send(ws, { type: 'room-joined', roomId: id });
            broadcast(room, ws, { type: 'peer-joined' });
            break;
          }

          case 'rejoin-room': {
            const id = msg.roomId?.trim();
            if (!id) return;
            const room = rooms.get(id);
            if (!room) { send(ws, { type: 'error', message: 'Room not found' }); return; }

            cleanDeadPeers(room);
            if (room.peers.size >= 2) {
              send(ws, { type: 'error', message: 'Room is full' });
              return;
            }

            room.peers.add(ws);
            currentRoom = id;
            role = (msg.role === 'host' || msg.role === 'guest') ? msg.role : 'guest';
            send(ws, { type: 'rejoin-ok', roomId: id });

            // Both peers present after rejoin — notify both to restart handshake
            if (room.peers.size === 2) {
              for (const p of room.peers) send(p, { type: 'peer-joined' });
            }
            break;
          }

          case 'signal': {
            if (!currentRoom) return;
            const sanitized = sanitizeSignal(msg.data);
            if (!sanitized) return;
            const room = rooms.get(currentRoom);
            if (!room) return;
            broadcast(room, ws, { type: 'signal', data: sanitized });
            break;
          }

          case 'leave-room': {
            if (!currentRoom) return;
            const room = rooms.get(currentRoom);
            if (room) {
              room.peers.delete(ws);
              broadcast(room, null, { type: 'peer-left' });
              if (room.peers.size === 0) room.lastEmptyAt = Date.now();
            }
            currentRoom = null;
            role = null;
            break;
          }
        }
      } catch {
        // JSON parse errors from garbage data — expected, ignore
      }
    });

    function handleDisconnect(): void {
      if (disconnected) return;
      disconnected = true;
      removeConnection(ip);

      if (currentRoom) {
        const room = rooms.get(currentRoom);
        if (room) {
          room.peers.delete(ws);
          broadcast(room, null, { type: 'peer-left' });
          if (room.peers.size === 0) room.lastEmptyAt = Date.now();
        }
        currentRoom = null;
      }
    }

    ws.on('close', handleDisconnect);
    ws.on('error', handleDisconnect);
  });

  // Ping/pong — detect dead connections (30s interval)
  setInterval(() => {
    for (const ws of wss.clients) {
      if (!(ws as any).isAlive) { ws.terminate(); continue; }
      (ws as any).isAlive = false;
      ws.ping();
    }
  }, 30_000);

  // Room cleanup (10s interval)
  setInterval(() => {
    const now = Date.now();
    for (const [id, room] of rooms) {
      cleanDeadPeers(room);
      if (room.peers.size === 0) {
        room.lastEmptyAt ??= now;
        if (now - room.lastEmptyAt > ROOM_TTL) rooms.delete(id);
      } else {
        room.lastEmptyAt = null;
      }
    }
    for (const [hash, pending] of pendingRooms) {
      if (now - pending.createdAt > PENDING_TTL) pendingRooms.delete(hash);
    }
  }, 10_000);
}

// --- Pending Room API (for saved contacts auto-connect) ---

export function setPendingRoom(peerHash: string, roomId: string, creatorHash: string): void {
  pendingRooms.set(peerHash, { roomId, creatorHash, createdAt: Date.now() });
}

export function getPendingRoom(myHash: string): { roomId: string; creatorHash: string } | null {
  const pending = pendingRooms.get(myHash);
  if (!pending) return null;
  if (Date.now() - pending.createdAt > PENDING_TTL) {
    pendingRooms.delete(myHash);
    return null;
  }
  // Room must still exist for pending to be valid
  if (!rooms.has(pending.roomId)) return null;
  pendingRooms.delete(myHash);
  return { roomId: pending.roomId, creatorHash: pending.creatorHash };
}

export function deletePendingRoom(hash: string): void {
  pendingRooms.delete(hash);
}
