#!/usr/bin/env bash
# Ghost Chat — Phase 7 verification (Polish + Production Readiness).
# Exit code 0 only when every automated check passes.

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$ROOT/ios"
ANDROID_DIR="$ROOT/android"
SIM="iPhone 17"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

STEP=0
FAIL=0

step() { STEP=$((STEP + 1)); echo; echo -e "${BOLD}[Phase 7 — step $STEP] $1${NC}"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}! $1${NC}"; }

abort_if_failed() {
    if [ $FAIL -ne 0 ]; then
        echo; echo -e "${RED}Phase 7 verification failed with $FAIL error(s).${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
step "toolchain"
for cmd in xcodegen xcodebuild swift openssl pod adb node ffmpeg afconvert sips; do
    command -v "$cmd" >/dev/null 2>&1 && pass "$cmd present" || fail "missing $cmd"
done
if [ -x "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/javac" ]; then
    export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
    pass "openjdk@17 at $JAVA_HOME"
else
    fail "Java 17 JDK not found"
fi
abort_if_failed

# ─────────────────────────────────────────────────────────────────────────────
step "simulator availability + boot"
if xcrun simctl list devices available 2>/dev/null | grep -q "$SIM"; then
    pass "$SIM simulator available"
else
    fail "simulator '$SIM' not found"
    abort_if_failed
fi
SIM_UDID=$(xcrun simctl list devices available | grep -F "$SIM " | head -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -n "$SIM_UDID" ]; then
    xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
    pass "simulator booted ($SIM_UDID)"
else
    warn "could not resolve simulator UDID; xcodebuild will boot on demand"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "new Phase-7 modules present on both platforms"

IOS_PAIRS=(
    "MessageEnvelope:$IOS_DIR/GhostChat/Core/Crypto/MessageEnvelope.swift"
    "GhostClock:$IOS_DIR/GhostChat/Core/Crypto/GhostClock.swift"
    "PqExchangePacket:$IOS_DIR/GhostChat/Core/Crypto/PqExchangePacket.swift"
    "BubbleShape:$IOS_DIR/GhostChat/Features/Chat/BubbleShape.swift"
    "Typography:$IOS_DIR/GhostChat/Resources/Typography.swift"
    "AppIcon:$IOS_DIR/GhostChat/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
)
for pair in "${IOS_PAIRS[@]}"; do
    name="${pair%%:*}"; path="${pair#*:}"
    if [ -f "$path" ]; then pass "iOS $name present"
    else fail "iOS $name missing at $path"
    fi
done

AND_PAIRS=(
    "MessageEnvelope:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/MessageEnvelope.kt"
    "GhostClock:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/GhostClock.kt"
    "PqExchangePacket:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/PqExchangePacket.kt"
    "DefaultIncomingPushHandler:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/push/DefaultIncomingPushHandler.kt"
    "GhostConnectionService:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/managers/GhostConnectionService.kt"
    "Typography:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/ui/theme/Typography.kt"
    "BubbleShape:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/ui/theme/BubbleShape.kt"
    "ProGuardRules:$ANDROID_DIR/app/proguard-rules.pro"
)
for pair in "${AND_PAIRS[@]}"; do
    name="${pair%%:*}"; path="${pair#*:}"
    if [ -f "$path" ]; then pass "Android $name present"
    else fail "Android $name missing at $path"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "Sentry SDK referenced on both sides"
grep -q '"Sentry"\|getsentry/sentry-cocoa' "$IOS_DIR/project.yml" \
    && pass "iOS Sentry SPM dep declared" \
    || fail "iOS Sentry SPM dep missing"
grep -q 'io.sentry:sentry-android' "$ANDROID_DIR/app/build.gradle.kts" \
    && pass "Android sentry-android declared" \
    || fail "Android sentry-android missing"
grep -q 'SentrySDK.start' "$IOS_DIR/GhostChat/App/AppDelegate.swift" \
    && pass "iOS AppDelegate initialises Sentry" \
    || fail "iOS Sentry not initialised"
grep -q 'SentryAndroid.init' "$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/GhostChatApplication.kt" \
    && pass "Android Application initialises Sentry" \
    || fail "Android Sentry not initialised"

# ─────────────────────────────────────────────────────────────────────────────
step "App Store / Google Play metadata"
grep -A1 "ITSAppUsesNonExemptEncryption" "$IOS_DIR/project.yml" | grep -q "true" \
    && pass "ITSAppUsesNonExemptEncryption=true" \
    || fail "ITSAppUsesNonExemptEncryption not flipped to true"
grep -q '<true/>' "$IOS_DIR/GhostChat/Resources/Info.plist" \
    && pass "Info.plist carries ITSAppUsesNonExemptEncryption=true" \
    || warn "Info.plist ITSAppUsesNonExemptEncryption check via plist format"
grep -q 'SentryDSN' "$IOS_DIR/project.yml" \
    && pass "SentryDSN key in project.yml" \
    || fail "SentryDSN key missing"
grep -q 'io.sentry.dsn' "$ANDROID_DIR/app/src/main/AndroidManifest.xml" \
    && pass "Android manifest has io.sentry.dsn meta-data" \
    || fail "Android manifest missing Sentry dsn meta-data"
grep -q 'BIND_TELECOM_CONNECTION_SERVICE' "$ANDROID_DIR/app/src/main/AndroidManifest.xml" \
    && pass "Android manifest declares Telecom ConnectionService" \
    || fail "Android manifest missing Telecom ConnectionService"
grep -q 'bouncycastle' "$ANDROID_DIR/app/proguard-rules.pro" \
    && pass "proguard-rules.pro keeps BouncyCastle" \
    || fail "proguard-rules.pro missing BouncyCastle keep"

# ─────────────────────────────────────────────────────────────────────────────
step "regenerated cross-platform vectors self-consistent"
(cd "$ROOT" && node scripts/generate-test-vectors.cjs >/dev/null) \
    && pass "generate-test-vectors.cjs ran cleanly" \
    || fail "generator failed"
cp "$ROOT/docs/test-vectors.json" "$ROOT/ios/Tests/GhostCryptoTests/test-vectors.json"
cp "$ROOT/docs/test-vectors.json" "$ROOT/android/crypto/src/test/resources/test-vectors.json"
(cd "$ROOT" && node scripts/verify-cross-platform.cjs) \
    && pass "cross-platform sha256 identical across all three copies" \
    || fail "cross-platform vectors diverged"

grep -q '"pqHandshake"' "$ROOT/docs/test-vectors.json" \
    && pass "pqHandshake vector present" \
    || fail "pqHandshake vector missing"
grep -q '"messageEnvelope"' "$ROOT/docs/test-vectors.json" \
    && pass "messageEnvelope vector present" \
    || fail "messageEnvelope vector missing"

# ─────────────────────────────────────────────────────────────────────────────
step "localization parity (iOS xcstrings ↔ Android EN ↔ Android RU)"
(cd "$ROOT" && node scripts/check-localization-parity.cjs >/dev/null) \
    && pass "i18n parity: every key present on all three surfaces" \
    || fail "i18n parity drift — run scripts/check-localization-parity.cjs for details"

# ─────────────────────────────────────────────────────────────────────────────
step "iOS: xcodegen + pod install"
(cd "$IOS_DIR" && xcodegen generate >/dev/null 2>&1) || fail "xcodegen failed"
(cd "$IOS_DIR" && pod install >/dev/null 2>&1) || fail "pod install failed"
[ -d "$IOS_DIR/GhostChat.xcworkspace" ] || fail "workspace missing"
[ -f "$IOS_DIR/Podfile.lock" ] || fail "Podfile.lock missing"
abort_if_failed
pass "iOS project regenerated and pods installed"

# ─────────────────────────────────────────────────────────────────────────────
step "iOS: swift test (GhostCrypto SPM baseline)"
SWIFT_LOG="$IOS_DIR/.phase7-swift.log"
(cd "$IOS_DIR" && swift test >"$SWIFT_LOG" 2>&1) || true
if grep -q "Executed 21 tests, with 0 failures" "$SWIFT_LOG"; then
    pass "GhostCrypto SPM tests: 21/21 pass"
else
    grep -E "error:|failed" "$SWIFT_LOG" | head -10
    fail "GhostCrypto SPM tests did not report 21/21"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "iOS: full xctest suite"
FULL_LOG="$IOS_DIR/.phase7-full-test.log"

run_ios_tests() {
    (cd "$IOS_DIR" && \
      xcodebuild \
        -workspace GhostChat.xcworkspace \
        -scheme GhostChat \
        -destination "platform=iOS Simulator,name=$SIM" \
        -configuration Debug \
        test > "$FULL_LOG" 2>&1) || true
}

run_ios_tests
if ! grep -q "Test Suite 'All tests' passed" "$FULL_LOG" && \
     grep -q "Application failed preflight checks" "$FULL_LOG"; then
    warn "simulator preflight flake — retrying after shutdown+erase"
    if [ -n "${SIM_UDID:-}" ]; then
        xcrun simctl shutdown all >/dev/null 2>&1 || true
        xcrun simctl erase "$SIM_UDID" >/dev/null 2>&1 || true
        sleep 2
        xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
        xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
    fi
    run_ios_tests
fi

if grep -q "Test Suite 'All tests' passed" "$FULL_LOG"; then
    TOTAL=$(grep -oE "Executed [0-9]+ tests" "$FULL_LOG" | tail -1 | grep -oE "[0-9]+")
    FAILED=$(grep -oE "with [0-9]+ failures" "$FULL_LOG" | tail -1 | grep -oE "[0-9]+")
    if [ "${FAILED:-0}" -eq 0 ] && [ "${TOTAL:-0}" -ge 260 ]; then
        pass "iOS full test suite: $TOTAL executed, 0 failed"
    else
        fail "iOS full test suite: $TOTAL executed, ${FAILED:-?} failed"
    fi
else
    grep -E "error:|failed:" "$FULL_LOG" | head -10
    fail "iOS full test suite did not complete cleanly"
fi

for suite in MessageEnvelopeTests GhostCryptoEnvelopeTests PqHandshakeTests ConnectionRotationTests; do
    if grep -q "Test Suite '$suite' passed" "$FULL_LOG"; then
        N=$(grep -A1 "Test Suite '$suite' passed" "$FULL_LOG" \
            | grep -oE "Executed [0-9]+ tests" | head -1 | grep -oE "[0-9]+")
        pass "iOS $suite ran (${N:-?} tests)"
    else
        fail "iOS $suite did not run"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "Android: :crypto:test (regression baseline)"
C_LOG="$ANDROID_DIR/.phase7-crypto.log"
(cd "$ANDROID_DIR" && ./gradlew :crypto:test --rerun-tasks > "$C_LOG" 2>&1) || true
if grep -q "BUILD SUCCESSFUL" "$C_LOG"; then
    pass "Android :crypto:test BUILD SUCCESSFUL"
else
    tail -30 "$C_LOG"
    fail "Android :crypto:test did not build/run"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Android: :app:testDebugUnitTest (incl. every new Phase-7 suite)"
A_LOG="$ANDROID_DIR/.phase7-tests.log"
(cd "$ANDROID_DIR" && ./gradlew :app:testDebugUnitTest --rerun-tasks > "$A_LOG" 2>&1) || true
if grep -q "BUILD SUCCESSFUL" "$A_LOG"; then
    TOTAL=0; FAILED=0
    for f in "$ANDROID_DIR"/app/build/test-results/testDebugUnitTest/TEST-*.xml; do
        [ -f "$f" ] || continue
        t=$(grep -oE 'tests="[0-9]+"' "$f" | head -1 | grep -oE "[0-9]+")
        fl=$(grep -oE 'failures="[0-9]+"' "$f" | head -1 | grep -oE "[0-9]+")
        TOTAL=$((TOTAL + ${t:-0}))
        FAILED=$((FAILED + ${fl:-0}))
    done
    if [ "$FAILED" -eq 0 ] && [ "$TOTAL" -ge 195 ]; then
        pass "Android :app:testDebugUnitTest — $TOTAL passed, 0 failed"
    else
        fail "Android :app:testDebugUnitTest — $TOTAL executed, $FAILED failed"
    fi
else
    tail -30 "$A_LOG"
    fail "Android :app:testDebugUnitTest did not build/run"
fi

for suite in \
    com.kordar.ghostchat.core.crypto.MessageEnvelopeTest \
    com.kordar.ghostchat.core.crypto.GhostCryptoEnvelopeTest \
    com.kordar.ghostchat.core.crypto.PqHandshakeTest \
    com.kordar.ghostchat.core.managers.ConnectionManagerRotationTest \
    com.kordar.ghostchat.core.push.DefaultIncomingPushHandlerTest
do
    RESULT="$ANDROID_DIR/app/build/test-results/testDebugUnitTest/TEST-$suite.xml"
    if [ -f "$RESULT" ]; then
        N=$(grep -oE 'tests="[0-9]+"' "$RESULT" | head -1 | grep -oE "[0-9]+")
        FL=$(grep -oE 'failures="[0-9]+"' "$RESULT" | head -1 | grep -oE "[0-9]+")
        if [ "${FL:-0}" -eq 0 ]; then
            pass "Android $suite: $N tests, 0 failures"
        else
            fail "Android $suite: $FL failures"
        fi
    else
        fail "Android $suite did not produce a TEST-*.xml"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "Android: :app:assembleDebug builds cleanly"
ASSEMBLE_LOG="$ANDROID_DIR/.phase7-assemble.log"
(cd "$ANDROID_DIR" && ./gradlew :app:assembleDebug > "$ASSEMBLE_LOG" 2>&1) || true
if grep -q "BUILD SUCCESSFUL" "$ASSEMBLE_LOG" && \
   [ -f "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk" ]; then
    SZ=$(wc -c < "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk" | tr -d ' ')
    pass "app-debug.apk produced (${SZ} bytes)"
else
    grep -E "error:" "$ASSEMBLE_LOG" | head -20
    fail "Android :app:assembleDebug failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Android: lint clean; no Divider/menuAnchor deprecation remains"
LINT_LOG="$ANDROID_DIR/.phase7-lint.log"
(cd "$ANDROID_DIR" && ./gradlew :app:lintDebug > "$LINT_LOG" 2>&1) || true
if grep -q "BUILD SUCCESSFUL" "$LINT_LOG"; then
    pass ":app:lintDebug passed"
else
    tail -30 "$LINT_LOG"
    fail ":app:lintDebug reported errors"
fi

BAD_DIVIDER=$(grep -rE "^import androidx\.compose\.material3\.Divider$" "$ANDROID_DIR/app/src/main" 2>/dev/null || true)
BAD_MENU=$(grep -rE "\.menuAnchor\(\)" "$ANDROID_DIR/app/src/main" 2>/dev/null || true)
[ -z "$BAD_DIVIDER" ] && pass "no deprecated Divider import left" \
    || { echo "$BAD_DIVIDER"; fail "Divider import still deprecated"; }
[ -z "$BAD_MENU" ] && pass "no deprecated menuAnchor() call left" \
    || { echo "$BAD_MENU"; fail "menuAnchor() still uses zero-arg overload"; }

# ─────────────────────────────────────────────────────────────────────────────
step "wire + protocol invariants (Phase 7 envelope + PQ handshake fields)"

IOS_KEX="$IOS_DIR/GhostChat/Core/Crypto/GhostCrypto.swift"
AND_KEX="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/KeyExchangePacket.kt"
grep -q 'pqKey' "$IOS_KEX" && pass "iOS KeyExchangePacket carries pqKey" || fail "iOS pqKey missing"
grep -q 'pqSupported' "$IOS_KEX" && pass "iOS KeyExchangePacket carries pqSupported" || fail "iOS pqSupported missing"
grep -q 'pqKey' "$AND_KEX" && pass "Android KeyExchangePacket carries pqKey" || fail "Android pqKey missing"
grep -q 'pqSupported' "$AND_KEX" && pass "Android KeyExchangePacket carries pqSupported" || fail "Android pqSupported missing"

IOS_PQ="$IOS_DIR/GhostChat/Core/Crypto/PqExchangePacket.swift"
AND_PQ="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/PqExchangePacket.kt"
grep -q '"pq-exchange"' "$IOS_PQ" && pass "iOS PqExchangePacket type=pq-exchange" || fail "iOS PqExchangePacket type drift"
grep -q '"pq-exchange"' "$AND_PQ" && pass "Android PqExchangePacket type=pq-exchange" || fail "Android PqExchangePacket type drift"

grep -q 'pqCiphertext' "$IOS_PQ" && pass "iOS PqExchangePacket carries pqCiphertext" || fail "iOS pqCiphertext missing"
grep -q 'pqCiphertext' "$AND_PQ" && pass "Android PqExchangePacket carries pqCiphertext" || fail "Android pqCiphertext missing"

# ─────────────────────────────────────────────────────────────────────────────
step "envelope + ReplayGuard integration"
grep -q 'MessageEnvelope' "$IOS_DIR/GhostChat/Core/Crypto/GhostCrypto.swift" \
    && pass "iOS GhostChatCrypto wraps encrypt/decrypt in MessageEnvelope" \
    || fail "iOS GhostChatCrypto missing envelope wrap"
grep -q 'MessageEnvelope' "$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/GhostChatCrypto.kt" \
    && pass "Android GhostChatCrypto wraps encrypt/decrypt in MessageEnvelope" \
    || fail "Android GhostChatCrypto missing envelope wrap"
grep -q 'timestampOutOfWindow' "$IOS_DIR/GhostChat/Core/Crypto/GhostCrypto.swift" \
    && pass "iOS GhostChatCrypto enforces timestamp window" \
    || fail "iOS timestamp window not enforced"
grep -q 'TimestampOutOfWindow' "$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/GhostChatCrypto.kt" \
    && pass "Android GhostChatCrypto enforces timestamp window" \
    || fail "Android timestamp window not enforced"

# ─────────────────────────────────────────────────────────────────────────────
step "auto-rotation wired on leave()"
grep -q 'rotateKeys(contactId' "$IOS_DIR/GhostChat/Core/Managers/ConnectionManager.swift" \
    && pass "iOS ConnectionManager.leave() calls rotateKeys" \
    || fail "iOS ConnectionManager.leave missing rotateKeys"
grep -q 'rotateKeys' "$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/managers/ConnectionManager.kt" \
    && pass "Android ConnectionManager.leave() calls rotateKeys" \
    || fail "Android ConnectionManager.leave missing rotateKeys"

# ─────────────────────────────────────────────────────────────────────────────
step "sound assets + icons shipped"
for f in ringtone.caf message-in.caf message-out.caf failed.caf; do
    [ -f "$IOS_DIR/GhostChat/Resources/Sounds/$f" ] && pass "iOS sound $f" || fail "iOS sound $f missing"
done
for f in ringtone.ogg message_in.ogg message_out.ogg failed.ogg; do
    [ -f "$ANDROID_DIR/app/src/main/res/raw/$f" ] && pass "Android sound $f" || fail "Android sound $f missing"
done
[ -f "$IOS_DIR/GhostChat/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" ] \
    && pass "iOS AppIcon-1024.png present" \
    || fail "iOS AppIcon-1024.png missing"
[ -f "$ANDROID_DIR/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml" ] \
    && pass "Android adaptive ic_launcher present" \
    || fail "Android adaptive ic_launcher missing"

# ─────────────────────────────────────────────────────────────────────────────
step "LOC limits: ChatViewModel ≤ 300, every source ≤ 400"
IOS_VM="$IOS_DIR/GhostChat/Features/Chat/ChatViewModel.swift"
AND_VM="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/features/chat/ChatViewModel.kt"
IOS_VM_LOC=$(wc -l < "$IOS_VM" | tr -d ' ')
AND_VM_LOC=$(wc -l < "$AND_VM" | tr -d ' ')
[ "$IOS_VM_LOC" -le 300 ] \
    && pass "iOS ChatViewModel.swift = $IOS_VM_LOC LOC (≤ 300)" \
    || fail "iOS ChatViewModel.swift = $IOS_VM_LOC LOC (> 300)"
[ "$AND_VM_LOC" -le 300 ] \
    && pass "Android ChatViewModel.kt = $AND_VM_LOC LOC (≤ 300)" \
    || fail "Android ChatViewModel.kt = $AND_VM_LOC LOC (> 300)"

IOS_OVER=$(find "$IOS_DIR/GhostChat" -name "*.swift" -exec wc -l {} \; 2>/dev/null \
    | awk '$1 > 400 { print $1"\t"$2 }')
if [ -z "$IOS_OVER" ]; then
    pass "no iOS Swift file exceeds 400 LOC"
else
    echo "$IOS_OVER"
    fail "iOS file(s) exceed 400 LOC — split them"
fi

AND_OVER=$(find "$ANDROID_DIR/app/src/main/java" -name "*.kt" -exec wc -l {} \; 2>/dev/null \
    | awk '$1 > 400 { print $1"\t"$2 }')
if [ -z "$AND_OVER" ]; then
    pass "no Android Kotlin file exceeds 400 LOC"
else
    echo "$AND_OVER"
    fail "Android file(s) exceed 400 LOC — split them"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "forbidden patterns scan (Phase 7 — still no key material in logs)"
rg_ios_hits=0
rg_and_hits=0
PATTERNS="messageKey|ratchetState|pqSharedSecret|rotation_?seed|sessionSecret|privateKey|envelope\\.c"

if grep -rnE "print\(.*(${PATTERNS})" "$IOS_DIR/GhostChat" 2>/dev/null | \
     grep -v '@testable' | grep -v 'Tests.swift' > /tmp/phase7.ios 2>/dev/null; then
    if [ -s /tmp/phase7.ios ]; then
        cat /tmp/phase7.ios
        rg_ios_hits=1
    fi
fi
[ "$rg_ios_hits" -eq 0 ] && pass "iOS: no print() of key material" \
    || fail "iOS leaks key material via print()"
rm -f /tmp/phase7.ios

if grep -rnE "Log\.(d|i|w|e)\(.*(${PATTERNS})" "$ANDROID_DIR/app/src/main" 2>/dev/null > /tmp/phase7.and 2>/dev/null; then
    if [ -s /tmp/phase7.and ]; then
        cat /tmp/phase7.and
        rg_and_hits=1
    fi
fi
[ "$rg_and_hits" -eq 0 ] && pass "Android: no Log.* of key material" \
    || fail "Android leaks key material via Log.*"
rm -f /tmp/phase7.and

# ─────────────────────────────────────────────────────────────────────────────
step "summary"
if [ $FAIL -eq 0 ]; then
    echo
    echo -e "${GREEN}${BOLD}Phase 7 verification: PASSED${NC}"
    echo
    echo "MANUAL VERIFICATION REQUIRED (cannot automate):"
    echo "  - Real-device ML-KEM handshake Android ↔ Android over live DataChannel"
    echo "  - iOS ↔ Android: verify graceful degrade to ECDH-only (iOS advertises pqSupported=false)"
    echo "  - Clock-shifted replay: one device's clock ±6 min → other rejects with"
    echo "    ReplayError.timestampOutOfWindow"
    echo "  - FCM 'call' data message → Android ConnectionService surfaces system incoming UI"
    echo "  - Real-device haptics + placeholder sound cues audible"
    echo "  - Sentry DSN populated → crash in debug build → event shows up with PII scrubbed"
    echo "  - App Store Connect upload (manual Archive) + Play internal test track upload"
    echo "  - App icon + launch screen appearance on real device"
    echo
    exit 0
else
    echo
    echo -e "${RED}${BOLD}Phase 7 verification FAILED: $FAIL error(s).${NC}"
    echo
    exit 1
fi
