#!/usr/bin/env bash
# Ghost Chat v2 — production deploy (Phase 1 server)
# Usage: ./scripts/deploy-server.sh [--yes]
#
# - Selective rsync: server/ + Dockerfile + nginx.conf + docker-compose.yml.
# - Never touches: .env, keys/, ssl/, certbot/, landing files, existing backups.
# - Snapshots previous image + configs on server before switching.
# - Rolls back automatically on health-gate failure.
set -Eeuo pipefail

# --- config ----------------------------------------------------------------
# Repository root = script directory parent.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Load deploy secrets (SSH_HOST, SSH_USER, SSH_KEY, optionally DOMAIN) from
# .env.deploy in repo root — gitignored. See .env.deploy.example for the template.
if [[ -f "${REPO_ROOT}/.env.deploy" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${REPO_ROOT}/.env.deploy"; set +a
fi

readonly SSH_USER="${DEPLOY_SSH_USER:-root}"
readonly SSH_HOST="${DEPLOY_SSH_HOST:?set DEPLOY_SSH_HOST in .env.deploy or env var}"
readonly SSH_KEY="${DEPLOY_SSH_KEY:-${HOME}/.ssh/digitalocean_key}"
readonly DOMAIN="${DEPLOY_DOMAIN:-ghostchat.one}"
readonly REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/root/kordar/deploy}"
# Docker build context in compose.yml is ".." relative to deploy/, i.e. /root/kordar/.
# Dockerfile.ghost-chat does `COPY server/...`, so code must live at /root/kordar/server/.
readonly REMOTE_SRC_ROOT="${DEPLOY_REMOTE_SRC_ROOT:-/root/kordar}"
readonly REMOTE_LANDING_DIR="${REMOTE_DIR}/ghostchat-www"
readonly HEALTH_URL="https://${DOMAIN}/health"
readonly WS_URL="https://${DOMAIN}/ws"
readonly LANDING_URL="https://${DOMAIN}/"
readonly HEALTH_RETRIES=12
readonly HEALTH_BACKOFF_SEC=5

# Colors (only if stdout is a TTY).
if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi

log()  { printf '%s[deploy]%s %s\n' "${C_DIM}" "${C_RST}" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n'   "${C_OK}"  "${C_RST}" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "${C_WARN}" "${C_RST}" "$*"; }
err()  { printf '%s[fail]%s %s\n'   "${C_ERR}" "${C_RST}" "$*" 1>&2; }

# Derived at runtime.
TIMESTAMP=""
ROLLBACK_NEEDED=0
ROLLBACK_RAN=0

ssh_cmd() { ssh -i "${SSH_KEY}" -o ConnectTimeout=20 -o ServerAliveInterval=10 "${SSH_USER}@${SSH_HOST}" "$@"; }
ssh_script() { ssh -i "${SSH_KEY}" -o ConnectTimeout=20 -o ServerAliveInterval=10 "${SSH_USER}@${SSH_HOST}" bash -s; }

confirm() {
    if [[ "${AUTO_YES:-0}" == "1" ]]; then return 0; fi
    printf 'Continue? [y/N] '
    read -r ans
    [[ "${ans}" == "y" || "${ans}" == "Y" ]]
}

# --- preflight -------------------------------------------------------------
preflight_local() {
    log "preflight: local checks"
    [[ -d "${REPO_ROOT}/server/src" ]] || { err "server/src missing"; exit 1; }
    [[ -f "${REPO_ROOT}/deploy/Dockerfile.ghost-chat" ]] || { err "deploy/Dockerfile.ghost-chat missing"; exit 1; }
    [[ -f "${REPO_ROOT}/deploy/nginx.conf" ]] || { err "deploy/nginx.conf missing"; exit 1; }
    [[ -f "${REPO_ROOT}/deploy/docker-compose.yml" ]] || { err "deploy/docker-compose.yml missing"; exit 1; }
    [[ -f "${SSH_KEY}" ]] || { err "SSH key not found: ${SSH_KEY}"; exit 1; }
    command -v rsync >/dev/null 2>&1 || { err "rsync not installed"; exit 1; }
    command -v ssh >/dev/null 2>&1 || { err "ssh not installed"; exit 1; }

    # Grep for known-bad patterns that would break prod.
    if grep -q "BLOCK_DURATION" "${REPO_ROOT}/server/src/"*.ts 2>/dev/null; then
        err "server/src still references BLOCK_DURATION — fix locally first"
        exit 1
    fi

    # Sanity: local compose must not publish ghost-chat on 0.0.0.0 in prod.
    if grep -E 'HOST_PORT.*:3000' "${REPO_ROOT}/deploy/docker-compose.yml" >/dev/null 2>&1; then
        warn "deploy/docker-compose.yml still has HOST_PORT mapping for ghost-chat."
        warn "Prod should bind to 127.0.0.1 or use expose only — review Phase 0 checklist."
    fi
    ok "local preflight passed"
}

preflight_remote() {
    log "preflight: ssh reachability"
    ssh_cmd 'echo pong' >/dev/null || { err "ssh unreachable"; exit 1; }
    ssh_cmd "test -d ${REMOTE_DIR}" || { err "remote dir ${REMOTE_DIR} missing"; exit 1; }
    ssh_cmd "test -d ${REMOTE_SRC_ROOT}" || { err "remote src root ${REMOTE_SRC_ROOT} missing"; exit 1; }
    ssh_cmd "test -f ${REMOTE_DIR}/.env" || { err ".env missing on server — fill from template first"; exit 1; }
    ssh_cmd "docker version --format '{{.Server.Version}}'" >/dev/null || { err "docker not healthy"; exit 1; }

    # Required running sidecars — we only restart ghost-chat; nginx+coturn must already be up.
    local missing
    missing="$(ssh_cmd "for c in ghost-nginx ghost-turn; do docker inspect -f '{{.State.Running}}' \$c 2>/dev/null | grep -q true || echo \$c; done")"
    if [[ -n "${missing}" ]]; then
        err "required containers not running: ${missing}"
        exit 1
    fi

    # .env must have TURN_SECRET and APNS creds populated (server already crashed once on empty env).
    local env_ok
    env_ok="$(ssh_cmd "grep -E '^(TURN_SECRET|APNS_KEY_ID|APNS_TEAM_ID|NODE_ENV)=.+' ${REMOTE_DIR}/.env | wc -l")"
    if [[ "${env_ok}" -lt 4 ]]; then
        err ".env on server missing required keys (TURN_SECRET / APNS_KEY_ID / APNS_TEAM_ID / NODE_ENV)"
        exit 1
    fi

    # Warn (not fail) if turnserver.conf still has placeholder/CHANGE_ME — coturn credentials will not match.
    local turn_broken
    turn_broken="$(ssh_cmd "grep -E 'static-auth-secret=(CHANGE_ME|\\\$\\{TURN_SECRET\\}|\\\$TURN_SECRET)' ${REMOTE_DIR}/turnserver.conf || true")"
    if [[ -n "${turn_broken}" ]]; then
        warn "turnserver.conf has placeholder secret — TURN relay will not match app .env"
        warn "fix: edit ${REMOTE_DIR}/turnserver.conf, set static-auth-secret=<same hex as .env TURN_SECRET>, then: docker compose --profile prod up -d coturn"
    fi
    ok "remote preflight passed"
}

# --- snapshot --------------------------------------------------------------
snapshot_remote() {
    TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    log "snapshot: timestamp=${TIMESTAMP}"
    ssh_script <<EOF
set -Eeuo pipefail
cd "${REMOTE_DIR}"

for f in nginx.conf docker-compose.yml .env; do
    [[ -f "\${f}" ]] && cp -p "\${f}" "\${f}.pre-deploy-${TIMESTAMP}"
done

# Tag the currently-running ghost-chat image so we can roll back to it.
if docker image inspect deploy-ghost-chat:latest >/dev/null 2>&1; then
    docker tag deploy-ghost-chat:latest "deploy-ghost-chat:backup-${TIMESTAMP}"
fi

# Landing dir: always snapshot if present, so sync_landing + rsync --delete
# has a safe rollback target. Idempotent — we preserve the current serving dir
# before any writes.
if [[ -d "${REMOTE_LANDING_DIR}" ]]; then
    rm -rf "${REMOTE_LANDING_DIR}.pre-deploy-${TIMESTAMP}"
    cp -rp "${REMOTE_LANDING_DIR}" "${REMOTE_LANDING_DIR}.pre-deploy-${TIMESTAMP}"
else
    # First deploy — seed landing dir from legacy in-place files if any exist.
    mkdir -p "${REMOTE_LANDING_DIR}"
    for f in index.html privacy.html manifest.json sw.js; do
        [[ -f "${REMOTE_DIR}/\${f}" ]] && cp -p "${REMOTE_DIR}/\${f}" "${REMOTE_LANDING_DIR}/\${f}"
    done
    for d in css js fonts icons; do
        [[ -d "${REMOTE_DIR}/\${d}" ]] && cp -rp "${REMOTE_DIR}/\${d}" "${REMOTE_LANDING_DIR}/\${d}"
    done
fi
EOF
    ok "snapshot created — configs.pre-deploy-${TIMESTAMP}, ghostchat-www.pre-deploy-${TIMESTAMP}/, :backup-${TIMESTAMP} image tag"
}

# --- sync ------------------------------------------------------------------
sync_code() {
    log "rsync: server/ → ${REMOTE_SRC_ROOT}/server/"
    # --delete is safe here: /root/kordar/server/ contains only the old server JS blob
    # that must be overwritten. Exclude everything unrelated to the build context.
    rsync -az --delete \
        -e "ssh -i ${SSH_KEY} -o ConnectTimeout=20" \
        --exclude 'node_modules/' \
        --exclude 'dist/' \
        --exclude 'test/' \
        --exclude '*.log' \
        --exclude '.DS_Store' \
        "${REPO_ROOT}/server/" \
        "${SSH_USER}@${SSH_HOST}:${REMOTE_SRC_ROOT}/server/"

    log "rsync: deploy-side configs → ${REMOTE_DIR}/"
    # Sync only specific deploy files. NEVER full deploy/ — would clobber landing, keys, ssl, certbot.
    # turnserver.conf is intentionally skipped: repo version has ${TURN_SECRET} placeholder,
    # server version has a real hex secret that coturn needs literally.
    rsync -az \
        -e "ssh -i ${SSH_KEY} -o ConnectTimeout=20" \
        "${REPO_ROOT}/deploy/Dockerfile.ghost-chat" \
        "${REPO_ROOT}/deploy/nginx.conf" \
        "${REPO_ROOT}/deploy/docker-compose.yml" \
        "${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/"

    ok "sync complete"
}

sync_landing() {
    # Repo landing/ → remote ghostchat-www/. --delete is safe because we took
    # a snapshot in snapshot_remote() and rollback() restores it.
    # Explicit chmod afterwards — cp -p on the server can carry over 600 from
    # files created locally (owner-only), and nginx worker cannot read those.
    if [[ ! -d "${REPO_ROOT}/deploy/landing" ]]; then
        warn "deploy/landing/ missing locally — skipping landing sync"
        return 0
    fi
    log "rsync: landing/ → ${REMOTE_LANDING_DIR}/"
    rsync -az --delete \
        -e "ssh -i ${SSH_KEY} -o ConnectTimeout=20" \
        --exclude '.DS_Store' \
        --exclude '*.bak' \
        "${REPO_ROOT}/deploy/landing/" \
        "${SSH_USER}@${SSH_HOST}:${REMOTE_LANDING_DIR}/"

    # Normalize permissions so the nginx worker (non-owner) can read everything.
    # chmod go+rX: add read to group/other on files, and add read+execute on
    # directories (capital X) — will NOT make files executable by accident.
    ssh_cmd "chmod -R go+rX ${REMOTE_LANDING_DIR}/"
    ok "landing synced + permissions normalized"
}

# --- build & up ------------------------------------------------------------
build_and_start() {
    ROLLBACK_NEEDED=1
    log "build: docker compose build ghost-chat (no cache)"
    ssh_script <<EOF
set -Eeuo pipefail
cd "${REMOTE_DIR}"

# Point build context at the mirrored tree where new server/ lives.
# Override context via compose.override if present; otherwise rely on docker-compose.yml.
docker compose build --no-cache ghost-chat

echo "[remote] ghost-chat image rebuilt"
docker compose up -d ghost-chat

# Nginx config reload only if the config file actually changed hash.
if docker exec ghost-nginx nginx -t >/dev/null 2>&1; then
    docker exec ghost-nginx nginx -s reload
    echo "[remote] nginx reloaded"
else
    echo "[remote] nginx -t failed; not reloading"
    exit 1
fi
EOF
    ok "new ghost-chat container up; nginx reloaded"
}

# --- health gate -----------------------------------------------------------
# Important: every probe writes curl output to a temp file and reads from it.
# Using `curl ... | head -1` would close the pipe early, kill curl with
# SIGPIPE (exit 141), and trip `set -o pipefail`, which then unwinds out of
# health_gate on what should have been a successful probe.
health_gate() {
    log "health gate: up to $((HEALTH_RETRIES * HEALTH_BACKOFF_SEC))s"
    local attempt=0
    local body_tmp
    body_tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${body_tmp}'" RETURN

    while (( attempt < HEALTH_RETRIES )); do
        attempt=$(( attempt + 1 ))
        local code
        code="$(curl -sk -o "${body_tmp}" -w '%{http_code}' -m 5 "${HEALTH_URL}" || echo 000)"
        if [[ "${code}" == "200" ]] && grep -q '"status":"ok"' "${body_tmp}"; then
            ok "/health → 200 + status:ok (attempt ${attempt})"
            break
        fi
        printf '%s[wait]%s /health attempt %d/%d (last=%s)\n' "${C_DIM}" "${C_RST}" \
            "${attempt}" "${HEALTH_RETRIES}" "${code}"
        sleep "${HEALTH_BACKOFF_SEC}"
        if (( attempt == HEALTH_RETRIES )); then
            err "/health never returned 200/ok"
            return 1
        fi
    done

    log "ws gate: upgrade probe (HTTP/1.1 — RFC 6455 does not allow Upgrade over HTTP/2)"
    local ws_curl_rc=0
    curl -sk --http1.1 -i -m 5 \
        -H 'Connection: Upgrade' \
        -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        "${WS_URL}" >"${body_tmp}" 2>/dev/null || ws_curl_rc=$?
    # curl exits 18 (CURLE_PARTIAL_FILE) for many WS upgrades because the
    # server keeps the socket open after 101 — that's a success, not a failure.
    # Only treat hard transport errors (timeout 28, refused 7, ...) as fatal.
    if (( ws_curl_rc != 0 && ws_curl_rc != 18 && ws_curl_rc != 56 )); then
        err "/ws upgrade curl failed (exit ${ws_curl_rc})"
        return 1
    fi
    local ws_first_line
    IFS= read -r ws_first_line < "${body_tmp}" || true
    ws_first_line="${ws_first_line//$'\r'/}"
    if [[ "${ws_first_line}" != *"101"* ]]; then
        err "/ws upgrade did not return 101 (got: ${ws_first_line:-empty})"
        return 1
    fi
    ok "/ws upgrade → ${ws_first_line}"

    log "landing gate: GET /"
    curl -skI -m 5 "${LANDING_URL}" >"${body_tmp}" 2>/dev/null
    local landing_ct=""
    while IFS= read -r line; do
        line="${line//$'\r'/}"
        if [[ "${line,,}" == content-type:* ]]; then
            landing_ct="${line}"
            break
        fi
    done < "${body_tmp}"
    if [[ "${landing_ct,,}" != *"text/html"* ]]; then
        err "landing / did not return text/html (got: ${landing_ct:-empty})"
        return 1
    fi
    ok "/ → ${landing_ct}"
    return 0
}

# --- rollback --------------------------------------------------------------
rollback() {
    if (( ROLLBACK_RAN == 1 )); then return 0; fi
    ROLLBACK_RAN=1
    warn "rolling back to snapshot ${TIMESTAMP}"
    ssh_script <<EOF || true
set +e
cd "${REMOTE_DIR}"

for f in nginx.conf docker-compose.yml .env; do
    if [[ -f "\${f}.pre-deploy-${TIMESTAMP}" ]]; then
        cp -p "\${f}.pre-deploy-${TIMESTAMP}" "\${f}"
        echo "[rollback] restored \${f}"
    fi
done

if [[ -d "${REMOTE_LANDING_DIR}.pre-deploy-${TIMESTAMP}" ]]; then
    rm -rf "${REMOTE_LANDING_DIR}"
    mv "${REMOTE_LANDING_DIR}.pre-deploy-${TIMESTAMP}" "${REMOTE_LANDING_DIR}"
    echo "[rollback] restored ghostchat-www/"
fi

if docker image inspect "deploy-ghost-chat:backup-${TIMESTAMP}" >/dev/null 2>&1; then
    docker tag "deploy-ghost-chat:backup-${TIMESTAMP}" deploy-ghost-chat:latest
    docker compose up -d ghost-chat
    echo "[rollback] ghost-chat image reverted"
fi

docker exec ghost-nginx nginx -t >/dev/null 2>&1 && \
    docker exec ghost-nginx nginx -s reload || \
    echo "[rollback] nginx -t failed post-rollback — inspect manually"
EOF
    warn "rollback complete — inspect docker logs ghost-chat"
}

trap 'rc=$?; if (( rc != 0 && ROLLBACK_NEEDED == 1 )); then rollback; fi; exit ${rc}' ERR INT TERM

# --- main ------------------------------------------------------------------
main() {
    AUTO_YES=0
    SIMULATE_ROLLBACK=0
    for arg in "$@"; do
        case "${arg}" in
            --yes|-y) AUTO_YES=1 ;;
            --simulate-rollback)
                # Test mode: print the rollback message + exit non-zero without
                # touching anything remote. Used by scripts/test-deploy-server.sh
                # to verify the failure path renders correctly.
                SIMULATE_ROLLBACK=1 ;;
            -h|--help)
                cat <<HELP
