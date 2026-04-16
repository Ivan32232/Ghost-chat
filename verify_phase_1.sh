#!/bin/bash
# Ghost Chat v2 — Phase 1 Verification
# Exit 0 = ALL checks pass. Exit 1 = something failed.
set -uo pipefail

cd "$(dirname "$0")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
PASS=0
FAIL=0
SKIP=0

# ws module lives in server/node_modules — make it available to inline scripts
export NODE_PATH="$(pwd)/server/node_modules"

pass() { echo -e "  ${GREEN}PASS${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $1"; ((SKIP++)); }

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

# Restart server to clear in-memory rate limits between test groups
# No TURN_SECRET needed — dev mode auto-generates one
restart_server() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  TURN_DOMAIN=test.local PORT=3199 \
    node server/dist/src/index.js &>/dev/null &
  SERVER_PID=$!
  sleep 2
}

# ========================================
echo "=== 1. TypeScript Compilation ==="
# ========================================

if (cd server && npx tsc --noEmit 2>&1); then
  pass "TypeScript compiles without errors"
else
  fail "TypeScript compilation errors"
fi

# Check dist/ exists
if [ -d "server/dist/src/index.js" ] || [ -f "server/dist/src/index.js" ]; then
  pass "dist/index.js exists"
else
  # Build it
  (cd server && npx tsc 2>&1)
  if [ -f "server/dist/src/index.js" ]; then
    pass "dist/index.js built successfully"
  else
    fail "dist/index.js not found after build"
  fi
fi

# ========================================
echo "=== 2. Module Structure ==="
# ========================================

for f in index.ts signaling.ts turn.ts push.ts rate-limiter.ts; do
  if [ -f "server/src/$f" ]; then
    pass "server/src/$f exists"
  else
    fail "server/src/$f missing"
  fi
done

