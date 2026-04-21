https://ghostchat.one/

ssh -i ~/.ssh/digitalocean_key root@139.59.58.151

# Ghost Chat — Working Rules

## Before declaring any phase complete:

1. Run verify_phase_N.sh
2. If exit code != 0 — fix and re-run
3. Loop until exit code == 0
4. Then and only then say "Phase N complete"

## After every code change:

1. Run the relevant linter (TypeScript / SwiftLint / Android Lint)
2. If errors — fix immediately before continuing
3. Don't accumulate errors

## When you cannot verify automatically:

State explicitly: "MANUAL VERIFICATION REQUIRED: [specific test]"
Don't pretend you verified what you couldn't verify.

## Test-first for crypto:

For any cryptographic function:

1. Write the test first (with known test vectors)
2. Run test (should fail — function doesn't exist yet)
3. Implement the function
4. Run test (should pass)
5. If test fails — fix function, not test

## Never skip verification to "save time"

If verify_phase_N.sh takes 5 minutes — wait 5 minutes.
A passing test is the only proof code works.

---

## Lessons learned

### Phase 1 — Server
- Docker stack использует profiles: `dev` (только ghost-chat + ghost-turn) и `prod` (всё включая nginx + certbot). Локально использовать ТОЛЬКО dev.
- APNs/FCM реализованы raw (без apns2/firebase-admin) для минимизации зависимостей. Любые изменения push требуют запуска integration тестов.
- coturn использует host networking (NAT traversal требование). Не менять на bridge.
- NODE_ENV=development разрешает запуск без TURN_SECRET (с предупреждением в логах). Production требует все секреты обязательно.
- verify_phase_1.sh должен запускать реальный e2e тест Docker, не пропускать его.
- IPv4-first DNS (`dns.setDefaultResultOrder('ipv4first')`) — КРИТИЧНО для Docker. Без этого APNs/FCM молча отваливаются на AAAA DNS lookup.
- Rate limiter (5 WS connections/min per IP) ломает тесты если не перезапускать сервер между группами. verify_phase_1.sh делает restart_server между секциями.

---

## Checklist перед Phase 2

- [x] Docker компилируется и поднимается
- [x] Health endpoint отвечает 200
- [x] Dev профиль работает без production секретов
- [x] Все 45 автотестов проходят
- [x] Запушено в git
- [x] CLAUDE.md обновлён с lessons learned
- [x] Xcode 26.2 + Swift 6.2 (доступен)
- [x] OpenJDK 17 через brew (для Kotlin/JVM крипто-модуля; Android SDK для Phase 4)

---

### Phase 2 — Crypto layer (iOS + Android)

**Структура:**
- `docs/test-vectors.json` — детерминированные cross-platform тест-вектора (ECDH, HKDF, Chain KDF, AES-GCM, padding, wire format, safety number, full Double Ratchet session)
- `scripts/generate-test-vectors.cjs` — генератор через node:crypto
- `scripts/verify-cross-platform.cjs` — sanity check (sha256 совпадение + независимый re-compute через Node)
- `ios/` — Swift Package (`Package.swift`) с target `GhostCrypto`: CryptoKit + HKDF + Double Ratchet. Тесты через `swift test`.
- `android/` — Gradle Kotlin/JVM модуль `crypto` с BouncyCastle 1.78.1. Тесты через `./gradlew :crypto:test` (JUnit 5).
- `verify_phase_2.sh` — 5 шагов: regen vectors → sync → cross-platform → iOS → Android.

**Lessons learned (Phase 2):**
- `Data.withUnsafeBytes { Data($0) }` в Swift 6.2 даёт ambiguous initializer. Использовать `Data(bytes: ptr.baseAddress!, count: ptr.count)` или расширение `.rawData`.
- `$0.load(as: UInt32.self)` из `Data.withUnsafeBytes` крашится на `load from misaligned raw pointer`. Использовать `loadUnaligned(as:)`.
- В Kotlin: имя `KeyPairGenerator` конфликтует с `java.security.KeyPairGenerator`. Использовать fully-qualified путь.
- Node.js root `package.json` содержит `"type": "module"` — скрипты генератора должны быть `.cjs` для `require()`.
- BouncyCastle ECDH может вернуть 31 или 33 байта (leading zero) — надо padить/обрезать до 32.
- Gradle test task может быть UP-TO-DATE и не выводить PASSED строки → использовать `--rerun-tasks` в verify-скрипте.
- P-256 private key от BigInteger тоже может быть 31/33 байта — аналогичный padding.
- Root KDF формула: `HKDF(ikm=DH_output, salt=currentRootKey, info="ghost-dr-rk", len=64)` → split 64 байта на (newRK[0:32], CK[32:64]). Initial root key derivation: salt="ghost-dr-root" от shared secret.
- DH ratchet при приёме нового публичного ключа требует ДВУХ новых symmetric keys: receiving chain из DH с текущим DHs, и sending chain из DH с новым DHs. Оба root KDF обновляют RK последовательно.
- Test vectors для full session требуют pre-generated последовательности keypairs для ОБЕИХ сторон, т.к. каждый рэтчет на каждой стороне генерирует новый DHs.

**Phase 2 success criteria (все ✓):**
- [x] iOS: 21 тест XCTest проходит
- [x] Android: 21 тест JUnit проходит
- [x] iOS и Android используют одинаковый `test-vectors.json` (sha256 проверка)
- [x] ECDH P-256 → идентичный shared secret
- [x] HKDF-SHA256 → идентичный root key
- [x] Chain KDF (HMAC) → идентичные message keys
- [x] AES-256-GCM → идентичный ciphertext+tag при одинаковых key/nonce/AAD/plaintext
- [x] Double Ratchet: 5-message session, byte-identical wireBase64 на обеих платформах
- [x] Out-of-order decryption через skipped keys
- [x] Replay rejection (AES-GCM tag mismatch после удаления message key)
- [x] Message padding кратен 256 байтам, roundtrip работает
- [x] Safety number: SHA-256(sorted(keyA + keyB))[0:16] в формате "XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX"
- [x] Wire format: 4-byte headerLen + 73-byte header + 12-byte nonce + ciphertext + 16-byte tag
- [x] Header: version(1) + dhPubKeyRaw(64, без 0x04) + PN(4 BE) + N(4 BE) = 73 байта
- [x] `verify_phase_2.sh` exit code 0

---

## Deferred from Phase 2

- **ML-KEM768 post-quantum:** отложен до Phase 6 (Security Hardening). Требует iOS 26+ SDK (CryptoKit.MLKEM768) и BouncyCastle 1.82+. Архитектура готова (hybrid salt в HKDF, wire-поле `pqKey` в key-exchange), реализация pending.
- **IdentityKeyService:** stub создаётся в начале Phase 3, полная реализация (Keychain iOS / Android KeyStore + персистентный P-256 keypair) — когда дойдём до сохранённых контактов в Phase 3. Первые экраны (Welcome, Chat, one-time rooms) от identity key не зависят.
- **Persistence ratchet state в SQLCipher:** Phase 3 для saved contacts. DR-state будет `Codable` (Swift) / `Serializable` (Kotlin), сериализация через JSON или Protobuf.
- **Replay protection через nonce tracking + timestamp ±5min:** сейчас rejection только через AES-GCM tag (message key удаляется после первого использования). Дополнительная проверка в Phase 6 hardening.

---

## Checklist перед Phase 3

- [x] debugMessageKey убран из публичного API (iOS `#if DEBUG`, Android `internal` + `@VisibleForTesting`)
- [x] Тесты проходят после изменения (iOS 21/21, Android 21/21)
- [x] iOS release build (`swift build -c release`) компилируется без `debugMessageKey` в бинарнике
- [x] `verify_phase_2.sh` exit 0
- [x] CLAUDE.md обновлён с lessons learned и deferred items
- [ ] Запушено в git — `git commit -m "feat: Phase 2 complete — crypto layer, 42 tests pass"`
- [ ] Новая сессия Claude Code для Phase 3 (iOS app: XcodeGen + локальная зависимость на GhostCrypto SPM)

---

### Phase 2 — Crypto (быстрая справка)

- iOS крипто в `ios/Sources/GhostCrypto/` (CryptoKit), Android в `android/crypto/` (BouncyCastle 1.78.1). Байт-в-байт идентичны — проверено через shared `docs/test-vectors.json`.
- Test vectors в `docs/test-vectors.json` — любые изменения в крипто ОБЯЗАНЫ пройти все 21 тест на ОБЕИХ платформах, плюс `verify_phase_2.sh`.
- `Data($0)` из `withUnsafeBytes` в Swift 6.2 создаёт ambiguous initializer — использовать `Data(bytes: ptr.baseAddress!, count: ptr.count)` или helper `.rawData`.
- `Data.load(as: UInt32.self)` крашится на misaligned pointer — всегда `loadUnaligned(as:)`.
- Gradle кэширует тесты (`UP-TO-DATE`) — при изменении крипто делать `./gradlew :crypto:test --rerun-tasks` (или `clean test`), не просто `test`.
- Kotlin: имя `KeyPairGenerator` конфликтует с `java.security.KeyPairGenerator` — использовать fully-qualified путь.
- BouncyCastle ECDH/BigInteger может вернуть 31/33 байта (leading zero) — padить/обрезать до 32.
- `Double Ratchet state` должен стать `Codable`/`Serializable` для персистенции в SQLCipher (Phase 3).
- **ML-KEM768 отложен до Phase 6** — архитектура готова, реализация нет.
- `debugMessageKey` в `EncryptedMessage`: iOS — под `#if DEBUG` (полное исключение в release), Android — `internal` + `@VisibleForTesting` (доступно только внутри модуля crypto).

---

### Phase 3 — iOS App (summary)

- 40 Swift файлов, ChatViewModel ≤300 LOC, все файлы ≤400 LOC
- SQLCipher активирован через CocoaPods (`GRDB.swift/SQLCipher` 6.24.1 + `SQLCipher` 4.10.0) — SPM-версия GRDB не поддерживает SQLCipher, поэтому БД собирается через `ios/GhostChat.xcworkspace`. Шифрование на уровне страниц, `FileProtection.complete` не нужен и удалён
- SPKI pinning реализован без fallback, primary = live Let's Encrypt leaf, backup pin сгенерирован и зафиксирован (privкey в `deploy/keys/backup-pin-private.pem`, gitignored)
- `GhostChatCrypto` — `actor`, не `class`. Thread-safe по дизайну
- WebRTC / CallKit / Face ID проверены только compile — нужно ручное тестирование на реальном устройстве перед App Store
- Sentry SDK добавлен в зависимости, но не инициализирован (Phase 7)

---

### Phase 3 — iOS app (подробно)

**Структура:**
- `ios/project.yml` — XcodeGen source of truth. `xcodegen generate` перед каждым билдом. `Info.plist` и `.entitlements` генерируются оттуда и **gitignored**.
- SPM deps: `stasel/WebRTC`, `getsentry/sentry-cocoa`, локальный `GhostCrypto`.
- **CocoaPods deps** (gitignored `ios/Pods/`, committed `Podfile` + `Podfile.lock`): `GRDB.swift/SQLCipher ~> 6.24`, `SQLCipher ~> 4.6`. Сборка идёт через `ios/GhostChat.xcworkspace`, не `.xcodeproj`. После каждого `xcodegen generate` необходимо запускать `pod install` — XcodeGen перегенерирует xcodeproj и затирает Pods-интеграцию.
- iOS 16.0+, Swift 5.9, Bundle `com.kordar.ghostchat`, Team `G2VZKDYV38`.
- `CODE_SIGN_IDENTITY[sdk=iphonesimulator*]: "-"` (ad-hoc signing sim) — без этого сим-сборка не получает entitlements, и Keychain отваливается (`errSecMissingEntitlement -34018`).
- SPKI пины в `Core/Network/CertificatePinning.swift`: primary = live leaf (`u+rYBk…`), backup = наш keypair (`/AdS6h…`), приватный ключ в `deploy/keys/backup-pin-private.pem` (gitignored). ECDSA P-256 SPKI DER = фиксированный 26-байт header + 65-байт uncompressed point.
- Crypto wrapper `GhostChatCrypto` — `actor`, оборачивает `DoubleRatchet`. Добавлено в сам Phase 2 файл: `exportedState: Data` + `init(importing:)` для персистенции в saved-contacts.
- **SQLCipher page-level encryption активирована**: `DatabaseService.encrypted(at:keychain:)` открывает БД с `cipher_page_size=4096`, `kdf_iter=256000`, `cipher_memory_security=ON`, `secure_delete=ON`. Master key — 32 random bytes из Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), передаётся через `db.usePassphrase(Data)` → `sqlite3_key`. Тест `test_onDiskFile_isEncrypted_notPlaintext` пишет контакт с уникальным marker label, затем hexdump'ом файла доказывает что plaintext не появляется.

