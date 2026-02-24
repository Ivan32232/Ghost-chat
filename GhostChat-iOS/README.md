# Ghost Chat — iOS

Нативное iOS-приложение для Ghost Chat. Полная совместимость с веб-клиентом.

## Требования

- Xcode 15+
- iOS 16.0+
- CocoaPods
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (опционально)

## Быстрый старт

### Вариант 1: XcodeGen (рекомендуется)

```bash
cd GhostChat-iOS
brew install xcodegen
xcodegen generate
pod install
open GhostChat.xcworkspace
```

### Вариант 2: Xcode вручную

1. Открыть Xcode → File → New → Project → iOS App → SwiftUI
2. Product Name: `GhostChat`, Bundle ID: `xyz.gbskgs.ghostchat`
3. Скопировать содержимое папок `GhostChat/` и `GhostChatTests/` в проект
4. `pod install` → открыть `.xcworkspace`
5. Настроить Signing & Capabilities:
   - Background Modes: Audio, VoIP
   - Push Notifications

### Настройка подписи

1. Xcode → GhostChat target → Signing & Capabilities
2. Выбрать Team (Apple Developer Account)
3. Automatic Signing → On
4. Добавить capabilities:
   - Background Modes → Audio, Voice over IP
   - Push Notifications

## Архитектура

```
GhostChat/
├── App/                    # Entry point, AppDelegate (CallKit, PushKit)
├── Core/
│   ├── Crypto/             # E2E шифрование (CryptoKit)
│   ├── WebRTC/             # P2P соединение + голосовые звонки
│   ├── Network/            # WebSocket signaling + TURN API
│   └── Security/           # Мониторинг безопасности
├── Features/
│   ├── Welcome/            # Экран создания/входа в комнату
│   ├── Chat/               # Чат + ViewModel (orchestrator)
│   └── Call/               # UI звонков
├── Models/                 # Данные (Message, Room, ControlMessage)
└── Resources/              # Assets, Info.plist, Entitlements
```

## Совместимость с сервером

Подключается к тому же серверу (`server/index.js`):
- WebSocket: `wss://gbskgs.xyz/ws`
- TURN API: `GET /api/turn-credentials`
- Шифрование: ECDH P-256 → HKDF → AES-256-GCM (идентично веб-клиенту)

## Тесты

```bash
# Через Xcode: Cmd+U
# Или через CLI:
xcodebuild test -workspace GhostChat.xcworkspace -scheme GhostChat -destination 'platform=iOS Simulator,name=iPhone 15'
```
