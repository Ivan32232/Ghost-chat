#!/usr/bin/env bash
# Ghost Chat — Phase 4 Android verification
# Exit code 0 only when every automated check passes.

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ANDROID_DIR="$ROOT/android"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

STEP=0
FAIL=0

step() { STEP=$((STEP + 1)); echo; echo -e "${BOLD}[Phase 4 — step $STEP] $1${NC}"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}! $1${NC}"; }

abort_if_failed() {
    if [ $FAIL -ne 0 ]; then
        echo; echo -e "${RED}Phase 4 verification failed with $FAIL error(s).${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
step "toolchain"
if [ -x "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/javac" ]; then
    export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
    pass "openjdk@17 present at $JAVA_HOME"
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
    pass "JAVA_HOME is $JAVA_HOME"
else
    fail "Java 17 JDK not found (brew install openjdk@17)"
fi

if [ -d "$HOME/Android/sdk" ]; then
    export ANDROID_HOME="$HOME/Android/sdk"
    pass "ANDROID_HOME set to $ANDROID_HOME"
elif [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME" ]; then
    pass "ANDROID_HOME is $ANDROID_HOME"
else
    fail "Android SDK not found (install via Android Studio SDK Manager)"
fi

for cmd in adb; do
    command -v "$cmd" >/dev/null 2>&1 && pass "$cmd present" || fail "missing $cmd"
done
abort_if_failed

cd "$ANDROID_DIR"

# ─────────────────────────────────────────────────────────────────────────────
step "Phase 2 crypto tests (:crypto:test, 21 original + new DoubleRatchetState)"
CRYPTO_LOG="$ANDROID_DIR/.phase4-crypto.log"
if ./gradlew :crypto:test --rerun-tasks > "$CRYPTO_LOG" 2>&1; then
    PASSED=$(grep -oE "PASSED" "$CRYPTO_LOG" | wc -l | tr -d ' ')
    FAILED=$(grep -oE "FAILED" "$CRYPTO_LOG" | wc -l | tr -d ' ')
    if [ "${FAILED:-0}" -eq 0 ] && [ "${PASSED:-0}" -ge 21 ]; then
        pass ":crypto:test — $PASSED passed, $FAILED failed (≥ 21 expected)"
    else
        tail -40 "$CRYPTO_LOG"
        fail ":crypto:test — $PASSED passed, $FAILED failed"
    fi
else
    tail -40 "$CRYPTO_LOG"
    fail ":crypto:test did not complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
step ":app:assembleDebug produces app-debug.apk"
BUILD_LOG="$ANDROID_DIR/.phase4-build.log"
if ./gradlew :app:assembleDebug > "$BUILD_LOG" 2>&1; then
    if [ -f "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk" ]; then
        SZ=$(wc -c < "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk" | tr -d ' ')
        pass "app-debug.apk produced (${SZ} bytes)"
    else
        fail "assembleDebug passed but APK missing"
    fi
else
    grep -E "error:" "$BUILD_LOG" | head -20
    fail ":app:assembleDebug failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
step ":app:testDebugUnitTest"
TEST_LOG="$ANDROID_DIR/.phase4-tests.log"
if ./gradlew :app:testDebugUnitTest > "$TEST_LOG" 2>&1; then
    TOTAL=0; FAILED=0
    for f in "$ANDROID_DIR"/app/build/test-results/testDebugUnitTest/TEST-*.xml; do
        [ -f "$f" ] || continue
        t=$(grep -oE 'tests="[0-9]+"' "$f" | head -1 | grep -oE "[0-9]+")
        fl=$(grep -oE 'failures="[0-9]+"' "$f" | head -1 | grep -oE "[0-9]+")
        TOTAL=$((TOTAL + ${t:-0}))
        FAILED=$((FAILED + ${fl:-0}))
    done
    if [ "$FAILED" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
        pass ":app:testDebugUnitTest — $TOTAL passed, $FAILED failed"
    else
        tail -30 "$TEST_LOG"
        fail ":app:testDebugUnitTest — $TOTAL executed, $FAILED failed"
    fi
else
    tail -30 "$TEST_LOG"
    fail ":app:testDebugUnitTest did not complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
step ":app:lintDebug (no errors)"
LINT_LOG="$ANDROID_DIR/.phase4-lint.log"
if ./gradlew :app:lintDebug > "$LINT_LOG" 2>&1; then
    pass ":app:lintDebug passed"
else
    tail -30 "$LINT_LOG"
    fail ":app:lintDebug reported errors"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "FLAG_SECURE applied in MainActivity"
MAIN_ACTIVITY="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/MainActivity.kt"
if grep -q "WindowManager.LayoutParams.FLAG_SECURE" "$MAIN_ACTIVITY"; then
    pass "MainActivity sets FLAG_SECURE on its window"
else
    fail "MainActivity does not set FLAG_SECURE"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Certificate pinning: exactly primary + backup, no fallback"
PIN_FILE="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/network/CertificatePinning.kt"
if grep -q 'PRIMARY_PIN = "u+rYBkrJDJtDcMZuuZxvgrwKAiaN/8Ppuk7pwdxjGbg="' "$PIN_FILE"; then
    pass "primary pin matches iOS (u+rYBk…)"
else
    fail "primary pin mismatched or missing"
fi
if grep -q 'BACKUP_PIN  = "/AdS6h9evKtyk7J9aoy+0isfcARe0dv7/C+BOUabNeo="' "$PIN_FILE"; then
    pass "backup pin matches iOS (/AdS6h…)"
else
    fail "backup pin mismatched or missing"
fi
PIN_COUNT=$(grep -cE "^ *const val .*_PIN" "$PIN_FILE")
if [ "$PIN_COUNT" -eq 2 ]; then
    pass "exactly 2 pins declared (no fallback)"
else
    fail "expected 2 pins, found $PIN_COUNT"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "SQLCipher PRAGMAs (cipher_page_size / kdf_iter / memory_security / secure_delete)"
DB_FILE="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/storage/DatabaseService.kt"
for pragma in "cipher_page_size = 4096" "kdf_iter = 256000" "cipher_memory_security = ON" "secure_delete = ON"; do
    if grep -q "$pragma" "$DB_FILE"; then
        pass "PRAGMA $pragma present"
    else
        fail "PRAGMA $pragma missing"
    fi
done
if grep -q "System.loadLibrary(\"sqlcipher\")" "$DB_FILE"; then
    pass "SQLCipher native library load call present"
else
    fail "SQLCipher library load missing"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "no SharedPreferences usage for settings"
if grep -rnE "getSharedPreferences|PreferenceManager\.getDefaultSharedPreferences" \
      "$ANDROID_DIR/app/src/main" > /tmp/phase4.sp 2>/dev/null; then
    if [ -s /tmp/phase4.sp ]; then
        cat /tmp/phase4.sp
        fail "SharedPreferences found — settings must live in KeystoreService"
    fi
else
    pass "no SharedPreferences usage"
fi
rm -f /tmp/phase4.sp

# ─────────────────────────────────────────────────────────────────────────────
step "no Log printing of keys or decrypted content"
if grep -rnE "Log\.(d|i|w|e).*messageKey|Log\.(d|i|w|e).*decrypted|Log\.(d|i|w|e).*plaintext" \
      "$ANDROID_DIR/app/src/main" > /tmp/phase4.log 2>/dev/null; then
    if [ -s /tmp/phase4.log ]; then
        cat /tmp/phase4.log
        fail "Log.* prints of keys / decrypted content detected"
    fi
else
    pass "no Log prints of key material or decrypted text"
fi
rm -f /tmp/phase4.log

# ─────────────────────────────────────────────────────────────────────────────
step "AndroidManifest: allowBackup=false, usesCleartextTraffic=false, POST_NOTIFICATIONS + MANAGE_OWN_CALLS"
MANIFEST="$ANDROID_DIR/app/src/main/AndroidManifest.xml"
grep -q 'android:allowBackup="false"' "$MANIFEST" \
    && pass 'allowBackup="false"' || fail 'allowBackup is not false'
grep -q 'android:usesCleartextTraffic="false"' "$MANIFEST" \
    && pass 'usesCleartextTraffic="false"' || fail 'usesCleartextTraffic not false'
grep -q 'android.permission.POST_NOTIFICATIONS' "$MANIFEST" \
    && pass 'POST_NOTIFICATIONS permission present' || fail 'POST_NOTIFICATIONS missing'
grep -q 'android.permission.MANAGE_OWN_CALLS' "$MANIFEST" \
    && pass 'MANAGE_OWN_CALLS permission present' || fail 'MANAGE_OWN_CALLS missing'
grep -q 'android.intent.action.VIEW' "$MANIFEST" \
    && pass 'VIEW intent filters declared (deep links)' || fail 'VIEW intent filters missing'
grep -q 'applicationId = "com.kordar.ghostchat"' "$ANDROID_DIR/app/build.gradle.kts" \
    && pass 'applicationId com.kordar.ghostchat' || fail 'applicationId mismatch'

# ─────────────────────────────────────────────────────────────────────────────
step "localization keys count (EN + RU)"
EN_COUNT=$(grep -cE "<string " "$ANDROID_DIR/app/src/main/res/values/strings.xml" 2>/dev/null || echo 0)
RU_COUNT=$(grep -cE "<string " "$ANDROID_DIR/app/src/main/res/values-ru/strings.xml" 2>/dev/null || echo 0)
if [ "$EN_COUNT" -ge 58 ] && [ "$RU_COUNT" -ge 58 ]; then
    pass "EN strings=$EN_COUNT, RU strings=$RU_COUNT (iOS parity ≥ 58)"
else
    fail "EN strings=$EN_COUNT, RU strings=$RU_COUNT — expected ≥ 58 on both"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "ChatViewModel ≤ 300 LOC"
CHAT_VM="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/features/chat/ChatViewModel.kt"
LOC=$(wc -l < "$CHAT_VM" | tr -d ' ')
if [ "$LOC" -le 300 ]; then
    pass "ChatViewModel.kt is $LOC lines (≤ 300)"
else
    fail "ChatViewModel.kt is $LOC lines (must be ≤ 300)"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "all :app Kotlin files ≤ 400 LOC"
OVER=$(find "$ANDROID_DIR/app/src/main/java" -name "*.kt" -exec wc -l {} \; 2>/dev/null \
    | awk '$1 > 400 { print $1"\t"$2 }')
if [ -z "$OVER" ]; then
    pass "no .kt file exceeds 400 LOC"
else
    echo "$OVER"
    fail "file(s) exceeding 400 LOC — split them"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "optional: instrumented SQLCipher proof (requires connected device/emulator)"
DEVICES=$(adb devices 2>/dev/null | grep -cE "device$" || true)
if [ "${DEVICES:-0}" -gt 0 ]; then
    INSTR_LOG="$ANDROID_DIR/.phase4-instr.log"
    if ./gradlew :app:connectedDebugAndroidTest \
           -Pandroid.testInstrumentationRunnerArguments.class=com.kordar.ghostchat.core.storage.DatabaseServiceAndroidTest \
           > "$INSTR_LOG" 2>&1; then
        pass "SQLCipher instrumented tests passed on connected device"
    else
        tail -30 "$INSTR_LOG"
        warn "instrumented tests did not pass (run manually once emulator is running)"
    fi
else
    warn "no adb device/emulator connected — skipping instrumented SQLCipher proof"
    warn "MANUAL VERIFICATION REQUIRED: :app:connectedDebugAndroidTest with device online"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "summary"
if [ $FAIL -eq 0 ]; then
    echo
    echo -e "${GREEN}${BOLD}Phase 4 verification: PASSED${NC}"
    echo
    echo "MANUAL VERIFICATION REQUIRED (cannot automate):"
    echo "  - WebRTC peer-to-peer session iOS ↔ Android"
    echo "  - FCM push wakes the app & launches incoming-call UI"
    echo "  - ConnectionService incoming call surface (real device)"
    echo "  - Cross-platform voice call iOS ↔ Android"
    echo "  - SQLCipher raw-file encryption proof on emulator"
    echo "    (./gradlew :app:connectedDebugAndroidTest)"
    echo "  - Biometric unlock + decoy PIN + 10-fail panic wipe"
    echo
    exit 0
else
    echo
    echo -e "${RED}${BOLD}Phase 4 verification FAILED: $FAIL error(s).${NC}"
    echo
    exit 1
fi