deploy-server.sh — Ghost Chat v2 production deploy

  --yes                  skip interactive confirmation
  --simulate-rollback    print the failure message + exit 1 without
                         contacting the server (test harness)
  --help                 this message

Before running:
  - deploy/nginx.conf already updated for new architecture (location / → static)
  - deploy/docker-compose.yml uses expose: 3000 (no ports: publish)
  - /root/kordar/deploy/.env filled (see .env template from deploy plan)
HELP
                exit 0 ;;
        esac
    done

    if (( SIMULATE_ROLLBACK == 1 )); then
        TIMESTAMP="simulated-$(date -u +%Y%m%dT%H%M%SZ)"
        ROLLBACK_RAN=1
        err "DEPLOY FAILED — rolled back to snapshot ${TIMESTAMP}"
        exit 1
    fi

    log "target: ${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}"
    preflight_local
    preflight_remote

    echo
    warn "about to deploy: rebuild ghost-chat image + update configs"
    confirm || { err "aborted by user"; exit 1; }

    snapshot_remote
    sync_code
    sync_landing
    build_and_start

    if ! health_gate; then
        err "health gate failed — rolling back"
        rollback
        ssh_cmd 'docker logs --tail 100 ghost-chat' || true
        exit 1
    fi

    # Final guard — even if a previous step quietly armed rollback (e.g. an
    # unexpected pipeline exit), refuse to print "succeeded" once the rollback
    # has actually run. The exit status mirrors what the user observes.
    if (( ROLLBACK_RAN == 1 )); then
        err "DEPLOY FAILED — rolled back to snapshot ${TIMESTAMP}"
        exit 1
    fi

    ROLLBACK_NEEDED=0
    ok "deploy succeeded — snapshot tag :backup-${TIMESTAMP} kept"
    log "keep snapshot for 24h, then: ssh ... 'cd ${REMOTE_DIR} && rm -rf *.pre-deploy-${TIMESTAMP} ghostchat-www.pre-deploy-${TIMESTAMP} && docker rmi deploy-ghost-chat:backup-${TIMESTAMP}'"
}

main "$@"