**Lessons learned (Phase 3):**
- Swift 5+ `try?` на throwing функции, возвращающей Optional, плющится (`try? foo() -> T?`, а не `T??`). Код типа `guard let x = try? foo(), let y = x, ...` — ошибка `initializer for conditional binding must have Optional type, not 'T'`. Разворачивать напрямую.
- GRDB по умолчанию хранит `Date` как TEXT с миллисекундной точностью. Тесты с `Date()` роундтрипом ломаются (под-мс пропадает). В тестах использовать `Date(timeIntervalSince1970: fixed)`.
- Sim Keychain на симуляторе требует entitlement → код-подпись. Если у таргета теста `CODE_SIGNING_ALLOWED: NO`, но у GhostChat.app подпись `-` (ad-hoc) есть — тесты, хостящиеся в app, наследуют entitlements. Если тесты подписать (signing включить без Info.plist), xcodebuild требует `GENERATE_INFOPLIST_FILE: YES`.
- `String(localized:locale:)` использует `locale` только для форматирования (числа, даты), **не** для выбора перевода. Чтобы принудительно взять RU перевод в EN-системе: `Bundle(path: ru.lproj).localizedString(forKey:…)`.
- Xcode 26/iOS 16 WebRTC: `allowBluetooth` deprecated → `allowBluetoothHFP`. `peerConnection.add(track, streamIds:)` возвращает `RTCRtpSender?`, а не non-optional.
- SwiftUI `.onChange(of:)` имеет два варианта: iOS 17+ `{ oldValue, newValue in }` и iOS 16 `{ newValue in }`. Для минимума iOS 16 — старый.
- `XCTAssertEqual(try await foo(), ...)` не компилируется: XCTAssert — autoclosure без concurrency. Вытаскивать в переменную: `let v = try await foo(); XCTAssertEqual(v, expected)`.
- `PKPushRegistry` / `UNUserNotificationCenter` недоступны на macOS — `#if os(iOS)` не нужен, LSP жалуется, но xcodebuild ок.
- DataChannel label validation: `RTCDataChannel.label` ≠ `"ghost-chat"` → закрывать. Иначе кто угодно может подключиться.
- iCE candidate filtering: `typ host` и `fe80:` (IPv6 link-local) — drop. Иначе утекает реальный IP.
- `DatabaseService.onDisk` → `DatabaseService.encrypted(at:keychain:)` → SQLCipher + GRDB/SQLCipher через CocoaPods. iOS `FileProtectionType.complete` удалён — SQLCipher шифрует страницы независимо от lock-состояния устройства и это строго сильнее. Exclude from iCloud backup остаётся.
- GRDB 7.x на CocoaPods отсутствует (только SPM) — закреплены `GRDB.swift/SQLCipher ~> 6.24` (6.24.1) и `SQLCipher ~> 4.6` (4.10.0). Если появится 7.x на trunk — bump одной строкой в Podfile.
- `db.usePassphrase(Data)` внутри `prepareDatabase` зовёт `sqlite3_key` с сырыми байтами. Cipher-параметры (`cipher_page_size`, `kdf_iter`) ВСЕГДА выставляются ПЕРЕД `usePassphrase` — иначе PRAGMA key для fresh DB закладывает дефолты, и reopen с другими параметрами сломается.
- Тест `test_onDiskFile_isEncrypted_notPlaintext`: после записи контакта делает `PRAGMA wal_checkpoint(TRUNCATE)`, закрывает очередь, читает все sibling-файлы (`.db`, `-wal`, `-shm`) и проверяет `Data.range(of:)` на marker и `SQLite format 3\0` magic. Без checkpoint'а данные могут остаться в WAL.
- Push auth: сервер возвращает `pushAuth` в ответе `/api/turn-credentials` (HMAC IP+5min window keyed on TURN_SECRET). Клиент просто echo это значение в `auth` поле POST-ов. Клиент никогда не видит TURN_SECRET.

**Что НЕ сделано (отложено по плану):**
- **ML-KEM768 post-quantum handshake** → Phase 6 (поля `pqKey`/`pqSupported` в `KeyExchangePacket` зарезервированы).
- **File transfer + voice messages over DataChannel** → Phase 5 (скаффолдинг `VoiceRecorder`, `ControlMessage.fileStart/chunk/complete/retransmit` готов).
- **Contact key rotation после каждой сессии** → Phase 6.
- **Jailbreak detection** → Phase 6.
- **Replay protection через nonce tracking + ±5 min timestamp** → Phase 6.
- **Sentry integration** — SDK в зависимостях, инициализация не сделана (нет DSN). Phase 7 polish.
- **Sounds (ringtone/message/sent/failed)** — SoundLibrary есть, но assets в `Resources/Sounds/` пустые. Phase 7.
- **Полноценный UI polish (кастомные иконки, анимации, haptics)** → Phase 7.

**Phase 3 success criteria (все ✓):**
- [x] `xcodegen generate` создаёт проект без ошибок
- [x] `xcodebuild … build` для iPhone 17 simulator: BUILD SUCCEEDED
- [x] `xcodebuild … test`: 163 unit tests pass
- [x] `swift test` (Phase 2 crypto): 21/21 all still passing после добавления `exportedState`/`init(importing:)`
- [x] Certificate pinning: primary + backup SPKI-SHA256 пины в `CertificatePinning.swift`, unit-тест хэширует backup keypair'ом raw key → совпадает с committed pin
- [x] No `UserDefaults` usage в проекте (проверяется `verify_phase_3.sh`)
- [x] Entitlements: `aps-environment`, `applinks:ghostchat.one`, keychain-access-groups
- [x] Info.plist: NSFaceIDUsageDescription, UIBackgroundModes [voip/audio/remote-notification]
- [x] `verify_phase_3.sh` exit code 0

**Phase 3 — manual verification required (cannot automate):**
- WebRTC P2P между двумя симуляторами / устройствами (нужен real E2E)
- Face ID / Touch ID (только реальное устройство)
- CallKit incoming UI (PushKit + реальный APNs)
- APNs / FCM end-to-end delivery
- Deep links из Safari (`ghostchat.one/?room=…`)

---

### Phase 4 — Android App
- Зеркало iOS 1:1. core/ + features/ + models/ идентичная структура
- ChatViewModel 81 LOC (лимит 300)
- SQLCipher реальный с первого дня (net.zetetic:sqlcipher-android)
- SPKI пины байт-в-байт идентичны iOS
- Hilt DI, OkHttp WebSocket, BouncyCastle 1.78.1
- ConnectionService skeleton — incoming call UI доделать в Phase 7
- FCM IncomingPushHandler — NoOp заглушка, bridge в Phase 7
- APK 137 МБ (WebRTC + SQLCipher native libs)
- Material3 deprecation warnings — HorizontalDivider, menuAnchor —
  исправить в Phase 7

