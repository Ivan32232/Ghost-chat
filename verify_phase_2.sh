#!/usr/bin/env bash
# verify_phase_2.sh — Phase 2 verification: cryptographic layer on iOS + Android.
#
# Runs in this order:
# 1. Regenerate test vectors (Node.js)
# 2. Sync test vectors to iOS and Android test resources
# 3. Cross-platform verification (JSON consistency + independent Node.js re-compute)
# 4. iOS XCTest (swift test)
# 5. Android JUnit (gradlew test)
#
# Exit code 0 ⇔ every step passed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# ---------- Pretty output ----------

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${BLUE}[verify_phase_2]${NC} %s\n" "$*"; }
pass() { printf "${GREEN}[PASS]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

section() {
  echo ""
  printf "${BLUE}=================================================================${NC}\n"
  printf "${BLUE}= %s${NC}\n" "$*"
  printf "${BLUE}=================================================================${NC}\n"
}

TOTAL=0
FAILED=0

run_step() {
  local name="$1"
  shift
  TOTAL=$((TOTAL + 1))
  log "→ $name"
  if "$@"; then
    pass "$name"
  else
    FAILED=$((FAILED + 1))
    fail "$name"
  fi
}

# ---------- Pre-flight ----------

section "Pre-flight checks"

command -v node >/dev/null 2>&1 || fail "node not installed"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not installed"

# OpenJDK 17 via brew
if [[ -d "$(brew --prefix openjdk@17 2>/dev/null)" ]]; then
  export JAVA_HOME="$(brew --prefix openjdk@17)"
  export PATH="$JAVA_HOME/bin:$PATH"
  log "Using JAVA_HOME=$JAVA_HOME"
else
  fail "openjdk@17 not installed (brew install openjdk@17)"
fi

swift --version | head -n 1 | sed 's/^/  swift: /'
java -version 2>&1 | head -n 1 | sed 's/^/  java:  /'
node --version | sed 's/^/  node:  /'

# ---------- Step 1: Regenerate test vectors ----------

section "Step 1: Regenerate test vectors"
run_step "generate-test-vectors" node scripts/generate-test-vectors.cjs

# ---------- Step 2: Sync to iOS + Android ----------

section "Step 2: Sync test vectors to iOS and Android test resources"

sync_vectors() {
  cp docs/test-vectors.json ios/Tests/GhostCryptoTests/test-vectors.json
  cp docs/test-vectors.json android/crypto/src/test/resources/test-vectors.json
}

run_step "sync-vectors" sync_vectors

# ---------- Step 3: Cross-platform consistency ----------

section "Step 3: Cross-platform consistency check"
run_step "cross-platform-verify" node scripts/verify-cross-platform.cjs

# ---------- Step 4: iOS XCTest ----------

section "Step 4: iOS tests (swift test)"

ios_test() {
  (cd ios && swift test 2>&1 | tee /tmp/ghost-chat-ios-test.log)
  local exit_code=${PIPESTATUS[0]}
  if [[ $exit_code -ne 0 ]]; then
    return $exit_code
  fi
  # Ensure at least N tests were executed
  local count=$(grep -c "' passed" /tmp/ghost-chat-ios-test.log || true)
  if [[ $count -lt 20 ]]; then
    echo "iOS: expected >=20 passing tests, got $count"
    return 1
  fi
  echo "iOS: $count tests passed"
}

run_step "ios-xctest" ios_test

# ---------- Step 5: Android JUnit ----------

section "Step 5: Android tests (gradlew test)"

android_test() {
  # --rerun-tasks forces real test execution so PASSED/FAILED lines print every run.
  (cd android && ./gradlew :crypto:test --rerun-tasks 2>&1 | tee /tmp/ghost-chat-android-test.log)
  local exit_code=${PIPESTATUS[0]}
  if [[ $exit_code -ne 0 ]]; then
    return $exit_code
  fi
  local passed=$(grep -c "PASSED" /tmp/ghost-chat-android-test.log || true)
  local failed=$(grep -c "FAILED" /tmp/ghost-chat-android-test.log || true)
  if [[ $failed -gt 0 ]]; then
    echo "Android: $failed failed tests"
    return 1
  fi
  if [[ $passed -lt 20 ]]; then
    echo "Android: expected >=20 passing tests, got $passed"
    return 1
  fi
  echo "Android: $passed tests passed"
}

run_step "android-junit" android_test

# ---------- Final summary ----------

section "Summary"

if [[ $FAILED -eq 0 ]]; then
  printf "${GREEN}✓ Phase 2 verification PASSED${NC}  ($TOTAL/$TOTAL steps)\n"
  printf "  iOS and Android crypto layers produce identical, test-vector-compliant output.\n"
  exit 0
else
  printf "${RED}✗ Phase 2 verification FAILED${NC}  ($FAILED/$TOTAL steps failed)\n"
  exit 1
fi
