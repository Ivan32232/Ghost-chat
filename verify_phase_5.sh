#!/usr/bin/env bash
# Ghost Chat — Phase 5 verification (File Transfer + Voice Messages)
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

step() { STEP=$((STEP + 1)); echo; echo -e "${BOLD}[Phase 5 — step $STEP] $1${NC}"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}! $1${NC}"; }

abort_if_failed() {
    if [ $FAIL -ne 0 ]; then
        echo; echo -e "${RED}Phase 5 verification failed with $FAIL error(s).${NC}"
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
step "wire format: fileComplete carries sha256 on both platforms"
IOS_CTRL="$IOS_DIR/GhostChat/Models/ControlMessage.swift"
AND_CTRL="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/models/ControlMessage.kt"
if grep -q "case fileComplete(fileId: String, sha256: String)" "$IOS_CTRL"; then
    pass "iOS fileComplete(fileId, sha256) present"
else
    fail "iOS fileComplete signature missing sha256"
fi
if grep -q 'data class FileComplete(val fileId: String, val sha256: String)' "$AND_CTRL"; then
    pass "Android FileComplete(fileId, sha256) present"
else
    fail "Android FileComplete signature missing sha256"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "cross-platform SHA-256 test vector matches in both test files"
IOS_VEC=$(grep -oE '"[0-9a-f]{64}"' "$IOS_DIR/GhostChatTests/Files/FileTransferServiceTests.swift" \
          | grep -E "2e781e3762" | head -1)
AND_VEC=$(grep -oE '"[0-9a-f]{64}"' "$ANDROID_DIR/app/src/test/java/com/kordar/ghostchat/core/files/FileTransferServiceTest.kt" \
          | grep -E "2e781e3762" | head -1)
if [ -n "$IOS_VEC" ] && [ -n "$AND_VEC" ] && [ "$IOS_VEC" = "$AND_VEC" ]; then
    pass "shared SHA-256 vector: $IOS_VEC"
else
    echo "iOS=$IOS_VEC  Android=$AND_VEC"
    fail "cross-platform SHA-256 vector mismatch"
fi

# Also independently recompute the expected hash from the deterministic byte
# formula and confirm it's exactly what both tests assert on.
EXPECTED=$(node -e '
const b = Buffer.alloc(4000);
for (let i = 0; i < 4000; i++) b[i] = ((i * 31 + 7) & 0xff);
console.log(require("crypto").createHash("sha256").update(b).digest("hex"));
' 2>/dev/null)
if [ "\"$EXPECTED\"" = "$IOS_VEC" ]; then
    pass "Node recomputed sha256 matches committed vector"
else
    echo "node=$EXPECTED  committed=$IOS_VEC"
    fail "Node recomputation disagrees with committed sha256 vector"
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
step "iOS: full test suite (includes FileTransferServiceTests, FileCatalogTests, ControlMessageTests)"
FULL_LOG="$IOS_DIR/.phase5-full-test.log"

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
# Retry once if the first run fails purely due to a simulator launch flake.
if ! grep -q "Test Suite 'All tests' passed" "$FULL_LOG" && \
     grep -q "Application failed preflight checks" "$FULL_LOG"; then
    warn "simulator preflight flake — retrying after shutdown"
    if [ -n "${SIM_UDID:-}" ]; then
        xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
        xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
        xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
    fi
    run_ios_tests
fi

if grep -q "Test Suite 'All tests' passed" "$FULL_LOG"; then
    TOTAL=$(grep -oE "Executed [0-9]+ tests" "$FULL_LOG" | tail -1 | grep -oE "[0-9]+")
    FAILED=$(grep -oE "with [0-9]+ failures" "$FULL_LOG" | tail -1 | grep -oE "[0-9]+")
    if [ "${FAILED:-0}" -eq 0 ] && [ "${TOTAL:-0}" -gt 0 ]; then
        pass "iOS full test suite: $TOTAL executed, $FAILED failed"
    else
        fail "iOS full test suite: $TOTAL executed, $FAILED failed"
    fi
else
    grep -E "error:|failed:" "$FULL_LOG" | head -10
    fail "iOS full test suite did not complete cleanly"
fi

# Confirm the new Phase 5 test suites actually ran.
for suite in FileTransferServiceTests FileCatalogTests; do
    if grep -q "Test Suite '$suite' passed" "$FULL_LOG"; then
        N=$(grep -A1 "Test Suite '$suite' passed" "$FULL_LOG" | grep -oE "Executed [0-9]+ tests" | head -1 | grep -oE "[0-9]+")
        pass "iOS $suite ran (${N:-?} tests)"
    else
        fail "iOS $suite did not run"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "Android: :app:testDebugUnitTest (includes FileTransferServiceTest + FileCatalogTest)"
A_LOG="$ANDROID_DIR/.phase5-tests.log"
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
    if [ "$FAILED" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
        pass "Android :app:testDebugUnitTest — $TOTAL passed, $FAILED failed"
    else
        fail "Android :app:testDebugUnitTest — $TOTAL executed, $FAILED failed"
    fi
else
    tail -30 "$A_LOG"
    fail "Android :app:testDebugUnitTest did not build/run"
fi

# Confirm the two new suites ran.
if [ -f "$ANDROID_DIR/app/build/test-results/testDebugUnitTest/TEST-com.kordar.ghostchat.core.files.FileTransferServiceTest.xml" ]; then
    N=$(grep -oE 'tests="[0-9]+"' "$ANDROID_DIR/app/build/test-results/testDebugUnitTest/TEST-com.kordar.ghostchat.core.files.FileTransferServiceTest.xml" | head -1 | grep -oE "[0-9]+")
    pass "FileTransferServiceTest ran ($N tests)"
else
    fail "FileTransferServiceTest did not run"
fi
if [ -f "$ANDROID_DIR/app/build/test-results/testDebugUnitTest/TEST-com.kordar.ghostchat.core.files.FileCatalogTest.xml" ]; then
    N=$(grep -oE 'tests="[0-9]+"' "$ANDROID_DIR/app/build/test-results/testDebugUnitTest/TEST-com.kordar.ghostchat.core.files.FileCatalogTest.xml" | head -1 | grep -oE "[0-9]+")
    pass "FileCatalogTest ran ($N tests)"
else
    fail "FileCatalogTest did not run"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Android: :app:assembleDebug builds cleanly"
ASSEMBLE_LOG="$ANDROID_DIR/.phase5-assemble.log"
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
LINT_LOG="$ANDROID_DIR/.phase5-lint.log"
(cd "$ANDROID_DIR" && ./gradlew :app:lintDebug > "$LINT_LOG" 2>&1) || true
if grep -q "BUILD SUCCESSFUL" "$LINT_LOG"; then
    pass ":app:lintDebug passed"
else
    tail -30 "$LINT_LOG"
    fail ":app:lintDebug reported errors"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "chunk size + backpressure thresholds match spec (2 KiB raw, 16 KiB buffer)"
IOS_FT="$IOS_DIR/GhostChat/Core/Files/FileTransferService.swift"
AND_FT="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/files/FileTransferService.kt"
grep -q "chunkSize = 2048" "$IOS_FT"        && pass "iOS chunkSize = 2048" || fail "iOS chunkSize mismatch"
grep -q "CHUNK_SIZE: Int = 2048" "$AND_FT"  && pass "Android CHUNK_SIZE = 2048" || fail "Android CHUNK_SIZE mismatch"

IOS_CM="$IOS_DIR/GhostChat/Core/Managers/ConnectionManager.swift"
AND_CM="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/managers/ConnectionManager.kt"
grep -q "backpressureThresholdBytes: UInt64 = 16 \* 1024" "$IOS_CM" \
    && pass "iOS backpressureThreshold = 16 KiB" \
    || fail "iOS backpressureThreshold missing/wrong"
grep -q "BACKPRESSURE_THRESHOLD_BYTES: Long = 16L \* 1024" "$AND_CM" \
    && pass "Android BACKPRESSURE_THRESHOLD_BYTES = 16 KiB" \
    || fail "Android BACKPRESSURE_THRESHOLD_BYTES missing/wrong"

# ─────────────────────────────────────────────────────────────────────────────
step "voice recorder: AAC m4a, 44100 Hz mono, 64 kbps (spec)"
IOS_VR="$IOS_DIR/GhostChat/Core/Audio/VoiceRecorder.swift"
AND_VR="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/audio/VoiceRecorder.kt"
grep -q "sampleRate: Double = 44_100" "$IOS_VR" && pass "iOS sample rate 44100" || fail "iOS sample rate wrong"
grep -q "bitRate: Int = 64_000"      "$IOS_VR" && pass "iOS bit rate 64000"   || fail "iOS bit rate wrong"
grep -q "SAMPLE_RATE: Int = 44_100"   "$AND_VR" && pass "Android sample rate 44100" || fail "Android sample rate wrong"
grep -q "BIT_RATE: Int = 64_000"      "$AND_VR" && pass "Android bit rate 64000"   || fail "Android bit rate wrong"

# ─────────────────────────────────────────────────────────────────────────────
step "file-transfer control routing wired in ConnectionManagers"
grep -q "private func handleControl" "$IOS_CM" \
    && pass "iOS handleControl(_) routed" || fail "iOS handleControl missing"
grep -q "private suspend fun handleControl" "$AND_CM" \
    && pass "Android handleControl() routed" || fail "Android handleControl missing"
grep -q "fileContinuation" "$IOS_CM" \
    && pass "iOS incomingFile stream wired" || fail "iOS incomingFile stream missing"
grep -q "_incomingFile.tryEmit" "$AND_CM" \
    && pass "Android incomingFile flow wired" || fail "Android incomingFile flow missing"

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
step "supported MIME types catalog parity (iOS + Android)"
REQUIRED_MIMES=(
    "image/jpeg" "image/png" "image/gif" "image/heic" "image/webp"
    "video/mp4" "video/quicktime"
    "audio/mpeg" "audio/mp4" "audio/aac" "audio/wav"
    "application/pdf" "application/msword"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    "text/plain" "application/zip"
)
IOS_CAT="$IOS_DIR/GhostChat/Core/Files/FileCatalog.swift"
AND_CAT="$ANDROID_DIR/app/src/main/java/com/kordar/ghostchat/core/files/FileCatalog.kt"
for m in "${REQUIRED_MIMES[@]}"; do
    ios_ok=1; and_ok=1
    grep -F "\"$m\"" "$IOS_CAT" >/dev/null 2>&1 || ios_ok=0
    grep -F "\"$m\"" "$AND_CAT" >/dev/null 2>&1 || and_ok=0
    if [ "$ios_ok" -eq 1 ] && [ "$and_ok" -eq 1 ]; then
        pass "$m"
    else
        fail "$m missing (ios=$ios_ok android=$and_ok)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "forbidden patterns scan (Phase 5)"

# 1. No Log-ing of raw file bytes on Android.
if grep -rnE "Log\.(d|i|w|e).*fileBytes|Log\.(d|i|w|e).*chunkData" \
      "$ANDROID_DIR/app/src/main" > /tmp/phase5.log 2>/dev/null; then
    if [ -s /tmp/phase5.log ]; then
        cat /tmp/phase5.log
        fail "Android logs printing file bytes/chunk data detected"
    fi
else
    pass "no Log of raw file bytes/chunks on Android"
fi
rm -f /tmp/phase5.log

# 2. No print() of file bytes on iOS.
if grep -rnE "print\(.*fileBytes|print\(.*chunkData" "$IOS_DIR/GhostChat" > /tmp/phase5.print 2>/dev/null; then
    if [ -s /tmp/phase5.print ]; then
        cat /tmp/phase5.print
        fail "iOS print() of file bytes detected"
    fi
else
    pass "no print() of file bytes on iOS"
fi
rm -f /tmp/phase5.print

# ─────────────────────────────────────────────────────────────────────────────
step "summary"
if [ $FAIL -eq 0 ]; then
    echo
    echo -e "${GREEN}${BOLD}Phase 5 verification: PASSED${NC}"
    echo
    echo "MANUAL VERIFICATION REQUIRED (cannot automate):"
    echo "  - Attach a JPG on iOS, receive on Android (byte-identical)"
    echo "  - Attach a PDF on Android, receive on iOS (SHA-256 match)"
    echo "  - Hold-to-record voice message on either platform → playback on the other"
    echo "  - Pinch-to-zoom full-screen image viewer on both"
    echo "  - Backpressure observable on a 50+ MiB file (no OOM, no dropped chunks)"
    echo "  - file-retransmit path: drop chunks mid-flight, receiver recovers"
    echo
    exit 0
else
    echo
    echo -e "${RED}${BOLD}Phase 5 verification FAILED: $FAIL error(s).${NC}"
    echo
    exit 1
fi