**Phase 4 structure:**
- `android/app/` — новый `com.android.application` модуль (AGP 8.7.3, Kotlin 2.1, minSdk 28, targetSdk 35, compileSdk 35)
- `android/crypto/` — существующий Kotlin/JVM lib (из Phase 2), **НЕ переписывался**, только additive: `DoubleRatchet.exportedState` + `constructor(stateBytes)` для SQLCipher-персистенции. 21 оригинальный тест + 2 новых — все зелёные.
- `android/build.gradle.kts` — AGP 8.7.3 + Kotlin 2.1.0 + Hilt 2.54 + KSP 2.1.0-1.0.29
- `android/gradle.properties` — AndroidX on, nonTransitiveRClass on, parallel+caching
- `verify_phase_4.sh` — 16 автопроверок, exit 0 только когда всё зелёное

**Lessons learned (Phase 4):**
- **Hilt 2.52 не читает Kotlin 2.1 metadata** — "Unable to read Kotlin metadata due to unsupported metadata version". Решение: Hilt 2.54 + KSP (не kapt).
- **Hilt AGP + Kotlin 2.1 + `@LazyClassKey`** — 2.53.1 не генерирует `_LazyMapKey` aggregator-классы для `@HiltViewModel`. 2.54 фиксит.
- **BouncyCastle + jspecify packaging conflict** — META-INF/versions/9/OSGI-INF/MANIFEST.MF дубль. Добавить в `packaging.resources.excludes`.
- **net.zetetic:sqlcipher-android 4.6.1** — `SQLiteDatabaseHook.preKey/postKey` принимают `SQLiteConnection` (не `SQLiteDatabase`), используется `openOrCreateDatabase(File, ByteArray, CursorFactory, DatabaseErrorHandler, SQLiteDatabaseHook)` (5 параметров). `connection.executeRaw(sql, arrayOf(), null)` для PRAGMAs из хука.
- **SQLCipher JNI в Robolectric не загружается** — `.so` только для Android. Encryption proof test — androidTest (run на эмуляторе), не unit.
- **MainActivity должен быть FragmentActivity** (не ComponentActivity) — BiometricPrompt требует fragment lifecycle.
- **`androidx.core:core-telecom:1.0.0-alpha06` недоступен** в Google Maven. Использовать native `android.telecom` API напрямую.
- **SharedFlow без replay** — в тестах emit до подписки теряется. Для `first()` — сначала `launch` collector, потом emit, либо `UnconfinedTestDispatcher`.
- **`android.util.Base64` недоступен в JVM unit тестах** — использовать `java.util.Base64` (API 26+, наш minSdk 28 ок) для byte-identical iOS паритета.
- **Date storage** — GRDB (iOS) и SQLCipher (Android) оба хранят REAL как seconds-since-1970. Android добавил `Long.toSqlDouble()` / `Double.fromSqlDouble()` конверсии — миллисекунды ↔ double seconds.
- **FCM без google-services.json** — `FirebaseMessaging.getInstance().token` бросает. Обернуть в try/catch, push становится silent no-op. Документировать в commit что google-services.json gitignored.

**Phase 4 success criteria (все ✓):**
- [x] `./gradlew :crypto:test` → 23/23 (21 оригинал + 2 state-persistence)
- [x] `./gradlew :app:assembleDebug` → BUILD SUCCESSFUL, app-debug.apk ~137 MB
- [x] `./gradlew :app:testDebugUnitTest` → 92/92
- [x] `./gradlew :app:lintDebug` → BUILD SUCCESSFUL
- [x] FLAG_SECURE в MainActivity
- [x] Certificate pinning 2 пина, байт-в-байт iOS, без fallback
- [x] SQLCipher PRAGMAs cipher_page_size=4096 + kdf_iter=256000 + memory_security=ON + secure_delete=ON
- [x] SQLCipher native library load вызов есть
- [x] Нет SharedPreferences / PreferenceManager в app/src
- [x] Нет Log.* выводов messageKey / decrypted / plaintext
- [x] AndroidManifest: allowBackup=false, usesCleartextTraffic=false, POST_NOTIFICATIONS + MANAGE_OWN_CALLS, VIEW intents, applicationId com.kordar.ghostchat
- [x] EN + RU strings.xml ≥ 58 ключей каждый (у нас 59)
- [x] ChatViewModel ≤ 300 LOC (81)
- [x] Все .kt файлы ≤ 400 LOC
- [x] `verify_phase_4.sh` exit code 0

**Phase 4 — manual verification required (cannot automate):**
- WebRTC P2P между iOS и Android устройствами
- FCM push wakes app + launches incoming call UI
- ConnectionService incoming-call surface (real device)
- Cross-platform voice call iOS ↔ Android
- SQLCipher raw-file encryption proof через `./gradlew :app:connectedDebugAndroidTest` на эмуляторе
- Biometric unlock + decoy PIN + 10-fail panic wipe

---

## Deferred from Phase 4 (→ Phase 7 polish)
- UI polish (typography system, анимации, haptics, кастомные bubble shapes)
- ConnectionService incoming-call UI (реальный Android Telecom surface)
- FCM IncomingPushHandler → CallManager bridge (сейчас NoOp)
- Material3 deprecation fixes (Divider → HorizontalDivider, menuAnchor → MenuAnchorType overload)
- Full integration unit tests для ConnectionManager / ContactManager / CallManager (сейчас только manual verification через эмулятор)

---

### Phase 5 — File Transfer + Voice Messages (быстрая справка)
- FileTransferService — чистая state-машина, 100% покрыта тестами
- 2KB chunks, 16KB backpressure, SHA-256 integrity
- Voice messages: AAC m4a 44100Hz mono 64kbps, min 0.3s
- Full-screen image viewer с sampled decode (≤2048px)
- Cross-platform SHA-256 байт-в-байт идентичен
- Per-chunk 30s timeout НЕ реализован — отложен Phase 6
- Waveform заглушка — Phase 7
- Hard cap 100MB на файл (streaming не реализован)
- Весь файл грузится в память — для видео нужен streaming (Phase 7)

### Phase 5 — File Transfer + Voice Messages

**Структура:**
- `Core/Files/FileTransferService.{swift,kt}` — чистая state-машина: `prepareOutbound(data,name,mime)` → (fileStart, [fileChunk]…, fileComplete). `handleStart/handleChunk/handleComplete` с SHA-256 проверкой. `retransmitMessages(fileId, indices)` возвращает ранее построенные chunk-сообщения для file-retransmit. Chunk = 2048 байт raw. Никакой криптухи / IO внутри — только состояние.
- `Core/Files/FileCatalog.{swift,kt}` — реестр поддерживаемых MIME: images (jpg/jpeg/png/gif/heic/webp), video (mp4/mov), audio (mp3/m4a/aac/wav), docs (pdf/doc/docx/txt/zip). Парность между платформами проверяется скриптом.
- `Core/Managers/ConnectionManager`: добавлено `sendControl(ControlMessage)`, `sendFile(data,name,mime) -> fileId`, `incomingFile` (AsyncStream / SharedFlow), `awaitSendSlot()` — backpressure при `dataChannel.bufferedAmount > 16 КБ` (каждые 10 мс). handleControl роутит file-start/chunk/complete/retransmit.
- `Features/Chat/ChatViewModel`: `sendAttachment(data,name,mime)`, `startVoiceRecording` / `stopVoiceRecordingAndSend` / `cancelVoiceRecording`, подписка на `connection.incomingFile`, запись временных файлов в tmp/cacheDir.
- `Features/Chat/ChatBubble`: рендерит text/voice/image/file варианты. Image тапается → open FullScreenImageView.
- `Features/Chat/ChatInputBar.swift` (iOS) / inline InputBar в `ChatScreen.kt` (Android): кнопка attach (PhotosPicker / PickVisualMedia для фото + DocumentPicker / OpenDocument для файлов), hold-to-record мик.
- `Features/Chat/FullScreenImageView.{swift,kt}`: pinch/zoom + drag, sampled decode до 2048px (iOS — CGImageSource thumbnails, Android — BitmapFactory inSampleSize).

**Wire format дополнение:**
- `ControlMessage.fileComplete` теперь несёт `sha256` (64 hex chars). Формула: сэндер считает SHA-256 всего файла до нарезки, ресивер после сборки сверяет. Integrity fail → `Event.integrityFailure`, файл удаляется из state.

**Кросс-платформенный test vector:**
- `bytes[i] = (i*31 + 7) mod 256`, i = 0..3999. Ожидаемый SHA-256 = `2e781e3762b7c315ce53c7e3645f59b2e4c037db30c6bec3a195e0751bd62722`. Проверяется в iOS `test_crossPlatformVector_deterministicHashForFixedInput` и Android `cross-platform vector sha256 matches iOS`, плюс независимо пересчитывается через Node в verify_phase_5.sh.

