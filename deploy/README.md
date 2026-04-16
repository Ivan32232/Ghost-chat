# Ghost Chat v2 — Deployment

## Local Development

No secrets, no SSL, no nginx — just the server:

```bash
cd deploy
docker compose up ghost-chat --build
```

Server runs on `http://localhost:3000`. TURN uses a dev secret (loud warning in logs).

### With local TURN server

```bash
cd deploy
docker compose --profile dev up --build
```

This starts ghost-chat + coturn (no TLS, port 3478).

### Run server outside Docker

```bash
cd server
npm install
npm run dev    # tsx with hot reload
```

## Production

```bash
cd deploy
cp .env.example .env
# Edit .env with real secrets

# Place keys:
mkdir -p keys
cp /path/to/AuthKey.p8 keys/AuthKey.p8
cp /path/to/firebase-sa.json keys/firebase-sa.json

# Ensure SSL certs exist:
# ssl/ghostchat.one/fullchain.pem
# ssl/ghostchat.one/privkey.pem

docker compose --profile prod up -d --build
```

### Production checklist

- [ ] `.env` has real `TURN_SECRET` (random 32+ chars)
- [ ] `.env` has `NODE_ENV=production`
- [ ] `.env` has `TRUST_PROXY=1`
- [ ] `.env` has `TURN_DOMAIN=ghostchat.one`
- [ ] `.env` has `APNS_KEY_ID`, `APNS_TEAM_ID`
- [ ] `keys/AuthKey.p8` exists (APNs)
- [ ] `keys/firebase-sa.json` exists (FCM)
- [ ] `ssl/ghostchat.one/` has fullchain.pem + privkey.pem
- [ ] `turnserver.conf` has matching `static-auth-secret`

## Profiles

| Command | Services |
|---|---|
| `docker compose up ghost-chat` | Server only |
| `docker compose --profile dev up` | Server + coturn (no TLS) |
| `docker compose --profile prod up` | Server + coturn + nginx + certbot |

## Health Check

```bash
curl http://localhost:3000/health
# {"status":"ok","uptime":42}
```
