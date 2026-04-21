#!/usr/bin/env bash
# Ghost Chat — Phase 6 verification (Security Hardening).
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

step() { STEP=$((STEP + 1)); echo; echo -e "${BOLD}[Phase 6 — step $STEP] $1${NC}"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}! $1${NC}"; }

abort_if_failed() {
    if [ $FAIL -ne 0 ]; then
        echo; echo -e "${RED}Phase 6 verification failed with $FAIL error(s).${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
step "toolchain"
for cmd in xcodegen xcodebuild swift openssl pod adb node; do
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
step "new Phase-6 modules present on both platforms"

IOS_PAIRS=(
    "ContactKeyRotation:$IOS_DIR/GhostChat/Core/Crypto/ContactKeyRotation.swift"
    "ReplayGuard:$IOS_DIR/GhostChat/Core/Crypto/ReplayGuard.swift"
    "PostQuantum:$IOS_DIR/GhostChat/Core/Crypto/PostQuantum.swift"
    "JailbreakDetector:$IOS_DIR/GhostChat/Core/Security/JailbreakDetector.swift"
    "SecureWipe:$IOS_DIR/GhostChat/Core/Security/SecureWipe.swift"
    "ChunkTimeoutTracker:$IOS_DIR/GhostChat/Core/Files/ChunkTimeoutTracker.swift"
)
for pair in "${IOS_PAIRS[@]}"; do
    name="${pair%%:*}"
    path="${pair#*:}"
    if [ -f "$path" ]; then
        pass "iOS $name present"
    else
        fail "iOS $name missing at $path"
    fi
done

AND_PAIRS=(
    "ContactKeyRotation:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/ContactKeyRotation.kt"
    "ReplayGuard:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/ReplayGuard.kt"
    "PostQuantum:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/PostQuantum.kt"
    "RootDetector:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/security/RootDetector.kt"
    "SecureWipe:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/security/SecureWipe.kt"
    "ChunkTimeoutTracker:$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/files/ChunkTimeoutTracker.kt"
)
for pair in "${AND_PAIRS[@]}"; do
    name="${pair%%:*}"
    path="${pair#*:}"
    if [ -f "$path" ]; then
        pass "Android $name present"
    else
        fail "Android $name missing at $path"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "BouncyCastle 1.82 + RootBeer on Android classpath"
BUILD="$ANDROID_DIR/app/build.gradle.kts"
grep -q 'bcprov-jdk18on:1.82' "$BUILD" && pass "bcprov 1.82 pinned" \
    || fail "bcprov 1.82 not pinned"
grep -q 'rootbeer-lib' "$BUILD" && pass "rootbeer present" \
    || fail "rootbeer not present"
grep -q 'bcprov-jdk18on:1.82' "$ANDROID_DIR/crypto/build.gradle.kts" \
    && pass "bcprov 1.82 pinned (crypto module)" \
    || fail "bcprov 1.82 not pinned in crypto module"

# ─────────────────────────────────────────────────────────────────────────────
step "cross-platform test vectors regenerated + Node-verified"
(cd "$ROOT" && node scripts/generate-test-vectors.cjs >/dev/null) \
    && pass "generate-test-vectors.cjs ran cleanly" \
    || fail "generator failed"
cp "$ROOT/docs/test-vectors.json" "$ROOT/ios/Tests/GhostCryptoTests/test-vectors.json"
cp "$ROOT/docs/test-vectors.json" "$ROOT/android/crypto/src/test/resources/test-vectors.json"
(cd "$ROOT" && node scripts/verify-cross-platform.cjs) \
    && pass "cross-platform sha256 identical across all three copies" \
    || fail "cross-platform vectors diverged"

# ─────────────────────────────────────────────────────────────────────────────
step "Phase-6 HKDF vectors self-consistent with Node"
EXPECTED_ROT=$(node -e '
const c = require("crypto");
const shared = Buffer.alloc(32, 0xAA);
console.log(c.hkdfSync("sha256", shared, Buffer.from("ghost-rot-v1"), Buffer.from("ghost-rot-seed"), 32) |> buf => Buffer.from(buf).toString("hex"));
' 2>/dev/null || node -e '
const c = require("crypto");
const shared = Buffer.alloc(32, 0xAA);
console.log(Buffer.from(c.hkdfSync("sha256", shared, Buffer.from("ghost-rot-v1"), Buffer.from("ghost-rot-seed"), 32)).toString("hex"));
')
if grep -q "\"derivedSeed\": \"$EXPECTED_ROT\"" "$ROOT/docs/test-vectors.json"; then
    pass "contactRotation.derivedSeed matches Node reference ($EXPECTED_ROT)"
else
    fail "contactRotation.derivedSeed != Node HKDF"
fi

EXPECTED_PQ=$(node -e '
const c = require("crypto");
const ecdh = Buffer.alloc(32, 0xAB);
const pq = Buffer.alloc(32, 0xCD);
console.log(Buffer.from(c.hkdfSync("sha256", Buffer.concat([ecdh, pq]), Buffer.from("ghost-chat-v1-pq"), Buffer.from("ghost-dr-root"), 32)).toString("hex"));
')
if grep -q "\"combinedWithPQ\": \"$EXPECTED_PQ\"" "$ROOT/docs/test-vectors.json"; then
    pass "pqHybrid.combinedWithPQ matches Node reference ($EXPECTED_PQ)"
else
    fail "pqHybrid.combinedWithPQ != Node HKDF"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "iOS: xcodegen + pod install"
(cd "$IOS_DIR" && xcodegen generate >/dev/null 2>&1) || fail "xcodegen failed"
(cd "$IOS_DIR" && pod install >/dev/null 2>&1) || fail "pod install failed"
[ -d "$IOS_DIR/GhostChat.xcworkspace" ] || fail "workspace missing"
[ -f "$IOS_DIR/Podfile.lock" ] || fail "Podfile.lock missing"
abort_if_failed
pass "iOS project regenerated and pods installed"

# ─────────────────────────────────────────────────────────────────────────────
step "iOS: swift test (GhostCrypto SPM — DoubleRatchet/currentRootKey addition)"
SWIFT_LOG="$IOS_DIR/.phase6-swift.log"
(cd "$IOS_DIR" && swift test >"$SWIFT_LOG" 2>&1) || true
if grep -q "Executed 21 tests, with 0 failures" "$SWIFT_LOG"; then
    pass "GhostCrypto SPM tests: 21/21 pass"
else
    grep -E "error:|failed" "$SWIFT_LOG" | head -10
    fail "GhostCrypto SPM tests did not report 21/21"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "iOS: full xctest suite (includes all Phase-6 new suites)"
FULL_LOG="$IOS_DIR/.phase6-full-test.log"

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
    if [ "${FAILED:-0}" -eq 0 ] && [ "${TOTAL:-0}" -ge 250 ]; then
        pass "iOS full test suite: $TOTAL executed, 0 failed"
    else
        fail "iOS full test suite: $TOTAL executed, ${FAILED:-?} failed"
    fi
else
    grep -E "error:|failed:" "$FULL_LOG" | head -10
    fail "iOS full test suite did not complete cleanly"
fi

# Confirm every new Phase-6 suite actually ran.
for suite in ContactKeyRotationTests ReplayGuardTests PostQuantumTests \
             JailbreakDetectorTests SecureWipeTests ChunkTimeoutTrackerTests; do
    if grep -q "Test Suite '$suite' passed" "$FULL_LOG"; then
        N=$(grep -A1 "Test Suite '$suite' passed" "$FULL_LOG" \
            | grep -oE "Executed [0-9]+ tests" | head -1 | grep -oE "[0-9]+")
        pass "iOS $suite ran (${N:-?} tests)"
    else
        fail "iOS $suite did not run"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "Android: :crypto:test (regression baseline after BC 1.82 bump)"
C_LOG="$ANDROID_DIR/.phase6-crypto.log"
(cd "$ANDROID_DIR" && ./gradlew :crypto:test --rerun-tasks > "$C_LOG" 2>&1) || true
if grep -q "BUILD SUCCESSFUL" "$C_LOG"; then
    pass "Android :crypto:test BUILD SUCCESSFUL"
else
    tail -30 "$C_LOG"
    fail "Android :crypto:test did not build/run"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Android: :app:testDebugUnitTest (incl. every new Phase-6 suite)"
A_LOG="$ANDROID_DIR/.phase6-tests.log"
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
    if [ "$FAILED" -eq 0 ] && [ "$TOTAL" -ge 180 ]; then
        pass "Android :app:testDebugUnitTest — $TOTAL passed, 0 failed"
    else
        fail "Android :app:testDebugUnitTest — $TOTAL executed, $FAILED failed"
    fi
else
    tail -30 "$A_LOG"
    fail "Android :app:testDebugUnitTest did not build/run"
fi

for suite in \
    com.kordar.ghostchat.core.crypto.ContactKeyRotationTest \
    com.kordar.ghostchat.core.crypto.ReplayGuardTest \
    com.kordar.ghostchat.core.crypto.PostQuantumTest \
    com.kordar.ghostchat.core.security.RootDetectorTest \
    com.kordar.ghostchat.core.security.SecureWipeTest \
    com.kordar.ghostchat.core.files.ChunkTimeoutTrackerTest \
    com.kordar.ghostchat.core.managers.ContactManagerRotationTest
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
ASSEMBLE_LOG="$ANDROID_DIR/.phase6-assemble.log"
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
step "Android: lint clean"
LINT_LOG="$ANDROID_DIR/.phase6-lint.log"
(cd "$ANDROID_DIR" && ./gradlew :app:lintDebug > "$LINT_LOG" 2>&1) || true
if grep -q "BUILD SUCCESSFUL" "$LINT_LOG"; then
    pass ":app:lintDebug passed"
else
    tail -30 "$LINT_LOG"
    fail ":app:lintDebug reported errors"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "wire + protocol invariants (Phase 6 carries-over Phase 5 + adds fields)"

IOS_CTRL="$IOS_DIR/GhostChat/Models/ControlMessage.swift"
AND_CTRL="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/models/ControlMessage.kt"
grep -q "case fileComplete(fileId: String, sha256: String)" "$IOS_CTRL" \
    && pass "iOS fileComplete(fileId, sha256)" \
    || fail "iOS fileComplete signature drift"
grep -q 'data class FileComplete(val fileId: String, val sha256: String)' "$AND_CTRL" \
    && pass "Android FileComplete(fileId, sha256)" \
    || fail "Android FileComplete signature drift"

IOS_KEX="$IOS_DIR/GhostChat/Core/Crypto/GhostCrypto.swift"
AND_KEX="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/KeyExchangePacket.kt"
grep -q 'pqKey' "$IOS_KEX" && pass "iOS KeyExchangePacket carries pqKey" || fail "iOS pqKey missing"
grep -q 'pqSupported' "$IOS_KEX" && pass "iOS KeyExchangePacket carries pqSupported" || fail "iOS pqSupported missing"
grep -q 'pqKey' "$AND_KEX" && pass "Android KeyExchangePacket carries pqKey" || fail "Android pqKey missing"
grep -q 'pqSupported' "$AND_KEX" && pass "Android KeyExchangePacket carries pqSupported" || fail "Android pqSupported missing"

# ─────────────────────────────────────────────────────────────────────────────
step "chunk timeout + backpressure invariants"

IOS_FT="$IOS_DIR/GhostChat/Core/Files/FileTransferService.swift"
AND_FT="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/files/FileTransferService.kt"
grep -q "chunkSize = 2048" "$IOS_FT"        && pass "iOS chunkSize = 2048" || fail "iOS chunkSize mismatch"
grep -q "CHUNK_SIZE: Int = 2048" "$AND_FT"  && pass "Android CHUNK_SIZE = 2048" || fail "Android CHUNK_SIZE mismatch"

IOS_CT="$IOS_DIR/GhostChat/Core/Files/ChunkTimeoutTracker.swift"
AND_CT="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/files/ChunkTimeoutTracker.kt"
grep -q "defaultTimeout: TimeInterval = 30.0" "$IOS_CT" \
    && pass "iOS ChunkTimeoutTracker default timeout = 30s" \
    || fail "iOS timeout drift"
grep -q "DEFAULT_TIMEOUT_MS: Long = 30_000L" "$AND_CT" \
    && pass "Android ChunkTimeoutTracker default timeout = 30_000 ms" \
    || fail "Android timeout drift"
grep -q "defaultMaxRetries: Int = 3" "$IOS_CT" \
    && pass "iOS max retries = 3" \
    || fail "iOS maxRetries drift"
grep -q "DEFAULT_MAX_RETRIES: Int = 3" "$AND_CT" \
    && pass "Android max retries = 3" \
    || fail "Android maxRetries drift"

IOS_CM="$IOS_DIR/GhostChat/Core/Managers/ConnectionManager.swift"
AND_CM="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/managers/ConnectionManager.kt"
grep -q 'chunkTimeout.arm(fileId:' "$IOS_CM" \
    && pass "iOS ConnectionManager arms chunk timer on fileStart" \
    || fail "iOS chunkTimeout.arm wiring missing"
grep -q 'chunkTimeout.arm(ctrl.fileId)' "$AND_CM" \
    && pass "Android ConnectionManager arms chunk timer on fileStart" \
    || fail "Android chunkTimeout.arm wiring missing"

# ─────────────────────────────────────────────────────────────────────────────
step "ReplayGuard wired into GhostChatCrypto.decrypt on both sides"
grep -q 'replayGuard.admit' "$IOS_DIR/GhostChat/Core/Crypto/GhostCrypto.swift" \
    && pass "iOS decrypt() calls ReplayGuard.admit" \
    || fail "iOS ReplayGuard not wired"
grep -q 'replayGuard.admit' "$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/crypto/GhostChatCrypto.kt" \
    && pass "Android decrypt() calls ReplayGuard.admit" \
    || fail "Android ReplayGuard not wired"

# ─────────────────────────────────────────────────────────────────────────────
step "SecureWipe wired into DatabaseService.deleteFile on both sides"
grep -q 'SecureWipe.wipeDatabase' "$IOS_DIR/GhostChat/Core/Storage/DatabaseService.swift" \
    && pass "iOS DatabaseService.deleteFile → SecureWipe.wipeDatabase" \
    || fail "iOS DatabaseService not using SecureWipe"
grep -q 'SecureWipe.wipeDatabase' "$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/storage/DatabaseService.kt" \
    && pass "Android DatabaseService.deleteFile → SecureWipe.wipeDatabase" \
    || fail "Android DatabaseService not using SecureWipe"

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
step "forbidden patterns scan (Phase 6 — secrets never in logs)"

# Grep for Log* or print* statements naming secret fields.
rg_ios_hits=0
rg_and_hits=0
PATTERNS="messageKey|ratchetState|pqSharedSecret|rotation_?seed|sessionSecret|privateKey"

if grep -rnE "print\(.*(${PATTERNS})" "$IOS_DIR/GhostChat" 2>/dev/null | \
     grep -v '@testable' | grep -v 'Tests.swift' > /tmp/phase6.ios 2>/dev/null; then
    if [ -s /tmp/phase6.ios ]; then
        cat /tmp/phase6.ios
        rg_ios_hits=1
    fi
fi
[ "$rg_ios_hits" -eq 0 ] && pass "iOS: no print() of key material" \
    || fail "iOS leaks key material via print()"
rm -f /tmp/phase6.ios

if grep -rnE "Log\.(d|i|w|e)\(.*(${PATTERNS})" "$ANDROID_DIR/app/src/main" 2>/dev/null > /tmp/phase6.and 2>/dev/null; then
    if [ -s /tmp/phase6.and ]; then
        cat /tmp/phase6.and
        rg_and_hits=1
    fi
fi
[ "$rg_and_hits" -eq 0 ] && pass "Android: no Log.* of key material" \
    || fail "Android leaks key material via Log.*"
rm -f /tmp/phase6.and

# ─────────────────────────────────────────────────────────────────────────────
step "summary"
if [ $FAIL -eq 0 ]; then
    echo
    echo -e "${GREEN}${BOLD}Phase 6 verification: PASSED${NC}"
    echo
    echo "MANUAL VERIFICATION REQUIRED (cannot automate):"
    echo "  - Real-device jailbreak / root detection sanity check"
    echo "  - Full ML-KEM768 handshake over signaling once protocol"
    echo "    bump lands (Phase 7 integration — wire format is already"
    echo "    reserved; PostQuantum module is fully functional on"
    echo "    Android and in-place on iOS with iOS 26+ gated stubs)"
    echo "  - Contact key rotation across an actual session teardown"
    echo "    (Android currently covered by unit mock; iOS unit +"
    echo "    in-memory integration)"
    echo "  - Per-chunk timeout under adverse network conditions (packet"
    echo "    loss, high jitter)"
    echo
    exit 0
else
    echo
    echo -e "${RED}${BOLD}Phase 6 verification FAILED: $FAIL error(s).${NC}"
    echo
    exit 1
fi
