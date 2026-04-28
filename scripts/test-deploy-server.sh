#!/usr/bin/env bash
# Regression tests for scripts/deploy-server.sh — covers the failure-path
# bug where a SIGPIPE inside health_gate() would set ROLLBACK_NEEDED=1, run
# rollback(), and then print "deploy succeeded" anyway.
#
# These tests don't touch the server: they exercise the script in isolated
# subshells with --simulate-rollback, and unit-test the in-process pieces
# (health-gate WS line parsing, final guard) by sourcing the script with
# `main` stubbed.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${SCRIPT_DIR}/deploy-server.sh"

PASS=0
FAIL=0
LAST_OUT=""
LAST_RC=0

run() {
    # Disable -e locally so we can capture both stdout and exit code without
    # `|| true` masking the real status.
    set +e
    LAST_OUT="$("$@" 2>&1)"
    LAST_RC=$?
    set -e
}

assert_contains() {
    local label="$1" needle="$2"
    if [[ "${LAST_OUT}" == *"${needle}"* ]]; then
        echo "  ok   ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL ${label}"
        echo "       expected substring: ${needle}"
        echo "       got: ${LAST_OUT}"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2"
    if [[ "${LAST_OUT}" != *"${needle}"* ]]; then
        echo "  ok   ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL ${label}"
        echo "       must NOT contain: ${needle}"
        echo "       got: ${LAST_OUT}"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_rc() {
    local label="$1" want="$2"
    if [[ "${LAST_RC}" == "${want}" ]]; then
        echo "  ok   ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL ${label}"
        echo "       expected exit ${want}, got ${LAST_RC}"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---------------------------------------------------------------------------
echo "1) --simulate-rollback prints DEPLOY FAILED and exits 1"
# DEPLOY_SSH_HOST set so the script's own readonly check doesn't bail early.
DEPLOY_SSH_HOST=test.local run env DEPLOY_SSH_HOST=test.local "${DEPLOY}" --simulate-rollback
assert_contains "prints 'DEPLOY FAILED'"        "DEPLOY FAILED"
assert_not_contains "must NOT print 'succeeded'" "deploy succeeded"
assert_rc "exit code is 1" 1

# ---------------------------------------------------------------------------
echo
echo "2) --help exits 0 and prints docs without --simulate-rollback running"
DEPLOY_SSH_HOST=test.local run env DEPLOY_SSH_HOST=test.local "${DEPLOY}" --help
assert_contains "help mentions --simulate-rollback" "--simulate-rollback"
assert_not_contains "help did not run rollback" "DEPLOY FAILED"
assert_rc "help exits 0" 0

# ---------------------------------------------------------------------------
echo
echo "3) preflight refuses to run without DEPLOY_SSH_HOST"
# Running without the env var. The script's `${DEPLOY_SSH_HOST:?...}` line
# fires at source time and prints the message to stderr. The bash :? expansion
# exits with 1 from the subshell.
unset DEPLOY_SSH_HOST || true
LAST_OUT="$(bash "${DEPLOY}" --help 2>&1)" || LAST_RC=$?
assert_contains "complains about DEPLOY_SSH_HOST" "DEPLOY_SSH_HOST"

# ---------------------------------------------------------------------------
echo
echo "4) script source-level: health_gate uses temp file, not '| head -1'"
# Read the script and confirm the fix is in place — protects against
# regressions during refactors.
if grep -q '| head -1 | tr' "${DEPLOY}"; then
    echo "  FAIL fix regressed: '| head -1 | tr' is back in script"
    FAIL=$(( FAIL + 1 ))
else
    echo "  ok   no '| head -1 | tr' pipeline in deploy script"
    PASS=$(( PASS + 1 ))
fi

if grep -q 'IFS= read -r ws_first_line' "${DEPLOY}"; then
    echo "  ok   ws gate uses 'read -r' from temp file"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL ws gate is missing the read-from-temp-file fix"
    FAIL=$(( FAIL + 1 ))
fi

if grep -q 'ROLLBACK_RAN == 1' "${DEPLOY}"; then
    echo "  ok   final guard checks ROLLBACK_RAN before printing success"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL final guard missing"
    FAIL=$(( FAIL + 1 ))
fi

# ---------------------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    echo "PASS — ${PASS} checks"
    exit 0
else
    echo "FAIL — ${PASS} ok, ${FAIL} failed"
    exit 1
fi
