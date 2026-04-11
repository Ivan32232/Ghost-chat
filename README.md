# Ghost Chat

> Zero-trace P2P encrypted messenger with voice calls. Messages exist only in memory — nothing is stored on any server.

<p align="center">
  <img src="client/icons/icon-192.png" alt="Ghost Chat" width="96">
</p>

<p align="center">
  <strong>🌐 Web:</strong> <a href="https://ghostchat.one/">ghostchat.one</a> ·
  <strong>📱 iOS:</strong> TestFlight ·
  <strong>🤖 Android:</strong> APK
</p>

---

## What it is

Ghost Chat is a P2P encrypted messenger where **the server never sees your messages**. The signaling server only helps two devices find each other — once the direct connection is established, every message, call, and file flows through an end-to-end encrypted WebRTC DataChannel. The server is stateless, has no database, and cannot read your conversations.

Available as a web app (works in any modern browser), a native iOS app, and a native Android app — all three platforms speak the same protocol and can chat with each other.

## Features

### Encryption
- **ECDH P-256** initial key exchange
- **Double Ratchet** protocol (Signal-style per-message forward secrecy)
- **AES-256-GCM** authenticated encryption
- **Post-Quantum hybrid** via ML-KEM768 on iOS 26+ and Android (BouncyCastle)
- **Replay protection** with nonce tracking and counter windows
- **Traffic analysis resistance** via 256-byte message padding
- **Voice encryption** via DTLS-SRTP (built into WebRTC)

### Messaging
- Text with Telegram-style reply, edit, and delete-for-everyone
- Typing indicators and read receipts
- Auto-delete messages with configurable TTL (off by default for privacy)
- File transfer up to 100 MB with backpressure-aware chunking
- Image previews inline
- Saved Messages (local self-chat like Telegram favorites)

### Voice calls
- P2P audio over the existing encrypted DataChannel
- **System-level call UI** — CallKit on iOS, ConnectionService on Android
- Offline call via VoIP push (APNs / FCM) — peer's phone wakes, shows native call screen
- Telegram-style audio route picker (earpiece / speaker / Bluetooth / wired headset)
- Mid-call Bluetooth hot-plug detection with auto-route

### Privacy and security
- **Biometric lock + PIN** with panic wipe after 10 wrong attempts
- **Screenshot detection** with peer notification
- **Privacy mode** — TURN-relay-only ICE policy hides your real IP
- **Safety number** verification (SHA-256 fingerprint) between peers
- **Auto-lock** with configurable timeout
- **One-time invite links** — each room link works exactly once
- SQLCipher-encrypted local storage for contacts and message history (opt-in)

### Internationalization
- 14 languages: English, Russian, Ukrainian, German, French, Spanish, Italian, Portuguese (BR), Japanese, Korean, Simplified Chinese, Hindi, Turkish, Arabic

## How it works

```
Host creates room → Server generates one-time ID
                   ↓
Guest joins via invite link → WebRTC handshake via signaling server
                            ↓
P2P DataChannel opens → Server is no longer needed
                      ↓
ECDH + ML-KEM768 hybrid key exchange → Double Ratchet → AES-256-GCM
```

After the P2P channel is established, all communication — messages, voice calls, control signals — flows directly between peers. The server only relays WebRTC handshake data during connection setup.

## Architecture

```
server/index.js                         Stateless signaling + push proxy
client/                                 Vanilla-JS web client (no framework)
  js/app.js                             GhostChat orchestrator
  js/crypto.js                          Web Crypto API encryption
  js/webrtc.js                          P2P connectivity
  js/voice.js                           Voice calls
GhostChat-iOS/GhostChat/                Native iOS (SwiftUI + WebRTC + CryptoKit)
GhostChat-Android/app/src/main/java/    Native Android (Kotlin + Jetpack Compose)
deploy/                                 Docker Compose (Node + Nginx + coturn + Certbot)
```

All three clients (web / iOS / Android) speak the same wire protocol and can interoperate.

## Quick start (web / server)

```bash
npm install
npm run dev          # starts on :3000
```

No build step required — vanilla JS served as static files.

## iOS

```bash
cd GhostChat-iOS
xcodegen generate
open GhostChat.xcodeproj
```

iOS 16.0+, SwiftUI, SPM for dependencies (WebRTC, SQLCipher, Firebase).
Bundle ID: `com.ivanpokhvalitov.ghostchat`.

## Android

```bash
cd GhostChat-Android
./gradlew assembleDebug       # debug APK
./gradlew assembleRelease     # release build
```

minSdk 28, targetSdk 35, Kotlin 2.1, Jetpack Compose, Java 17.

## Tech stack

| Layer | Implementation |
|---|---|
| Server | Node.js + `ws` (single dependency) |
| Web client | Vanilla JavaScript, Web Crypto API, WebRTC |
| iOS | SwiftUI, WebRTC, CryptoKit (ML-KEM768), SQLCipher, CallKit |
| Android | Kotlin, Jetpack Compose, WebRTC, BouncyCastle, SQLCipher, ConnectionService |
| Transport | WebRTC DataChannel (messages), DTLS-SRTP (voice) |
| Push | APNs (iOS + VoIP), FCM v1 (Android) |
| Deploy | Docker Compose: Node + Nginx + coturn + Let's Encrypt |

## Security model

| Layer | Implementation |
|---|---|
| Key exchange | ECDH P-256 + ML-KEM768 (hybrid, optional) |
| Key derivation | HKDF-SHA256 over ECDH ‖ ML-KEM shared secret |
| Message encryption | Double Ratchet + AES-256-GCM, unique key per message |
| Forward secrecy | Per-message key ratchet |
| Replay protection | Counter window + nonce tracking |
| Voice | DTLS-SRTP |
| IP privacy | Optional TURN-relay-only ICE transport |
| TURN auth | HMAC-SHA1 temporary credentials (1h TTL) |
| Local storage | SQLCipher (AES-256) with biometric-derived key |

## Deployment

See [deploy/DEPLOY.md](deploy/DEPLOY.md) for production deployment instructions with Docker Compose, Nginx, coturn TURN server, and Let's Encrypt SSL.

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `PORT` | Server port | `3000` |
| `NODE_ENV` | `production` suppresses logs, requires `TURN_SECRET` | — |
| `TRUST_PROXY` | Set `1` behind reverse proxy | — |
| `TURN_SECRET` | Shared secret for coturn HMAC-SHA1 auth | **required in prod** |
| `TURN_DOMAIN` | TURN server hostname | `localhost` |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_PATH`, `APNS_BUNDLE_ID` | Apple Push (optional) | — |
| `FCM_SA_PATH` | Firebase service-account JSON path (optional) | — |

## License

MIT