# File size check — each under 400 lines
for f in server/src/*.ts; do
  LINES=$(wc -l < "$f")
  NAME=$(basename "$f")
  if [ "$LINES" -le 400 ]; then
    pass "$NAME is $LINES lines (limit 400)"
  else
    fail "$NAME is $LINES lines — OVER 400 line limit"
  fi
done

# ========================================
echo "=== 3. Server Start ==="
# ========================================

# No TURN_SECRET — dev mode uses built-in dev secret
TURN_DOMAIN=test.local PORT=3199 \
  node server/dist/src/index.js &
SERVER_PID=$!
sleep 2

# Verify process is alive
if kill -0 "$SERVER_PID" 2>/dev/null; then
  pass "Server started on :3199"
else
  fail "Server failed to start"
  exit 1
fi

BASE="http://localhost:3199"

# ========================================
echo "=== 4. Health Endpoint ==="
# ========================================

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/health")
if [ "$STATUS" = "200" ]; then
  pass "GET /health returns 200"
else
  fail "GET /health returns $STATUS"
fi

BODY=$(curl -s "$BASE/health")
if echo "$BODY" | grep -q '"status":"ok"'; then
  pass "Health body has status:ok"
else
  fail "Health body: $BODY"
fi

# ========================================
echo "=== 5. TURN Credentials ==="
# ========================================

TURN=$(curl -s "$BASE/api/turn-credentials")

if echo "$TURN" | grep -q '"credential"'; then
  pass "TURN response has credential"
else
  fail "TURN missing credential: $TURN"
fi

if echo "$TURN" | grep -q '"pushAuth"'; then
  pass "TURN response has pushAuth"
else
  fail "TURN missing pushAuth"
fi

if echo "$TURN" | grep -q 'turn:test.local:3478'; then
  pass "TURN URLs have correct domain"
else
  fail "TURN domain mismatch"
fi

if echo "$TURN" | grep -q '"ttl":3600'; then
  pass "TURN TTL is 3600"
else
  fail "TURN TTL incorrect"
fi

# Verify HMAC-SHA1 credential format (base64)
CRED=$(echo "$TURN" | python3 -c "import sys,json; print(json.load(sys.stdin)['credential'])" 2>/dev/null)
if echo "$CRED" | base64 -d >/dev/null 2>&1; then
  pass "TURN credential is valid base64"
else
  fail "TURN credential not valid base64"
fi

# ========================================
echo "=== 6. WebSocket Signaling ==="
# ========================================

WS_RESULT=$(node -e "
const WebSocket = require('ws');
const results = [];
const ws1 = new WebSocket('ws://localhost:3199/ws');
ws1.on('open', () => ws1.send(JSON.stringify({ type: 'create-room' })));
ws1.on('message', (d) => {
  const m = JSON.parse(d);
  if (m.type === 'room-created') {
    results.push('room-created');
    if (m.roomId && m.roomId.length >= 60) results.push('roomId-valid-length');
    const ws2 = new WebSocket('ws://localhost:3199/ws');
    ws2.on('open', () => ws2.send(JSON.stringify({ type: 'join-room', roomId: m.roomId })));
    ws2.on('message', (d2) => {
      results.push(JSON.parse(d2).type);
      ws1.close(); ws2.close();
    });
  }
  if (m.type === 'peer-joined') results.push('host-peer-joined');
});
setTimeout(() => { console.log(results.join(',')); process.exit(0); }, 3000);
" 2>/dev/null)

if echo "$WS_RESULT" | grep -q "room-created"; then pass "WS: room created"; else fail "WS: create-room failed"; fi
if echo "$WS_RESULT" | grep -q "roomId-valid-length"; then pass "WS: roomId is 64+ chars (384-bit)"; else fail "WS: roomId too short"; fi
if echo "$WS_RESULT" | grep -q "room-joined"; then pass "WS: guest joined room"; else fail "WS: join-room failed"; fi
if echo "$WS_RESULT" | grep -q "host-peer-joined"; then pass "WS: host notified of peer"; else fail "WS: host not notified"; fi

# Test rejoin
WS_REJOIN=$(node -e "
const WebSocket = require('ws');
const ws1 = new WebSocket('ws://localhost:3199/ws');
ws1.on('open', () => ws1.send(JSON.stringify({ type: 'create-room' })));
ws1.on('message', (d) => {
  const m = JSON.parse(d);
  if (m.type === 'room-created') {
    ws1.close();
    const ws2 = new WebSocket('ws://localhost:3199/ws');
    ws2.on('open', () => ws2.send(JSON.stringify({ type: 'rejoin-room', roomId: m.roomId, role: 'host' })));
    ws2.on('message', (d2) => { console.log(JSON.parse(d2).type); ws2.close(); });
  }
});
setTimeout(() => process.exit(0), 3000);
" 2>/dev/null)

if echo "$WS_REJOIN" | grep -q "rejoin-ok"; then pass "WS: rejoin works"; else fail "WS: rejoin failed: $WS_REJOIN"; fi

# Restart server — basic WS tests consumed connection rate limit
restart_server

# Test signal relay
WS_SIGNAL=$(node -e "
const WebSocket = require('ws');
const ws1 = new WebSocket('ws://localhost:3199/ws');
ws1.on('open', () => ws1.send(JSON.stringify({ type: 'create-room' })));
ws1.on('message', (d) => {
  const m = JSON.parse(d);
  if (m.type === 'room-created') {
    const ws2 = new WebSocket('ws://localhost:3199/ws');
    ws2.on('open', () => ws2.send(JSON.stringify({ type: 'join-room', roomId: m.roomId })));
    ws2.on('message', (d2) => {
      const m2 = JSON.parse(d2);
      if (m2.type === 'room-joined') {
        ws2.send(JSON.stringify({ type: 'signal', data: { type: 'offer', sdp: 'test-sdp' } }));
      }
      if (m2.type === 'signal') { console.log('signal-relayed:' + m2.data.type); ws1.close(); ws2.close(); }
    });
  }
  if (m.type === 'signal') { console.log('host-got-signal:' + m.data.type); }
});
setTimeout(() => process.exit(0), 3000);
" 2>/dev/null)

if echo "$WS_SIGNAL" | grep -q "signal"; then pass "WS: signal relay works"; else fail "WS: signal not relayed"; fi

# Test invalid signal type rejected
WS_BAD_SIGNAL=$(node -e "
const WebSocket = require('ws');
const ws1 = new WebSocket('ws://localhost:3199/ws');
ws1.on('open', () => ws1.send(JSON.stringify({ type: 'create-room' })));
ws1.on('message', (d) => {
  const m = JSON.parse(d);
  if (m.type === 'room-created') {
    const ws2 = new WebSocket('ws://localhost:3199/ws');
    ws2.on('open', () => ws2.send(JSON.stringify({ type: 'join-room', roomId: m.roomId })));
    ws2.on('message', (d2) => {
      const m2 = JSON.parse(d2);
      if (m2.type === 'room-joined') {
        ws2.send(JSON.stringify({ type: 'signal', data: { type: 'evil-type', payload: 'hack' } }));
        setTimeout(() => { console.log('no-relay'); ws1.close(); ws2.close(); }, 1000);
      }
    });
  }
  if (m.type === 'signal') { console.log('RELAYED-BAD'); }
});
setTimeout(() => process.exit(0), 3000);
" 2>/dev/null)

if echo "$WS_BAD_SIGNAL" | grep -q "RELAYED-BAD"; then fail "WS: bad signal type was relayed!"; else pass "WS: invalid signal types rejected"; fi

# ========================================
echo "=== 7. Push Endpoints (before rate limiter exhausts quota) ==="
# ========================================

# Push endpoints return 503 when not configured (no APNs/FCM keys)
S503=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":{"roomId":"test"}}' \
  "$BASE/api/send-push")
if [ "$S503" = "503" ]; then pass "APNs returns 503 when not configured"; else fail "APNs unconfigured: $S503"; fi

S503_FCM=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":{"roomId":"test"}}' \
  "$BASE/api/send-push-android")
if [ "$S503_FCM" = "503" ]; then pass "FCM returns 503 when not configured"; else fail "FCM unconfigured: $S503_FCM"; fi

# ========================================
echo "=== 8. Rate Limiter ==="
# ========================================

BLOCKED=0
for i in $(seq 1 25); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" -d '{"token":"bad"}' \
    "$BASE/api/send-push")
  if [ "$STATUS" = "429" ]; then BLOCKED=1; break; fi
done

if [ "$BLOCKED" = "1" ]; then
  pass "Push rate limiter blocks after threshold"
else
  fail "Push rate limiter did not trigger after 25 requests"
fi

# ========================================
echo "=== 9. WS Connection Limit ==="
# ========================================

WS_LIMIT=$(node -e "
const WebSocket = require('ws');
let rejected = 0;
const socks = [];
for (let i = 0; i < 6; i++) {
  const ws = new WebSocket('ws://localhost:3199/ws');
  socks.push(ws);
  ws.on('close', (code) => { if (code === 1008) rejected++; });
}
setTimeout(() => { console.log(rejected); socks.forEach(s => { try { s.close(); } catch {} }); process.exit(0); }, 2500);
" 2>/dev/null)

if [ "${WS_LIMIT:-0}" -ge 1 ] 2>/dev/null; then
  pass "WS connection limit enforced ($WS_LIMIT rejected)"
else
  fail "WS connection limit not working (rejected: ${WS_LIMIT:-0})"
fi

# ========================================
echo "=== 10. Pending Room API ==="
# ========================================

# Fresh server for pending room tests
restart_server

ROOM_ID=$(node -e "
const WebSocket = require('ws');
const ws = new WebSocket('ws://localhost:3199/ws');
ws.on('open', () => ws.send(JSON.stringify({ type: 'create-room' })));
ws.on('message', (d) => { const m = JSON.parse(d); if (m.roomId) { console.log(m.roomId); ws.close(); } });
setTimeout(() => process.exit(0), 2000);
" 2>/dev/null)

PEER_HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CREATOR_HASH="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

if [ -n "$ROOM_ID" ]; then
  # POST
  PR_POST=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"peerHash\":\"$PEER_HASH\",\"roomId\":\"$ROOM_ID\",\"creatorHash\":\"$CREATOR_HASH\"}" \
    "$BASE/api/pending-room")
  if [ "$PR_POST" = "200" ]; then pass "Pending room: POST ok"; else fail "Pending room: POST $PR_POST"; fi

  # GET
  PR_GET=$(curl -s "$BASE/api/pending-room?myHash=$PEER_HASH")
  if echo "$PR_GET" | grep -q "$ROOM_ID"; then pass "Pending room: GET returns roomId"; else fail "Pending room: GET $PR_GET"; fi

  # GET again (should be consumed)
  PR_GONE=$(curl -s "$BASE/api/pending-room?myHash=$PEER_HASH")
  if echo "$PR_GONE" | grep -q '"roomId":null'; then pass "Pending room: consumed after GET"; else fail "Pending room: not consumed: $PR_GONE"; fi

  # DELETE
  PR_DEL=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/pending-room?myHash=$PEER_HASH")
  if [ "$PR_DEL" = "200" ]; then pass "Pending room: DELETE ok"; else fail "Pending room: DELETE $PR_DEL"; fi
else
  fail "Could not create room for pending room test"
fi

# Validation: bad hashes
PR_BAD=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"peerHash":"short","roomId":"x","creatorHash":"y"}' \
  "$BASE/api/pending-room")
if [ "$PR_BAD" = "400" ]; then pass "Pending room: rejects invalid params"; else fail "Pending room: accepted bad params ($PR_BAD)"; fi

# ========================================
echo "=== 11. Security Headers ==="
# ========================================

HEADERS=$(curl -sI "$BASE/health")
for H in "x-content-type-options" "x-frame-options" "strict-transport-security" "content-security-policy"; do
  if echo "$HEADERS" | grep -qi "$H"; then
    pass "Header: $H present"
  else
    fail "Header: $H MISSING"
  fi
done

# ========================================
echo "=== 12. Edge Cases ==="
# ========================================

# Fresh server for clean state
restart_server

# 404 for unknown paths
S404=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/nonexistent")
if [ "$S404" = "404" ]; then pass "404 for unknown path"; else fail "Unknown path: $S404"; fi

# Leave room
WS_LEAVE=$(node -e "
const WebSocket = require('ws');
const ws = new WebSocket('ws://localhost:3199/ws');
ws.on('open', () => ws.send(JSON.stringify({ type: 'create-room' })));
ws.on('message', (d) => {
  const m = JSON.parse(d);
  if (m.type === 'room-created') {
    ws.send(JSON.stringify({ type: 'leave-room' }));
    setTimeout(() => { console.log('leave-ok'); ws.close(); }, 500);
  }
});
setTimeout(() => process.exit(0), 2000);
" 2>/dev/null)
if echo "$WS_LEAVE" | grep -q "leave-ok"; then pass "WS: leave-room works"; else fail "WS: leave-room failed"; fi

# ========================================
echo "=== 13. Docker E2E ==="
# ========================================

# Kill local server before Docker test (port conflict)
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
  fail "Docker not available — install Docker Desktop and start daemon"
else
  # Build
  if docker compose -f deploy/docker-compose.yml build ghost-chat 2>&1 | tail -3; then
    pass "Docker build succeeds"
  else
    fail "Docker build failed"
  fi

  # Run in dev mode (no secrets needed)
  docker compose -f deploy/docker-compose.yml up -d ghost-chat 2>/dev/null
  sleep 5

  # Health check inside container
  DOCKER_HEALTH=$(docker exec ghost-chat node -e "
    require('http').get('http://localhost:3000/health', r => {
      let d=''; r.on('data',c=>d+=c);
      r.on('end',()=>{console.log(r.statusCode+':'+d);process.exit(r.statusCode===200?0:1)});
    }).on('error', e => { console.error(e.message); process.exit(1); });
  " 2>&1)

  if echo "$DOCKER_HEALTH" | grep -q "200:"; then
    pass "Docker container health check returns 200"
  else
    fail "Docker container health check failed: $DOCKER_HEALTH"
  fi

  # Health check from host
  HOST_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health 2>/dev/null)
  if [ "$HOST_HEALTH" = "200" ]; then
    pass "Docker host port health check returns 200"
  else
    fail "Docker host port health check: $HOST_HEALTH"
  fi

  # Cleanup
  docker compose -f deploy/docker-compose.yml down 2>/dev/null
fi

# ========================================
# Summary
# ========================================

echo ""
echo "========================================"
echo -e "  ${GREEN}PASSED: $PASS${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}FAILED: $FAIL${NC}"
fi
if [ "$SKIP" -gt 0 ]; then
  echo -e "  ${YELLOW}SKIPPED: $SKIP${NC}"
fi
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}Phase 1 verification FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}Phase 1 verification PASSED${NC}"
exit 0