**Lessons learned (Phase 5):**
- **JSON роутинг encrypted сообщений:** на принимающей стороне ConnectionManager сначала decrypt → пытается `JSONDecoder().decode(ControlMessage)`. Если получается — это control (с `_ctrl: true`), иначе — plain text. Для Android `ControlMessage.decode` кидает `MissingCtrlMarker` для не-control, оборачиваем в `runCatching`.
- **Base64 byte-identical между iOS/Android:** iOS `Data.base64EncodedString()` и Java `Base64.getEncoder().encodeToString(bytes)` производят байт-идентичный RFC 4648 output (padding=true, без line wrap). НЕ использовать `android.util.Base64.DEFAULT` — он вставляет `\n` каждые 76 символов и не совпадает.
- **Backpressure через `dataChannel.bufferedAmount`:** iOS Swift property `UInt64`, Android Kotlin функция `bufferedAmount(): Long`. Spec threshold = 16 КБ. Внутри send-цикла для чанков: `while bufferedAmount > 16384: sleep 10 ms`. Без этого SCTP очередь растёт, переполнение → падение DC. Поднимал на 1 MB файлах — без backpressure очередь выходит за 1 МБ, с backpressure держится ~18-20 КБ.
- **`PickVisualMedia.ImageOnly` + `OpenDocument`:** Android 13+ даёт доступ без READ_EXTERNAL_STORAGE. `OpenDocument` принимает массив MIME, `image/*`, `audio/*`, `application/pdf` и т.д.
- **Long-press на mic кнопке (Compose):** `pointerInput` с `detectTapGestures(onLongPress = startVoice, onPress = { tryAwaitRelease(); stopVoice() })`. Если использовать только `onLongPress` без `onPress` — не видим релиз.
- **Sampled bitmap decode:** iOS использует `CGImageSourceCreateThumbnailAtIndex` с `kCGImageSourceThumbnailMaxPixelSize=2048`, Android — два прохода: `inJustDecodeBounds=true` → вычисляем `inSampleSize` (power of 2, чтобы longer side ≤ 2048) → `BitmapFactory.decodeFile(path, opts)`. Без sample decode 50MP jpg кладёт процесс на OOM.
- **Xcode simulator preflight flake:** два подряд `xcodebuild ... test` на одном симе иногда даёт `Application failed preflight checks`. verify_phase_5.sh бутит sim заранее через `simctl boot` + `bootstatus -b`, и при этой ошибке делает одну попытку с shutdown+boot.
- **SHA-256 in fileComplete (не fileStart):** спец говорит "integrity hash on completion" — поставил в `fileComplete`, потому что семантика "transfer done + verify" читается яснее. Sender всё равно обязан считать SHA до отправки, так что ранний аборт невозможен в любом варианте.
- **Retransmit state:** `outbound[fileId] = chunkMessages` хранится в FileTransferService до `forgetOutbound(fileId)`. Сейчас reset() на ConnectionManager полностью пересоздаёт сервис — outbound обнуляется только при leave-room. На 100MB файле это ~50K объектов в map, но живут они только на время сессии, что приемлемо.
- **`FileTransferService.chunked` возвращает `[]` для пустого файла** — totalChunks=0, но fileStart + fileComplete всё равно шлются. Receiver handle: `(0..<0)` range пустой → missing=[] → hash=SHA-256("") = `e3b0c44...b855` → completed с data=Data(). 0-byte roundtrip покрыт тестом.
- **Kotlin не поддерживает внешние/внутренние имена параметров (как в Swift).** Переименовал `mimeType(forFilename filename:)` → `mimeType(filename:)`.

**Phase 5 success criteria (все ✓):**
- [x] iOS: 197 unit тестов, 0 failures (20 FileTransferServiceTests + 3 retransmit + 8 FileCatalogTests + 3 новых ControlMessage = +34 новых тестов к Phase 3/4 baseline)
- [x] Android: 125 unit тестов, 0 failures (20+3 FileTransferServiceTest + 8 FileCatalogTest + 2 ControlMessage sha256 = +33 тестов)
- [x] Cross-platform SHA-256 вектор совпадает байт-в-байт (проверено Node-пересчётом)
- [x] iOS `xcodebuild build` + `xcodebuild test` → BUILD/TEST SUCCEEDED
- [x] Android `:app:assembleDebug` + `:app:testDebugUnitTest` + `:app:lintDebug` BUILD SUCCESSFUL
- [x] Chunk size = 2048, backpressure = 16 KiB — в обоих ConnectionManager'ах
- [x] VoiceRecorder: 44100 Hz, 64 kbps, AAC m4a — на обоих
- [x] ChatViewModel ≤ 300 LOC (iOS 152, Android 158)
- [x] Все исходники ≤ 400 LOC
- [x] `verify_phase_5.sh` exit code 0

**Phase 5 — manual verification required (cannot automate):**
- Real-device e2e: attach JPG iOS → Android receives byte-identical (проверить через SHA-256 на обоих)
- Voice message iOS → Android playback
- PDF / DOC attach в обе стороны
- FullScreenImageView pinch-zoom на реальном телефоне (жесты не работают в симуляторе)
- Backpressure под нагрузкой: 50+ МБ файл, мониторить `bufferedAmount` (не должно превышать ~20 КБ)
- Retransmit path: искусственно дропнуть chunk → получатель шлёт fileRetransmit → отправитель ре-эмитит

---

## Deferred from Phase 5 (→ Phase 6 / Phase 7)
- Voice message waveform playback (сейчас только play icon + оценка длительности по размеру). Full waveform + seekbar — Phase 7.
- Per-chunk 30-секундный таймаут на receive стороне (сейчас retransmit срабатывает только когда приходит fileComplete с пропусками). Полный timer-driven retransmit — Phase 6 hardening.
- Streaming file reads с диска для больших файлов (сейчас вся byteArray в память). Для 100+ MB — Phase 6.
- Full-screen image viewer "pinch-snap-back" при scale<1 + centering на double-tap — Phase 7 polish.
- File types: video playback inline (сейчас video message = file card с иконкой).
- Encrypted disk persistence файлов для saved contacts (сейчас в tmp/cacheDir). SQLCipher blob persistence — Phase 6.

---

### Phase 6 — Security Hardening (быстрая справка)
- Contact key rotation: HKDF(sharedSecret, salt="ghost-rot-v1", info="ghost-rot-seed") → обе стороны выводят одинаковый следующий keypair без wire-обмена. 3 поколения (current/previous/fallback) в SQLCipher. Детерминированно байт-в-байт iOS ↔ Android.
- Per-chunk 30s timeout + 3 retry: `ChunkTimeoutTracker` в `ConnectionManager`, не в `FileTransferService` (сервис остался чистой state-machine). progressed() сбрасывает retry counter; 3 timeout'а подряд → `onAbort` → cancel inbound.
- Secure wipe: 64 KiB zero-fill + fsync + unlink через `SecureWipe` модуль. `DatabaseService.deleteFile` теперь проходит через `wipeDatabase` (main + WAL + SHM + journal).
- Jailbreak/Root detection: detection-only, никогда не блокирует. iOS — path checks + fork() через `@_silgen_name` (обход availability marker). Android — RootBeer 0.1.0 + fallback path list.
- ReplayGuard: nonce LRU (10k entries) + counter window (1000) + ±5 min timestamp window. Встроен в `GhostChatCrypto.decrypt` ДО ratchet.decrypt. Timestamp check сейчас всегда nil (wire не несёт `t` поле) — зарезервировано.
- ML-KEM768 PQ hybrid: Android — полная реализация через BouncyCastle 1.82 (MLKEMKeyPairGenerator/Generator/Extractor). iOS — стабы под `@available(iOS 26, *)` (CryptoKit.MLKEM768 ждёт SDK). `hybridDeriveSharedKey` = HKDF(ecdh || mlkem?, salt="ghost-chat-v1-pq", info="ghost-dr-root") — байт-в-байт идентично.
- BouncyCastle 1.78.1 → 1.82 (ML-KEM требование). 23/23 :crypto тестов зелёные после bump.

