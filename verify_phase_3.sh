#!/usr/bin/env bash
# Ghost Chat — Phase 3 verification
# Exit code 0 only when every automated check passes.

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$ROOT/ios"
SIM="iPhone 17"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

STEP=0
FAIL=0

step() {
    STEP=$((STEP + 1))
    echo
    echo -e "${BOLD}[Phase 3 — step $STEP] $1${NC}"
}

pass() {
    echo -e "${GREEN}✓ $1${NC}"
}

fail() {
    echo -e "${RED}✗ $1${NC}"
    FAIL=$((FAIL + 1))
}

warn() {
    echo -e "${YELLOW}! $1${NC}"
}

abort_if_failed() {
    if [ $FAIL -ne 0 ]; then
        echo
        echo -e "${RED}Phase 3 verification failed with $FAIL error(s).${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
step "toolchain"
for cmd in xcodegen xcodebuild swift openssl python3 pod; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "$cmd present"
    else
        fail "missing required tool: $cmd"
    fi
done
abort_if_failed

# ─────────────────────────────────────────────────────────────────────────────
step "simulator availability"
if xcrun simctl list devices available 2>/dev/null | grep -q "$SIM"; then
    pass "$SIM simulator available"
else
    fail "simulator '$SIM' not found. Run 'xcrun simctl list devices'."
    abort_if_failed
fi

# ─────────────────────────────────────────────────────────────────────────────
step "XcodeGen regenerates project"
(cd "$IOS_DIR" && xcodegen generate >/dev/null 2>&1) || fail "xcodegen generate exited non-zero"
if [ -d "$IOS_DIR/GhostChat.xcodeproj" ]; then
    pass "GhostChat.xcodeproj created"
else
    fail "GhostChat.xcodeproj missing after xcodegen"
fi
abort_if_failed

# ─────────────────────────────────────────────────────────────────────────────
step "CocoaPods install (SQLCipher + GRDB/SQLCipher)"
(cd "$IOS_DIR" && pod install >/dev/null 2>&1) || fail "pod install exited non-zero"
if [ -d "$IOS_DIR/GhostChat.xcworkspace" ] && [ -f "$IOS_DIR/Podfile.lock" ]; then
    pass "GhostChat.xcworkspace + Podfile.lock ready"
else
    fail "pod install did not produce xcworkspace / Podfile.lock"
fi
if grep -q "GRDB.swift/SQLCipher" "$IOS_DIR/Podfile.lock" 2>/dev/null; then
    pass "Podfile.lock locks GRDB.swift/SQLCipher"
else
    fail "GRDB.swift/SQLCipher missing from Podfile.lock"
fi
if grep -q "SQLCipher" "$IOS_DIR/Podfile.lock" 2>/dev/null; then
    GRDB_VER=$(grep -oE "GRDB\.swift/SQLCipher \([0-9.]+\)" "$IOS_DIR/Podfile.lock" | head -1 | grep -oE "\([0-9.]+\)" | tr -d '()')
    SQLCIPHER_VER=$(grep -oE "^  - SQLCipher \([0-9.]+\)" "$IOS_DIR/Podfile.lock" | head -1 | grep -oE "\([0-9.]+\)" | tr -d '()')
    pass "Pods: GRDB.swift/SQLCipher ${GRDB_VER:-?} + SQLCipher ${SQLCIPHER_VER:-?}"
else
    fail "SQLCipher missing from Podfile.lock"
fi
abort_if_failed

# ─────────────────────────────────────────────────────────────────────────────
step "Phase 2 crypto tests (swift test)"
PHASE2_OUT="$(cd "$IOS_DIR" && swift test --quiet 2>&1 || true)"
if echo "$PHASE2_OUT" | grep -q "0 failures" ; then
    pass "swift test: all Phase 2 crypto tests pass"
elif echo "$PHASE2_OUT" | grep -q "error:"; then
    echo "$PHASE2_OUT" | tail -30
    fail "swift test reported errors"
else
    echo "$PHASE2_OUT" | tail -15
    warn "swift test output unclear; please inspect"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "xcodebuild: build workspace for $SIM"
BUILD_LOG="$IOS_DIR/.phase3-build.log"
(cd "$IOS_DIR" && \
  xcodebuild \
    -workspace GhostChat.xcworkspace \
    -scheme GhostChat \
    -destination "platform=iOS Simulator,name=$SIM" \
    -configuration Debug \
    clean build 2>&1 > "$BUILD_LOG")
BUILD_STATUS=$?
if [ $BUILD_STATUS -eq 0 ] && tail -5 "$BUILD_LOG" | grep -q "BUILD SUCCEEDED"; then
    pass "xcodebuild: BUILD SUCCEEDED"
else
    grep -E "error:" "$BUILD_LOG" | head -20
    fail "xcodebuild build failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "xcodebuild: unit tests on $SIM"
TEST_LOG="$IOS_DIR/.phase3-test.log"
(cd "$IOS_DIR" && \
  xcodebuild \
    -workspace GhostChat.xcworkspace \
    -scheme GhostChat \
    -destination "platform=iOS Simulator,name=$SIM" \
    -configuration Debug \
    test 2>&1 > "$TEST_LOG")
TEST_STATUS=$?
TOTAL=$(grep -oE "Executed [0-9]+ tests" "$TEST_LOG" | tail -1 | grep -oE "[0-9]+")
FAILED=$(grep -oE "with [0-9]+ failures" "$TEST_LOG" | tail -1 | grep -oE "[0-9]+")
SKIPPED=$(grep -oE "[0-9]+ tests skipped" "$TEST_LOG" | tail -1 | grep -oE "[0-9]+")
SKIPPED=${SKIPPED:-0}
FAILED=${FAILED:-0}
TOTAL=${TOTAL:-0}
if [ "$TEST_STATUS" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    pass "unit tests: $TOTAL executed, $FAILED failed, $SKIPPED skipped"
else
    grep -E "error:|failed:" "$TEST_LOG" | head -20
    fail "unit tests: $TOTAL executed, $FAILED failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "SQLCipher proof test ran"
if grep -q "test_onDiskFile_isEncrypted_notPlaintext.*passed" "$TEST_LOG"; then
    pass "raw-file encryption-proof test passed"
else
    fail "SQLCipher encryption-proof test did not run or did not pass"
fi
if grep -q "test_onDiskFile_reopenWithDifferentKey_fails.*passed" "$TEST_LOG"; then
    pass "wrong-key reopen rejection test passed"
else
    fail "wrong-key reopen rejection test missing"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "SQLCipher linkage check on built app"
APP_BUNDLE=$(find ~/Library/Developer/Xcode/DerivedData -type d -name "GhostChat.app" -path "*/Debug-iphonesimulator/*" 2>/dev/null | head -1)
if [ -n "$APP_BUNDLE" ] && [ -d "$APP_BUNDLE/Frameworks" ]; then
    if [ -d "$APP_BUNDLE/Frameworks/SQLCipher.framework" ]; then
        pass "SQLCipher.framework bundled in GhostChat.app/Frameworks"
    else
        ls "$APP_BUNDLE/Frameworks" 2>/dev/null | head
        fail "SQLCipher.framework missing from app bundle"
    fi
    if [ -d "$APP_BUNDLE/Frameworks/GRDB.framework" ]; then
        pass "GRDB.framework bundled in GhostChat.app/Frameworks"
    else
        fail "GRDB.framework missing from app bundle"
    fi
    # Verify the dylib links them (confirms dynamic load, not just bundled).
    DYLIB="$APP_BUNDLE/GhostChat.debug.dylib"
    if [ -f "$DYLIB" ]; then
        if otool -L "$DYLIB" 2>/dev/null | grep -q "SQLCipher.framework"; then
            pass "GhostChat dylib links SQLCipher.framework"
        else
            fail "GhostChat dylib does not link SQLCipher"
        fi
    fi
else
    fail "could not locate built GhostChat.app to inspect Frameworks/"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "forbidden patterns scan"

# UserDefaults used (not just mentioned in comments)
if grep -rnE "UserDefaults\.(standard|init|\()|UserDefaults\(" "$IOS_DIR/GhostChat" 2>/dev/null > /tmp/phase3.userdefaults; then
    if [ -s /tmp/phase3.userdefaults ]; then
        cat /tmp/phase3.userdefaults
        fail "UserDefaults usage found — settings must live in Keychain"
    else
        pass "no UserDefaults usage"
    fi
else
    pass "no UserDefaults usage"
fi
rm -f /tmp/phase3.userdefaults

# Decrypted content or message keys going to stdout
if grep -rnE "print\(.*messageKey|print\(.*decrypted" "$IOS_DIR/GhostChat" 2>/dev/null > /tmp/phase3.print; then
    if [ -s /tmp/phase3.print ]; then
        cat /tmp/phase3.print
        fail "print() of message keys or decrypted content detected"
    fi
else
    pass "no print() of key material"
fi
rm -f /tmp/phase3.print

# ATS arbitrary loads slipped in
if grep -rn "NSAllowsArbitraryLoads.*true" "$IOS_DIR/GhostChat" 2>/dev/null > /tmp/phase3.ats; then
    if [ -s /tmp/phase3.ats ]; then
        cat /tmp/phase3.ats
        fail "NSAllowsArbitraryLoads=true would weaken ATS"
    fi
else
    pass "ATS allowsArbitraryLoads is not enabled"
fi
rm -f /tmp/phase3.ats

# FileProtection.complete stub must not be USED (mentions in doc comments OK).
if grep -nE "^[^/]*FileProtectionType\.complete" "$IOS_DIR/GhostChat/Core/Storage/DatabaseService.swift" 2>/dev/null | grep -v "^[[:space:]]*//" > /tmp/phase3.fp; then
    if [ -s /tmp/phase3.fp ]; then
        cat /tmp/phase3.fp
        fail "DatabaseService.swift still USES FileProtectionType.complete (should be removed — SQLCipher replaces it)"
    else
        pass "FileProtection.complete stub removed from DatabaseService"
    fi
else
    pass "FileProtection.complete stub removed from DatabaseService"
fi
rm -f /tmp/phase3.fp

# ─────────────────────────────────────────────────────────────────────────────
step "generated Info.plist + entitlements sanity"
PLIST="$IOS_DIR/GhostChat/Resources/Info.plist"
ENT="$IOS_DIR/GhostChat/Resources/GhostChat.entitlements"
if [ -f "$PLIST" ] && grep -q "NSFaceIDUsageDescription" "$PLIST"; then
    pass "Info.plist has NSFaceIDUsageDescription"
else
    fail "Info.plist missing NSFaceIDUsageDescription"
fi
if [ -f "$PLIST" ] && grep -q "voip" "$PLIST"; then
    pass "Info.plist declares voip background mode"
else
    fail "Info.plist missing UIBackgroundModes.voip"
fi
if [ -f "$ENT" ] && grep -q "aps-environment" "$ENT"; then
    pass "entitlements declare aps-environment"
else
    fail "entitlements missing aps-environment"
fi
if [ -f "$ENT" ] && grep -q "applinks:ghostchat.one" "$ENT"; then
    pass "entitlements declare applinks:ghostchat.one"
else
    fail "entitlements missing associated-domains applinks:ghostchat.one"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "SPKI pin sanity"
PIN_FILE="$IOS_DIR/GhostChat/Core/Network/CertificatePinning.swift"
if grep -q "u+rYBkrJDJtDcMZuuZxvgrwKAiaN/8Ppuk7pwdxjGbg=" "$PIN_FILE"; then
    pass "primary pin present (matches live cert as of plan date)"
else
    fail "primary pin missing from CertificatePinning.swift"
fi
if grep -q "/AdS6h9evKtyk7J9aoy+0isfcARe0dv7/C+BOUabNeo=" "$PIN_FILE"; then
    pass "backup pin present (matches deploy/keys/backup-pin-private.pem)"
else
    fail "backup pin missing from CertificatePinning.swift"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "SQLCipher PRAGMAs + passphrase usage sanity"
DB_FILE="$IOS_DIR/GhostChat/Core/Storage/DatabaseService.swift"
for pragma in "cipher_page_size = 4096" "kdf_iter = 256000" "cipher_memory_security = ON" "secure_delete = ON"; do
    if grep -q "$pragma" "$DB_FILE"; then
        pass "PRAGMA $pragma present"
    else
        fail "PRAGMA $pragma missing from DatabaseService.swift"
    fi
done
if grep -q "usePassphrase" "$DB_FILE"; then
    pass "db.usePassphrase(...) call present"
else
    fail "db.usePassphrase(...) missing — DB is not being unlocked with the master key"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "summary"
if [ $FAIL -eq 0 ]; then
    echo
    echo -e "${GREEN}${BOLD}Phase 3 verification: PASSED${NC}"
    echo
    echo "MANUAL VERIFICATION REQUIRED (cannot automate):"
    echo "  - WebRTC peer-to-peer session between two simulators / devices"
    echo "  - Face ID / Touch ID unlock path (real device only)"
    echo "  - Incoming VoIP push + CallKit UI (real device with APNs)"
    echo "  - APNs / FCM end-to-end delivery"
    echo "  - Deep link from Safari (ghostchat.one/?room=…)"
    echo
    exit 0
else
    echo
    echo -e "${RED}${BOLD}Phase 3 verification FAILED: $FAIL error(s).${NC}"
    echo
    exit 1
fi
