# Phase 4 — Android Implementation Plan

**Goal:** Feature-parity Android app mirroring the iOS app produced in Phase 3. Same architecture, same protocol, same UI structure. Cross-platform byte-compat already proven in Phase 2 (`:crypto` module, 21 tests green).

**Architecture:**
- Single Gradle multi-module build: `:crypto` (existing Kotlin/JVM lib, BouncyCastle) + `:app` (new, com.android.application).
- `:app` depends on `:crypto` — no duplicated crypto code, Phase 2 tests stay intact.
- App is Kotlin 2.1 + Jetpack Compose + Hilt, `minSdk 28 / targetSdk 35`.
- Mirrors iOS folder tree under `android/app/src/main/java/com/kordar/ghostchat/`:
    - `core/{crypto,network,webrtc,storage,security,audio,push,managers,localization}`
    - `features/{welcome,chat,call,contacts,settings}`
    - `models/`
- One file = one Kotlin file per iOS Swift file where it makes sense; file ≤ 400 lines, `ChatViewModel ≤ 300`.

**Tech Stack:**
- Kotlin 2.1.x, AGP 8.7.x, Gradle 8.9+
- Jetpack Compose, Material3 dark theme
- Hilt for DI (`@HiltAndroidApp`, `@HiltViewModel`, `@AndroidEntryPoint`)
- OkHttp 4.12 WebSocket + CertificatePinner (no fallback)
- BouncyCastle 1.78.1 (already in `:crypto`)
- SQLCipher `net.zetetic:sqlcipher-android:4.14.1` via raw `SQLiteDatabase.openOrCreateDatabase` (Room on top would be overkill — mirror iOS GRDB approach with direct statements)
- FCM `com.google.firebase:firebase-messaging`
- io.getstream:stream-webrtc-android
- Android KeyStore + `EncryptedFile` (for DB master key) — no SharedPreferences, no UserDefaults
- ConnectionService (self-managed) + Foreground Service `phoneCall|microphone`
- FLAG_SECURE on MainActivity from day 1

**Conventions:** JSON wire format BYTE-identical to iOS (`ControlMessageType` strings, `_ctrl: true`, same field names). Pin tests MUST match iOS pins (`u+rYBk…` primary, `/AdS6h…` backup).

---

## Stages (mirror Phase 3 exactly)

| #  | iOS Phase 3 stage                     | Android equivalent                                                              |
|----|---------------------------------------|---------------------------------------------------------------------------------|
| 1  | project scaffolding                   | Gradle multi-module, `:app` AGP, AndroidManifest, empty MainActivity            |
| 2  | domain models                         | `Contact.kt`, `ChatMessage.kt`, `ControlMessage.kt`, `Room.kt`, `AppEnums.kt`   |
| 3  | security layer                        | `KeystoreService.kt`, `BiometricAuthService.kt`, `SecurityMonitor.kt`           |
| 4  | storage layer                         | `DatabaseService.kt` (SQLCipher), `ContactStore.kt`, `MessageStore.kt`          |
| 5  | crypto wrapper + identity             | `GhostChatCrypto.kt`, `IdentityKeyService.kt` (uses existing `:crypto`)         |
| 6  | network layer                         | `SignalingClient.kt` (OkHttp), `TURNService.kt`, `CertificatePinning.kt`        |
| 7  | WebRTC layer                          | `GhostRTC.kt`, `GhostVoice.kt` (stream-webrtc-android)                          |
| 8  | audio helpers                         | `SoundLibrary.kt`, `VoiceRecorder.kt`                                           |
| 9  | push                                  | `PushManager.kt`, `GhostFirebaseService.kt`, manifest entry                     |
| 10 | localization (EN + RU)                | `res/values/strings.xml` + `res/values-ru/strings.xml`, `LocalizationManager`   |
| 11 | managers                              | `ConnectionManager.kt`, `CallManager.kt` (ConnectionService), `MessageManager`, `ContactManager`, `SettingsManager` |
| 12 | Welcome screen                        | `WelcomeScreen.kt` + `WelcomeViewModel.kt`                                      |
| 13 | Chat screen                           | `ChatScreen.kt` + `ChatViewModel.kt` (≤ 300 LOC)                                |
| 14 | Call screens                          | `CallScreen.kt`, `IncomingCallScreen.kt`                                        |
| 15 | Contacts screens                      | `ContactsScreen.kt`, `ContactDetailScreen.kt`                                   |
| 16 | Settings + Lock + Security Dashboard  | `SettingsScreen.kt`, `LockScreen.kt`, `SecurityDashboardScreen.kt`              |
| 17 | App entry wiring                      | `GhostChatApp.kt` (Hilt), `MainActivity.kt`, deep link intent filter, ConnectionService registration |
| 18 | verify_phase_4.sh                     | Toolchain check, assembleDebug, unit tests, FLAG_SECURE scan, SQLCipher hexdump, pinning check |

Each stage ends with:
1. `./gradlew :app:assembleDebug` (or scoped for early stages) — green
2. `./gradlew :crypto:test` — still 21/21 green
3. `./gradlew :app:lintDebug` (after module exists) — no errors
4. `git add` + `git commit -m "feat(android): Phase 4 Stage N — <stage>"`

### Commit template
```
feat(android): Phase 4 Stage N — <stage>

<short what/why>

- :crypto tests still 21/21
- :app assembleDebug green
```

No `Co-Authored-By` — user rule.

---

## Success criteria (mirrors Phase 3)

- `./gradlew :app:assembleDebug` → BUILD SUCCESSFUL, produces `app-debug.apk`
- `./gradlew :crypto:test` → 21/21 still pass (no regressions)
- `./gradlew :app:testDebugUnitTest` → all unit tests pass
- `grep` AndroidManifest: `WindowManager.LayoutParams.FLAG_SECURE` applied in MainActivity
- No `SharedPreferences` usage for settings (everything in KeyStore-backed EncryptedFile)
- No `android.util.Log` usage that prints keys/ciphertext/decrypted text
- `CertificatePinner.Builder().add(host, "sha256/primary").add(host, "sha256/backup").build()` — exactly two pins, no fallback
- SQLCipher raw-file test passes: writes marker, closes DB, reads raw file bytes, asserts marker plaintext absent
- EN + RU strings.xml contain all 55 keys from iOS `Localizable.xcstrings`
- `verify_phase_4.sh` exits 0

## MANUAL VERIFICATION REQUIRED (cannot automate)

1. WebRTC peer-to-peer between iOS and Android devices
2. FCM push wakes app and launches incoming call UI
3. ConnectionService incoming call UI (system telecom surface)
4. Cross-platform voice call iOS ↔ Android

---

## Notes on choices vs. spec

- **Storage: raw SQLCipher (no Room).** Mirrors iOS GRDB-at-low-level — keeps schema visible in one file, easy to diff against iOS. Room would add `.kapt`/KSP overhead and abstract away statements we want to audit.
- **OkHttp CertificatePinner, not custom TrustManager.** OkHttp's `CertificatePinner` is SHA-256-of-SPKI by default, identical semantics to iOS SPKI pinning.
- **PushManager is OkHttp not Retrofit.** iOS uses URLSession directly — we stay 1:1.
- **Compose, not XML.** SwiftUI mirror → Jetpack Compose. Forbidden patterns scan targets Compose modifiers for FLAG_SECURE wrapper.
- **No kapt.** Hilt has a KSP processor (`com.google.dagger:hilt-android-compiler` via KSP); avoids kapt slowness.