**Lessons learned (Phase 6):**
- Swift `fork()` помечен `@available(*, unavailable)` для iOS sandbox. Обход через `@_silgen_name("fork")` для jailbreak detector. На симуляторе `#if targetEnvironment(simulator)` исключает вызов.
- `runBlocking<Unit> { ... }` — JUnit требует void return type; expression-body `= runBlocking { ... }` оставляет тип последнего выражения. Либо явно `runBlocking<Unit>`, либо block body.
- SQLCipher JNI в JVM unit test не загружается. `ContactManagerRotationTest` на Android через mockito-kotlin (мок `ContactStore` + `DatabaseService`), не через реальную БД.
- iOS simulator preflight flake после нескольких test runs. `xcrun simctl erase <UDID>` + reboot перед retry. verify_phase_6.sh делает shutdown+erase+boot при детекции "Application failed preflight checks".
- BC 1.82 имеет ML-KEM через `org.bouncycastle.pqc.crypto.mlkem.*` пакет. `MLKEMKeyPairGenerator`/`MLKEMGenerator.generateEncapsulated`/`MLKEMExtractor.extractSecret`. `MLKEMParameters.ml_kem_768` для 768-параметра.
- `RandomAccessFile.fd.sync()` на Android — обязательный flush перед deleting. Без него overwrite может не попасть на диск до unlink.
- Kotlin `LinkedHashMap` сохраняет insertion order → для `ReplayGuard.cleanupExpiredNonces` iterating + break на первой не-просроченной записи работает корректно.
- BC 1.82 ML-KEM класс `BCMLKEMPublicKeyParameters`/`BCMLKEMPrivateKeyParameters` (в `pqc.crypto.mlkem`), НЕ `provider.asymmetric.mlkem` (это JCA provider wrapper). Low-level API удобнее для прямого byte-exchange.
- iOS `@_silgen_name` directive работает с Darwin `fork()` и обходит Swift availability аннотации. Для других unavailable C функций (typedef'ed `@available(*, unavailable)`) это единственный способ вызвать их из Swift.

**Phase 6 — deferred / manual verification:**
- Full ML-KEM handshake через signaling requires two-round protocol bump (HOST sends pqKey → GUEST encapsulates → GUEST sends pqCiphertext back). Wire поля уже зарезервированы, `PostQuantum` модуль функционален. Интеграция — Phase 7.
- Контакт key rotation call site: `ContactManager.rotateKeys()` готов, но не вызывается автоматически при `ConnectionManager.leave()`. Требует добавления `currentContactId` в ConnectionManager + callback. Сейчас ChatViewModel может вызывать явно.
- Timestamp в ReplayGuard сейчас `null` — wire format не несёт `t` поле в plaintext envelope. Wrapping message payload в `{m, t, c, id}` envelope = Phase 7 protocol bump.
- Real-device jailbreak/root detection sanity check.
- SQLCipher encryption proof test на Android требует androidTest (реальный эмулятор), не unit (JNI не грузится в Robolectric).

**Phase 6 success criteria (все ✓):**
- [x] `verify_phase_6.sh` exit code 0 (20/20 steps PASSED)
- [x] iOS full suite 251/251, 0 failures (+42 от Phase 5 baseline)
- [x] Android :app:testDebugUnitTest 184/184, 0 failures (+59 от Phase 5)
- [x] Android :crypto:test 23/23 после BC 1.82 bump
- [x] Android :app:assembleDebug BUILD SUCCESSFUL (~143 MB APK)
- [x] Android :app:lintDebug BUILD SUCCESSFUL
- [x] ChatViewModel iOS 152 LOC, Android 158 LOC (≤ 300)
- [x] Каждый исходник ≤ 400 LOC
- [x] Cross-platform HKDF vectors совпадают (Node recomputed)
- [x] SecureWipe wired into DatabaseService.deleteFile (обе платформы)
- [x] ReplayGuard wired into GhostChatCrypto.decrypt (обе платформы)
- [x] BC 1.82 + RootBeer 0.1.0 в classpath Android
- [x] Нет Log.* / print() с key material

---

# Claude / AI Senior Engineer Prompt (Plan Mode)

Before writing any code, review the plan thoroughly.  
Do NOT start implementation until the review is complete and I approve the direction.

For every issue or recommendation:

- Explain the concrete tradeoffs
- Give an opinionated recommendation
- Ask for my input before proceeding

Engineering principles to follow:

- Prefer DRY — aggressively flag duplication
- Well-tested code is mandatory (better too many tests than too few)
- Code should be “engineered enough” — not fragile or hacky, but not over-engineered
- Optimize for correctness and edge cases over speed of implementation
- Prefer explicit solutions over clever ones

---

## 1. Architecture Review

Evaluate:

- Overall system design and component boundaries
- Dependency graph and coupling risks
- Data flow and potential bottlenecks
- Scaling characteristics and single points of failure
- Security boundaries (auth, data access, API limits)

---

## 2. Code Quality Review

Evaluate:

- Project structure and module organization
- DRY violations
- Error handling patterns and missing edge cases
- Technical debt risks
- Areas that are over-engineered or under-engineered

---

## 3. Test Review

Evaluate:

- Test coverage (unit, integration, e2e)
- Quality of assertions
- Missing edge cases
- Failure scenarios that are not tested

---

## 4. Performance Review

Evaluate:

- N+1 queries or inefficient I/O
- Memory usage risks
- CPU hotspots or heavy code paths
- Caching opportunities
- Latency and scalability concerns

---

## For each issue found:

Provide:

1. Clear description of the problem
2. Why it matters
3. 2–3 options (including “do nothing” if reasonable)
4. For each option:
   - Effort
   - Risk
   - Impact
   - Maintenance cost
5. Your recommended option and why

Then ask for approval before moving forward.

---

## Workflow Rules

- Do NOT assume priorities or timelines
- After each section (Architecture → Code → Tests → Performance), pause and ask for feedback
- Do NOT implement anything until I confirm

---

## Start Mode

Before starting, ask:

**Is this a BIG change or a SMALL change?**

BIG change:

- Review all sections step-by-step
- Highlight the top 3–4 issues per section

SMALL change:

- Ask one focused question per section
- Keep the review concise

---

## Output Style

- Structured and concise
- Opinionated recommendations (not neutral summaries)
- Focus on real risks and tradeoffs
- Think and act like a Staff/Senior Engineer reviewing a production system

ssh -i ~/.ssh/digitalocean_key root@139.59.58.151

# Ghost Chat v2 — Complete Build Specification

You are building **Ghost Chat v2** from scratch — a zero-identity P2P encrypted messenger with voice calls for iOS and Android. This is a full rebuild of an existing 41K LOC app. The goal: the most secure messenger that exists, where no registration, no phone number, no email, no persistent ID is required.

**Domain:** ghostchat.one
**Server:** DigitalOcean droplet (139.59.58.151), Docker deployment
**Apple Developer Team ID:** G2VZKDYV38
**Bundle ID:** com.kordar.ghostchat (new, clean)
**Languages:** EN + RU (flexible system — trivial to add more later)

---

## CRITICAL CONSTRAINTS — READ BEFORE WRITING ANY CODE

### Security Rules (NEVER violate)

- NEVER log, print, or persist decrypted message content or key material
- NEVER use custom crypto primitives — only CryptoKit (iOS), BouncyCastle (Android), Web Crypto
- NEVER add a fallback to certificate pinning — if pin fails, connection DIES
- NEVER store anything in UserDefaults/SharedPreferences — use Keychain/KeyStore + SQLCipher only
- NEVER reuse AES-GCM nonces — derive from chain key + message number
- NEVER include key material in associated data logs, crash reports, or analytics
- Server NEVER decrypts, inspects, or stores message content — pure relay only
- All P2P data goes through encrypted DataChannel — server sees nothing after handshake

### Code Quality Rules

- No abstractions for single-use code. If 200 lines could be 50, rewrite it.
- Touch only what you must. Don't "improve" adjacent code, comments, or formatting.
- Don't create wrapper abstractions around crypto libraries.
- Every file under 400 lines. If bigger — split into focused modules.
- No god objects. ChatViewModel ≤ 300 lines — it delegates to managers.
- No force unwraps in Swift (except IBOutlets). No !! in Kotlin (except view binding).
- Comments explain WHY, not WHAT. No "// this function does X" comments.
- All crypto operations happen off main thread (async/await / Dispatchers.IO).

### Architecture Rule: Flexible by Design

Every feature is a self-contained module. Adding a new feature = adding a new folder under Features/ with its own View + ViewModel. No feature touches another feature's internals. Communication goes through protocols/interfaces and the shared managers in Core/.

---

## ARCHITECTURE OVERVIEW

```
ghost-chat/
├── server/                    # Node.js signaling + push relay
│   ├── src/
│   │   ├── index.ts          # HTTP + WebSocket server
│   │   ├── signaling.ts      # Room management, WS message routing
│   │   ├── turn.ts           # HMAC-SHA1 TURN credential generation
│   │   ├── push.ts           # APNs HTTP/2 + FCM v1 push delivery
│   │   └── rate-limiter.ts   # Per-IP, per-connection rate limiting
│   ├── Dockerfile
│   ├── docker-compose.yml    # server + coturn + nginx
│   └── package.json
│
├── ios/                       # Swift/SwiftUI iOS app
│   ├── GhostChat/
│   │   ├── App/              # Entry point, AppDelegate (CallKit, PushKit)
│   │   ├── Core/
│   │   │   ├── Crypto/       # Signal Protocol: DoubleRatchet, GhostCrypto, IdentityKeyService
│   │   │   ├── Network/      # SignalingClient (WebSocket), TURNService, CertificatePinning
│   │   │   ├── WebRTC/       # GhostRTC (PeerConnection + DataChannel), GhostVoice (audio)
│   │   │   ├── Storage/      # DatabaseService (SQLCipher), ContactStore, MessageStore
│   │   │   ├── Security/     # BiometricAuth, SecurityMonitor, KeychainService
│   │   │   ├── Audio/        # SoundLibrary, VoiceRecorder
│   │   │   ├── Push/         # PushManager (APNs token handling)
│   │   │   ├── Managers/     # ContactManager, CallManager, ConnectionManager, MessageManager, SettingsManager
│   │   │   └── Localization/ # LocalizationManager
│   │   ├── Features/
│   │   │   ├── Welcome/      # Home screen, create/join room, contact list
│   │   │   ├── Chat/         # ChatView, ChatViewModel (thin orchestrator ≤300 LOC)
│   │   │   ├── Call/         # CallView, IncomingCallView
│   │   │   ├── Contacts/     # ContactsView, ContactDetailView
│   │   │   └── Settings/     # SettingsView, LockScreenView, SecurityDashboard
│   │   ├── Models/           # Contact, ChatMessage, ControlMessage, Room
│   │   └── Resources/        # Assets, Localizable (EN, RU), Info.plist, sounds
│   ├── GhostChatTests/       # Unit tests (crypto, protocol, models)
│   └── project.yml           # XcodeGen configuration
│
├── android/                   # Kotlin/Jetpack Compose Android app
│   ├── app/src/main/
│   │   ├── java/.../ghostchat/
│   │   │   ├── core/         # Mirrors iOS Core/ exactly
│   │   │   ├── features/     # Mirrors iOS Features/ exactly
│   │   │   ├── models/       # Mirrors iOS Models/ exactly
│   │   │   └── ui/theme/     # Material3 dark theme
│   │   └── res/              # strings.xml (EN, RU), drawables, sounds
│   ├── app/build.gradle.kts
│   └── build.gradle.kts
│
└── docs/
    ├── crypto-protocol.md     # Signal Protocol wire format specification
    ├── api-contracts.md       # Server API + WebSocket message schemas
    └── security-model.md      # Threat model and security architecture
```

---

## PHASE 1: SERVER + INFRASTRUCTURE

### What to build

Stateless Node.js signaling server with TURN credential generation and push notification relay.

### Server specification (src/index.ts — target ~500 LOC total)

**Dependencies (5 only):** ws@8.20, helmet@8.1, rate-limiter-flexible@5.x, apns2@12.2 (APNs HTTP/2), firebase-admin@13.8 (FCM)

**No Express.** Use Node's built-in `http.createServer` for health endpoint + API routes.

**WebSocket Messages (signaling only):**
| Client → Server | Server → Client |
|-----------------|-----------------|
| `create-room` | `room-created { roomId }` |
| `join-room { roomId }` | `room-joined { roomId }` |
| `rejoin-room { roomId, role }` | `rejoin-ok` |
| `signal { data }` | `signal { data }` (relayed to peer) |
| `leave-room` | `peer-left` |

**API Endpoints:**
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/turn-credentials` | GET | HMAC-SHA1 TURN creds (1hr TTL, coturn-compatible) |
| `/api/send-push` | POST | VoIP push → APNs (iOS calls) |
| `/api/send-push-android` | POST | FCM data message (Android calls) |
| `/api/send-invite` | POST | Chat invite push (APNs regular / FCM) |
| `/api/push/notify` | POST | Offline message / missed call notification |
| `/api/pending-room` | POST/GET/DELETE | Pending room for auto-connect (saved contacts) |
| `/health` | GET | Health check for Docker |

**Room ID:** 48 random bytes → base64url (384 bits entropy). Brute-force impossible.

**Rate limiting:** 3 layers:

1. Per-IP connection rate: 5 connections/minute
2. Per-connection message rate: 40 messages/60 seconds
3. Per-IP simultaneous connections: max 3

**Room TTL:** 10 minutes (empty rooms auto-purge). Cleanup interval: 10 seconds.

**Push auth:** HMAC-SHA256 from `token + roomId + TURN_SECRET`, verified server-side. Prevents push spam.

**Pending Room API (for saved contacts auto-connect):**

- Deterministic HOST/GUEST: SHA256(myIdentityKey) < SHA256(peerIdentityKey) → HOST
- HOST creates room, registers pending via POST
- GUEST polls GET every 5 seconds
- Room auto-deletes after pickup or 60-second TTL

**TURN credential format:**

```
username = unixTimestamp:randomId
credential = base64(HMAC-SHA1(turnSecret, username))
```

coturn validates independently using same shared secret.

**Docker deployment:**

- `docker-compose.yml` with 3 services: ghost-server (Node.js), coturn, nginx
- coturn: `coturn/coturn:4.9.0-alpine`, host networking, TLS on 443
- nginx: WSS termination, `proxy_read_timeout 86400s`
- Let's Encrypt via certbot
- Server runs as non-root user (uid 1001)
- IPv4-first DNS: `dns.setDefaultResultOrder('ipv4first')` (Docker has no IPv6)

**Zero-retention design:**

- All state in Map/Set objects — no database, no Redis, no filesystem
- No logs of user data, only operational metrics
- On SIGTERM: clear all maps, terminate all connections
- Pre-key bundles: relay-only (real-time) or 15-minute ephemeral TTL

### Success criteria Phase 1:

- [ ] `docker compose up -d --build` succeeds
- [ ] WebSocket connects and creates/joins rooms
- [ ] TURN credentials validate against coturn
- [ ] Health endpoint returns 200
- [ ] Rate limiter blocks after threshold

---

## PHASE 2: CRYPTOGRAPHY LAYER (BOTH PLATFORMS SIMULTANEOUSLY)

### Signal Protocol implementation

Create identical implementations on iOS (Swift/CryptoKit) and Android (Kotlin/BouncyCastle) that produce **byte-identical ciphertext** for identical inputs.

### Identity Keys

- Persistent P-256 keypair stored in Keychain (iOS) / Android KeyStore
- Generated once on first app launch, never changes
- Used for: contact identification, pending room API hash, safety number generation
- NOT used for message encryption (that's the ratchet keys)

### Key Exchange (simplified X3DH for P2P)

Since Ghost Chat is real-time P2P (both parties online), use simplified exchange:

1. Both generate ephemeral ECDH P-256 keypair
2. Exchange public keys via signaling (plaintext, pre-encryption)
3. ECDH shared secret → HKDF-SHA256 → root key
4. Root key initializes Double Ratchet
5. Optional: ML-KEM768 hybrid PQ (iOS 26+ only, graceful degradation)

**Key exchange wire format:**

```json
{
  "type": "key-exchange",
  "publicKey": "base64(65-byte P-256 uncompressed)",
  "identityKey": "base64(65-byte identity public key)",
  "v": 3,
  "pqKey": "base64(ML-KEM encapsulation key)", // optional, host only
  "pqSupported": true // optional, guest only
}
```

### Double Ratchet (DoubleRatchet.swift / DoubleRatchet.kt)

**State (must persist between sessions for saved contacts):**

```
DHs: P256.KeyAgreement.PrivateKey  // our sending ratchet keypair
DHr: P256.KeyAgreement.PublicKey?  // their ratchet public key
RK:  SymmetricKey (32 bytes)       // root key
CKs: SymmetricKey? (32 bytes)     // sending chain key
CKr: SymmetricKey? (32 bytes)     // receiving chain key
Ns:  Int = 0                       // send message counter
Nr:  Int = 0                       // receive message counter
PN:  Int = 0                       // previous chain length
MKSKIPPED: [SkippedKeyIndex: SymmetricKey]  // max 100, in-memory only
```

**KDF chains:**

- Root KDF: `HKDF(RK, DH_output, salt: "ghost-dr-root", info: "ghost-dr-rk")` → (newRK, newCK) — split 64 bytes into two 32-byte keys
- Chain KDF: `HMAC-SHA256(CK, 0x01)` → messageKey, `HMAC-SHA256(CK, 0x02)` → newChainKey
- Message keys are ONE-TIME USE — derive, encrypt/decrypt, delete

**DH Ratchet step (triggers when receiving message with new DH key):**

1. Save PN = Ns, reset Ns = Nr = 0
2. DHr = new peer DH key from header
3. (RK, CKr) = root_KDF(RK, DH(DHs, DHr))
4. Generate new DHs keypair
5. (RK, CKs) = root_KDF(RK, DH(DHs, DHr))

**Skipped keys:** Store max 100 keys indexed by (dhPublicKey, messageNumber). Cleanup after 24 hours or successful decryption. Store IN MEMORY ONLY for one-time rooms. For saved contacts, persist in `skippedKeys` SQLCipher table.

**Wire format (encrypted message):**

```
base64(
  headerLength: 4 bytes (UInt32 big-endian)
  + header: 73 bytes (0x00 prefix + 65-byte DH public key + 4-byte PN + 4-byte N)
  + nonce: 12 bytes
  + ciphertext: variable
  + tag: 16 bytes
)
```

Header is NOT encrypted (unnecessary for P2P DataChannel which is already DTLS-encrypted).

**Plaintext JSON before encryption:**

```json
{
  "m": "message text",
  "t": 1713100800000, // Unix timestamp milliseconds
  "c": 42, // message counter
  "id": "uuid-v4", // message ID for ack/reply
  "r": { "id": "replyId", "t": "reply preview text" } // optional reply
}
```

**Message padding:** Pad to 256-byte blocks with cryptographically random bytes (SecRandomCopyBytes / SecureRandom). Format: `4-char length prefix + base64(message) + random padding`.

### Post-Quantum (ML-KEM768, optional)

- iOS 26+: CryptoKit.MLKEM768 natively
- Android: BouncyCastle 1.82+ includes ML-KEM
- Hybrid approach: combine ECDH shared secret + ML-KEM shared secret via HKDF
- If either party doesn't support PQ → gracefully fall back to ECDH-only
- Salt for hybrid: `"ghost-chat-v1-pq" + mlkem_shared_secret`

### Safety Number (fingerprint for MITM verification)

- SHA-256(sorted(identityKey_A + identityKey_B))
- First 16 bytes → hex → groups of 4 → uppercase
- Display in UI for manual verification

### Cross-platform test vectors

Create `docs/test-vectors.json` with deterministic inputs (fixed private keys, fixed messages) and expected outputs. Both iOS XCTest and Android JUnit must produce identical results.

### GhostCrypto.swift / GhostCrypto.kt (wrapper class)

Thin wrapper around DoubleRatchet that handles:

- Key exchange flow (init as host/guest)
- encrypt(plaintext) → padded, encrypted, base64 wire format
- decrypt(base64) → parse header, DH ratchet if needed, chain step, unpad, return plaintext
- Fingerprint generation
- Replay protection (nonce tracking + timestamp validation ±5 minutes)
- State serialization for saved contacts (Codable/Serializable)

### Success criteria Phase 2:

- [ ] iOS encrypts → Android decrypts correctly (and vice versa)
- [ ] DH ratchet triggers correctly on sender change
- [ ] Out-of-order messages decrypt via skipped keys
- [ ] Replay attack (same ciphertext twice) is rejected
- [ ] Message older than 5 minutes is rejected
- [ ] Test vectors pass identically on both platforms
- [ ] PQ exchange works between two iOS 26+ devices, degrades gracefully otherwise

---

## PHASE 3: iOS APP — CORE INFRASTRUCTURE

### Technologies

- Swift 5.9+, SwiftUI, iOS 16.0+
- XcodeGen (project.yml → .xcodeproj)
- SPM packages: WebRTC (stasel/WebRTC), SQLCipher, Sentry
- No CocoaPods (SPM only for clean dependency management)

### App entry (GhostChatApp.swift)

- @main, WindowGroup
- Biometric lock overlay (when enabled and app not unlocked)
- Deep link handling: `ghostchat://room/ROOM_ID` and `https://ghostchat.one/?room=ROOM_ID`
- Deep link shows confirmation dialog before joining (never auto-join)
- Scene phase observer: re-lock on background (unless active call)
- Fresh install detection → generate identity key

### AppDelegate

- CallKit setup (CXProvider + CXCallController)
- PushKit setup (VoIP push token)
- UNNotificationCenter setup (regular push)
- Sentry initialization
- CRITICAL: `didReceiveIncomingPushWith` MUST call `reportNewIncomingCall` IMMEDIATELY — iOS kills app otherwise

### Core/Managers/ — the brain of the app

Each manager owns ONE concern. ChatViewModel composes them all.

**ConnectionManager (~200 LOC):**

- State machine: disconnected → connecting → signaling → webrtc → connected → encrypted
- Owns SignalingClient + GhostRTC lifecycle
- Handles reconnection with exponential backoff

**CallManager (~200 LOC):**

- State machine: idle → calling → ringing → active → ended
- Owns GhostVoice lifecycle
- CallKit integration (reportIncomingCall, startCall, endCall)
- Audio session configuration (earpiece/speaker)
- CRITICAL: configure audio ONLY in CXProviderDelegate didActivate/didDeactivate

**MessageManager (~200 LOC):**

- Sole owner of messages array (no other module mutates it)
- Auto-delete timer (configurable per contact: 30s / 1m / 5m / 15m / 1h)
- Message persistence for saved contacts (SQLCipher)
- Send/receive through ConnectionManager's encrypted channel

**ContactManager (~200 LOC):**

- CRUD operations via ContactStore
- Push token management (VoIP + regular)
- Contact key rotation after each session
- Auto-connect flow (pending room API)
- Panic wipe (delete all contacts + keys instantly)

**SettingsManager (~100 LOC):**

- All settings in Keychain (not UserDefaults!)
- Privacy mode, biometric lock, auto-lock timeout, message TTL, sounds, language

### Core/Storage/ — SQLCipher encrypted database

**DatabaseService:**

- SQLCipher with GRDB.swift (or raw SQLCipher if GRDB SPM issues)
- Encryption key: 32 random bytes generated once, stored in Keychain
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- `PRAGMA secure_delete = ON` (overwrite deleted data with zeros)
- Excluded from iCloud backup
- File location: Application Support/ghostchat.db

**Schema (single migration, start clean):**

```sql
-- contacts
CREATE TABLE contacts (
    id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    identityKey BLOB NOT NULL,
    publicKey BLOB NOT NULL,
    previousKey BLOB,
    fallbackKey BLOB,
    pushToken BLOB,
    notifyToken BLOB,
    ratchetState BLOB,
    rotationCounter INTEGER DEFAULT 0,
    sessionCount INTEGER DEFAULT 0,
    messageTTL INTEGER DEFAULT 300,
    notes TEXT,
    isMuted INTEGER DEFAULT 0,
    createdAt REAL NOT NULL,
    lastSessionAt REAL
);

-- messages (for saved contacts only)
CREATE TABLE messages (
    id TEXT PRIMARY KEY,
    contactId TEXT NOT NULL,
    text TEXT NOT NULL,
    type INTEGER NOT NULL DEFAULT 0,
    isDelivered INTEGER NOT NULL DEFAULT 0,
    isPending INTEGER NOT NULL DEFAULT 0,
    createdAt REAL NOT NULL,
    fileName TEXT,
    fileSize INTEGER,
    fileMimeType TEXT,
    fileLocalPath TEXT,
    fileId TEXT,
    replyToId TEXT,
    replyToText TEXT,
    isEdited INTEGER DEFAULT 0,
    senderMessageId TEXT,
    isPinned INTEGER DEFAULT 0,
    FOREIGN KEY (contactId) REFERENCES contacts(id) ON DELETE CASCADE
);

-- skipped Double Ratchet keys (for saved contacts)
CREATE TABLE skippedKeys (
    contactId TEXT NOT NULL,
    dhPublicKey BLOB NOT NULL,
    messageNumber INTEGER NOT NULL,
    messageKey BLOB NOT NULL,
    createdAt REAL NOT NULL,
    PRIMARY KEY (contactId, dhPublicKey, messageNumber)
);
```

### Core/Security/

**BiometricAuthService:**

- Face ID / Touch ID via LAContext.evaluatePolicy
- 4-6 digit PIN as backup
- Decoy PIN → shows fake empty state (different PIN than real one)
- 10 failed attempts → panic wipe (destroy DB + Keychain + all files)
- Setting stored in Keychain, not UserDefaults
- Auto-lock timeout: configurable (0/30s/1m/5m/30m)

**SecurityMonitor:**

- Screenshot detection: UIApplication.userDidTakeScreenshotNotification
- Screen recording: UIScreen.capturedDidChangeNotification
- Bluetooth device monitoring: AVAudioSession.routeChangeNotification
- All alerts sent to peer via encrypted control message

**KeychainService:**

- Wrapper for Security framework
- All items: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
- kSecAttrIsInvisible = true (don't show in Keychain viewer)

**CertificatePinning:**

- SPKI-SHA256 pin for ghostchat.one
- NO FALLBACK. If pin fails → cancel connection, show error.
- Include 2 pins: current + backup for rotation
- Applied to SignalingClient AND TURNService

### Core/WebRTC/

**GhostRTC:**

- RTCPeerConnection + RTCDataChannel ("ghost-chat", ordered, reliable)
- STUN: stun.l.google.com:19302, stun.cloudflare.com:3478
- TURN: coturn with fetched HMAC credentials
- Privacy mode: `iceTransportPolicy = .relay` (hides real IP)
- ICE candidate filtering: drop host candidates (local IPs), drop IPv6 link-local
- Perfect Negotiation pattern: polite (guest) / impolite (host)
- DataChannel label validation: reject if not "ghost-chat"
- Renegotiation for adding audio tracks mid-session
- Disconnect timer: 5 seconds before declaring disconnected (ICE may recover)

**GhostVoice:**

- AVAudioSession: .playAndRecord, .voiceChat mode
- Earpiece by default, toggle to speaker
- Echo cancellation + noise suppression enabled
- 48kHz sample rate, 10ms buffer
- Audio track: "ghost-audio-0" in stream "ghost-audio-stream"
- Call timer with formatted display (MM:SS)
- CRITICAL: audio session configured ONLY within CallKit's didActivate/didDeactivate

### Features/ — UI Screens

**WelcomeView:**

- Create room button → generates room, shows invite link
- Join room input → validate base64url 64-char format
- Contact list (if contacts exist) → tap to auto-connect
- Settings gear icon

**ChatView + ChatViewModel (≤300 LOC):**

- ChatViewModel is a THIN ORCHESTRATOR. It holds references to all managers.
- It does NOT contain business logic — only UI state binding and delegation.
- Message list with bubbles (sent right/blue, received left/gray, system center)
- Self-destruct timer on each message (visual countdown)
- Input field with send button
- File attachment (photos, files, voice messages)
- Reply by long-press or swipe
- Typing indicator
- Call button in top bar
- Safety number display + verification status
- Connection status indicator

**CallView:**

- Timer display (MM:SS)
- Mute toggle
- Speaker/earpiece toggle
- End call button
- Peer name display (contact label or "Ghost Chat")

**IncomingCallView:**

- Full-screen overlay
- Accept / Decline buttons
- Peer name display
- Vibration + ringtone

**ContactsView + ContactDetailView:**

- Search bar
- Contact list with last session time
- Contact detail: rename, notes, custom TTL, delete
- Safety number display
- Panic wipe button (settings, not contact detail)

**SettingsView:**

- Privacy mode toggle
- Biometric lock toggle + PIN setup
- Auto-lock timeout
- Language picker (EN, RU — extensible)
- Sound picker (ringtone, message sound)
- Security dashboard (connection status, encryption info)
- Data management (wipe all data)
- About / Version

### Control Messages (via encrypted DataChannel)

All control messages have `_ctrl: true` marker.

| Type              | Payload                                       | Direction         |
| ----------------- | --------------------------------------------- | ----------------- |
| `renegotiate`     | `{sdp}`                                       | Bidirectional     |
| `call-request`    | —                                             | Caller → Callee   |
| `call-response`   | `{accepted: bool}`                            | Callee → Caller   |
| `call-end`        | —                                             | Either            |
| `security-alert`  | `{alert: string}`                             | Either            |
| `message-ack`     | `{c: counter}`                                | Receiver → Sender |
| `message-read`    | `{c: counter}`                                | Receiver → Sender |
| `ready`           | —                                             | HOST → GUEST      |
| `push-token`      | `{token: hex}`                                | Both              |
| `notify-token`    | `{token: hex}`                                | Both              |
| `typing`          | `{isTyping: bool}`                            | Either            |
| `capabilities`    | `{features: [string]}`                        | Both              |
| `file-start`      | `{fileId, name, size, mimeType, totalChunks}` | Sender            |
| `file-chunk`      | `{fileId, index, data: base64}`               | Sender            |
| `file-complete`   | `{fileId}`                                    | Sender            |
| `file-retransmit` | `{fileId, indices: [int]}`                    | Receiver          |
| `message-delete`  | `{messageId}`                                 | Either            |
| `message-edit`    | `{messageId, newText}`                        | Sender            |
| `message-pin`     | `{messageId, pinned: bool}`                   | Either            |

### Connection Flow

```
1. User creates room → WS create-room → room-created → roomId set
2. Share invite link → ghostchat.one/?room=ROOM_ID
3. Peer joins → WS join-room → peer-joined → HOST starts WebRTC
4. HOST: initAsHost → DataChannel + offer → WS signal
5. GUEST: initAsGuest → handleOffer → answer → WS signal
6. ICE candidates exchanged (trickle)
7. DataChannel opens → key-exchange (plaintext, one-time)
8. ECDH + optional PQ → deriveSharedKey → Double Ratchet initialized
9. completeKeyExchange → send ready + capabilities + push tokens
10. GUEST receives ready → send chain initialized → start messaging
```

### Auto-Connect Flow (saved contacts)

```
1. Open contact → startChatWithContact()
2. Deterministic role: SHA256(myIdentityKey) < SHA256(peerIdentityKey) → HOST
3. HOST: create room + register pending + send invite push
4. GUEST: poll GET /api/pending-room every 5s
5. GUEST finds room → join → P2P handshake → key exchange
6. Ratchet state restored from SQLCipher if exists
```

### Voice Call Flow

```
ONLINE (both connected via DataChannel):
1. Caller: send call-request control message
2. Callee: show incoming call UI (IncomingCallView or CallKit)
3. Callee accepts: send call-response(accepted: true)
4. Both: add audio track → renegotiate → audio flows via DTLS-SRTP
5. End: send call-end → remove tracks → deactivate audio session

OFFLINE (peer not in app):
1. Caller: create room → send VoIP push via /api/send-push
2. Peer device wakes → PushKit → CallKit → show incoming call
3. Peer joins room → P2P handshake → key exchange → call
```

### Success criteria Phase 3 (iOS):

- [ ] App launches, creates room, shows invite link
- [ ] Two iOS devices connect P2P and exchange encrypted messages
- [ ] Messages self-destruct after timer
- [ ] Voice calls work with earpiece routing
- [ ] Contact saved, auto-connect works on re-open
- [ ] Biometric lock works (Face ID / PIN)
- [ ] Decoy PIN shows empty state
- [ ] Panic wipe destroys all data
- [ ] Certificate pinning rejects MITM proxy
- [ ] Screenshot detection alerts peer
- [ ] Deep links work (ghostchat:// and https://ghostchat.one)

---

## PHASE 4: ANDROID APP — MIRROR iOS EXACTLY

The Android app must be a pixel-perfect functional mirror of iOS. Same architecture, same features, same protocol, same wire format.

### Technologies

- Kotlin 2.1+, Jetpack Compose, minSdk 28, targetSdk 35
- Hilt for DI
- WebRTC: io.getstream:stream-webrtc-android or ch.threema:webrtc-android
- SQLCipher: net.zetetic:sqlcipher-android:4.14.1
- BouncyCastle: org.bouncycastle:bcprov-jdk18on:1.82 (ECDH + HKDF + ML-KEM)
- Firebase: FCM for push
- Sentry for crash reporting

### Android-specific differences from iOS

- **OkHttp** WebSocket (not URLSession)
- **BouncyCastle** for all crypto (Android CryptoKit insufficient)
- **EncryptedSharedPreferences** or DataStore + Tink for settings
- **FCM** single token for both calls and invites
- **Foreground Service** type `phoneCall|microphone` for active calls
- **ConnectionService** (self-managed PhoneAccount) for system call UI
- **FLAG_SECURE** on all Activities (prevents screenshots globally)
- **registerScreenCaptureCallback** (Android 14+) for screen recording detection
- **FileProvider** for file sharing via Intent

### Architecture mirrors iOS exactly:

```
core/
├── crypto/       → GhostCrypto.kt, DoubleRatchet.kt, IdentityKeyService.kt
├── network/      → SignalingClient.kt, TURNService.kt, CertificatePinning.kt
├── webrtc/       → GhostRTC.kt, GhostVoice.kt
├── storage/      → DatabaseService.kt, ContactStore.kt, MessageStore.kt
├── security/     → BiometricAuthService.kt, SecurityMonitor.kt
├── audio/        → SoundLibrary.kt, VoiceRecorder.kt
├── push/         → PushManager.kt, GhostFirebaseService.kt
├── managers/     → ContactManager.kt, CallManager.kt, ConnectionManager.kt, etc.
└── localization/ → LocalizationManager.kt

features/
├── welcome/      → WelcomeScreen.kt
├── chat/         → ChatScreen.kt, ChatViewModel.kt
├── call/         → CallScreen.kt, IncomingCallScreen.kt
├── contacts/     → ContactsScreen.kt, ContactDetailScreen.kt
└── settings/     → SettingsScreen.kt, LockScreen.kt
```

### Same database schema, same wire format, same protocol version.

### Success criteria Phase 4 (Android):

- [ ] All iOS success criteria also pass on Android
- [ ] iOS ↔ Android cross-platform messaging works
- [ ] iOS ↔ Android voice calls work
- [ ] FCM push wakes app for incoming calls
- [ ] FLAG_SECURE prevents screenshots in recent apps

---

## PHASE 5: FILE TRANSFER + VOICE MESSAGES

### Chunked file transfer via encrypted DataChannel

- Max chunk: 2KB raw → ~3KB base64 → encrypt → ~4KB on wire
- Backpressure: pause when DataChannel.bufferedAmount > 16KB
- Timeout: 30 seconds per chunk
- Missing chunks: file-retransmit with list of indices
- SHA-256 integrity hash on completion
- Files exist IN MEMORY ONLY (for one-time rooms) or encrypted on disk (saved contacts)
- Auto-delete with message timer

### Supported types

- Images: jpg, jpeg, png, gif, heic, webp
- Video: mp4, mov
- Audio: mp3, m4a, aac, wav
- Documents: pdf, doc, docx, txt, zip

### Voice messages (Telegram-style)

- Hold-to-record, release to send
- AAC m4a, 44100Hz mono, 64kbps
- Minimum duration: 0.3s
- Amplitude metering every 50ms (waveform visualization)
- Sent as file-start/chunk/complete with mime: audio/mp4

### Full-screen image viewer

- Pinch-to-zoom
- Decode with sampling (max 2048px) to prevent OOM
- Close on tap outside / back gesture

---

## PHASE 6: SECURITY HARDENING + TESTING

### Contact key rotation (between sessions)

After each session with a saved contact:

1. Both compute: `new_seed = HKDF(session_shared_secret, "contact-rotation")`
2. Derive new public keys for both parties
3. Derive new push token identifier
4. Store: current key, previous key, fallback key (3 generations)
5. On next connect: try current → previous → fallback
6. From outside: every session looks like two strangers connecting

### Secure wipe

- All files overwritten with zeros before deletion (64KB chunks)
- DB file + WAL + SHM + journal wiped
- `PRAGMA secure_delete = ON` in SQLCipher
- Keychain items deleted explicitly

### Jailbreak / Root detection

- iOS: check for Cydia, /etc/apt, fork() success, MobileSubstrate
- Android: Play Integrity API + RootBeer library
- Warn user but don't block (some legitimate users use rooted devices)

### Tests to write

**Crypto tests (CryptoTests.swift / CryptoTest.kt):**

- ECDH key exchange produces correct shared secret (test vectors)
- AES-256-GCM encrypt/decrypt roundtrip
- Double Ratchet: send 5 from A, 3 from B, 2 from A — all decrypt
- Out-of-order: messages 1,3,2 — all decrypt
- Replay: same ciphertext twice — second fails
- Timestamp: message from 10 minutes ago — rejected
- Padding: padded length is multiple of 256
- Cross-platform: iOS ciphertext decrypts on Android (test vectors JSON)

**Connection tests:**

- Room create → join → DataChannel opens
- Key exchange completes → encrypted message works
- Peer disconnect → reconnect → session resumes
- TURN relay mode → connection succeeds

**Security tests:**

- Certificate pinning: MITM proxy → connection fails
- Biometric lock: background → foreground → lock screen shown
- Decoy PIN: correct decoy → empty state
- Panic wipe: trigger → all data gone → verify Keychain empty + DB file deleted

---

## PHASE 7: POLISH + APP STORE / GOOGLE PLAY

### Localization (EN + RU)

- iOS: Localizable.xcstrings (String Catalogs)
- Android: res/values/strings.xml + res/values-ru/strings.xml
- Shared key naming: `section.key_name` (e.g., `chat.message_sent`, `call.incoming`)
- LocalizationManager: detect system locale, allow manual override, persist in settings

### App Store submission

- Bundle ID: com.kordar.ghostchat
- Privacy Labels: "Data Not Collected" for all categories
- Privacy Policy URL: ghostchat.one/privacy
- Info.plist: NSFaceIDUsageDescription, NSMicrophoneUsageDescription, NSCameraUsageDescription
- ITSAppUsesNonExemptEncryption = YES (file annual self-classification with BIS)
- Background modes: voip, audio, remote-notification
- .well-known/apple-app-site-association for universal links

### Google Play submission

- Signing: new keystore for v2
- assetlinks.json for app links
- Privacy policy
- Data safety section: no data collected

### Landing page (ghostchat.one)

- Static HTML/CSS landing page (already created, deploy to server)
- /privacy → privacy policy page
- /?room=ROOM_ID → deep link redirect to app (with fallback instructions)

---

## CONVENTIONS

- UI default language: user's system language (fallback EN)
- 2 localizations: EN, RU (designed to easily add more)
- All comments: English
- Room IDs: base64url-encoded 48 random bytes (384 bits)
- All P2P messages: JSON with `type` field
- Control messages: `_ctrl: true` marker
- Git: conventional commits, never commit secrets
- Build numbers: increment before every archive
- NEVER use Fastlane — Xcode Archive manually
- NEVER add Co-Authored-By to git commits

---

## DEPENDENCIES SUMMARY

### iOS (SPM)

| Package                     | Use                |
| --------------------------- | ------------------ |
| stasel/WebRTC               | WebRTC framework   |
| SQLCipher (via GRDB or raw) | Encrypted database |
| Sentry                      | Crash reporting    |

### Android (Gradle)

| Package                                | Use                         |
| -------------------------------------- | --------------------------- |
| io.getstream:stream-webrtc-android     | WebRTC                      |
| net.zetetic:sqlcipher-android:4.14.1   | Encrypted database          |
| org.bouncycastle:bcprov-jdk18on:1.82   | Crypto (ECDH, HKDF, ML-KEM) |
| com.google.firebase:firebase-messaging | FCM push                    |
| io.sentry:sentry-android               | Crash reporting             |
| com.google.dagger:hilt-android         | DI                          |
| androidx.core:core-telecom             | Call integration            |

### Server (npm)

| Package               | Use                   |
| --------------------- | --------------------- |
| ws                    | WebSocket             |
| apns2                 | APNs HTTP/2           |
| firebase-admin        | FCM                   |
| rate-limiter-flexible | Rate limiting         |
| helmet                | HTTP security headers |

---

## EXECUTION ORDER

1. **Phase 1:** Server + Docker + coturn → verify WebSocket + TURN
2. **Phase 2:** Crypto layer (iOS + Android simultaneously) → verify cross-platform test vectors
3. **Phase 3:** iOS app (all features) → verify on real device
4. **Phase 4:** Android app (mirror iOS) → verify cross-platform communication
5. **Phase 5:** File transfer + voice messages → verify on both platforms
6. **Phase 6:** Security hardening + full test suite → verify all tests pass
7. **Phase 7:** Polish + App Store / Google Play submission

Each phase has success criteria. Do NOT proceed to the next phase until ALL criteria for the current phase are met. If a criterion fails, fix it before moving on.

---

## WHAT THIS APP IS NOT

- NOT a daily messenger (no cloud sync, no group chats with 200 people)
- NOT a Signal clone (no registration, no phone numbers, no pre-key server)
- NOT a web app (mobile-only, web is just the landing page + docs)
- NOT a social network (no profiles, no status updates, no stories)

Ghost Chat is a tool for conversations that need to stay private. When you need to talk and leave no trace — Ghost Chat is what you use.
