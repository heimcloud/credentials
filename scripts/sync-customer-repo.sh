#!/usr/bin/env bash
# Sync private customer credentials repo over SSH deploy key → syncDir →
# credentialsPath, then trigger overlay import.
#
# Soft failures (network, auth, remote unavailable): log a clear warning and
# exit 0 so the timer does not degrade the system.
# Hard misconfiguration (missing slug option at generate-time, missing key,
# missing known_hosts when required): exit 1.
#
# Never print the repo slug, private key material, or tokens.
set -euo pipefail

log() { echo "neo-credentials-sync: $*" >&2; }
warn() { echo "neo-credentials-sync: WARNING: $*" >&2; }

SOFT_EXIT=0
soft_fail() {
  warn "$1"
  exit "$SOFT_EXIT"
}

: "${CREDENTIALS_SYNC_DIR:?hard misconfig: CREDENTIALS_SYNC_DIR unset}"
: "${CREDENTIALS_DEST_DIR:?hard misconfig: CREDENTIALS_DEST_DIR unset}"
: "${CREDENTIALS_DEPLOY_KEY:?hard misconfig: CREDENTIALS_DEPLOY_KEY unset}"
: "${CREDENTIALS_GIT_URL:?hard misconfig: CREDENTIALS_GIT_URL unset}"
: "${CREDENTIALS_KNOWN_HOSTS:?hard misconfig: CREDENTIALS_KNOWN_HOSTS unset}"

SSH_BIN="${CREDENTIALS_SSH_BIN:-ssh}"
GIT_BIN="${CREDENTIALS_GIT_BIN:-git}"
RSYNC_BIN="${CREDENTIALS_RSYNC_BIN:-rsync}"
OVERLAY_UNIT="${CREDENTIALS_OVERLAY_UNIT:-neo-credentials-overlay-import.service}"
STATUS_FILE="${CREDENTIALS_STATUS_FILE:-}"

write_status() {
  local state="$1" msg="$2"
  if [[ -n "$STATUS_FILE" ]]; then
    umask 077
    mkdir -p "$(dirname "$STATUS_FILE")"
    printf 'state=%s\nts=%s\nmsg=%s\n' "$state" "$(date -Iseconds)" "$msg" >"$STATUS_FILE"
  fi
}

if [[ ! -f "$CREDENTIALS_DEPLOY_KEY" ]]; then
  write_status hard-misconfig "deploy key private file missing"
  log "hard misconfig: deploy key private file missing"
  exit 1
fi

if [[ ! -f "$CREDENTIALS_KNOWN_HOSTS" ]]; then
  write_status hard-misconfig "known_hosts file missing"
  log "hard misconfig: SSH known_hosts file missing (pin the Gitea host key)"
  exit 1
fi

if [[ ! -s "$CREDENTIALS_KNOWN_HOSTS" ]]; then
  write_status hard-misconfig "known_hosts file empty"
  log "hard misconfig: SSH known_hosts file is empty"
  exit 1
fi

export GIT_SSH_COMMAND="${SSH_BIN} -i ${CREDENTIALS_DEPLOY_KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=${CREDENTIALS_KNOWN_HOSTS} -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o HashKnownHosts=no"

mkdir -p "$CREDENTIALS_SYNC_DIR"
chmod 0700 "$CREDENTIALS_SYNC_DIR" || true

if [[ ! -d "$CREDENTIALS_SYNC_DIR/.git" ]]; then
  log "cloning into sync dir (URL redacted)"
  if ! "$GIT_BIN" clone --depth 1 "$CREDENTIALS_GIT_URL" "$CREDENTIALS_SYNC_DIR"; then
    write_status soft-fail "git clone failed"
    soft_fail "git clone failed (network/auth/remote). Will retry next timer."
  fi
else
  log "fetching updates"
  if ! (
    cd "$CREDENTIALS_SYNC_DIR"
    "$GIT_BIN" remote set-url origin "$CREDENTIALS_GIT_URL"
    "$GIT_BIN" fetch --depth 1 origin
    # Prefer tracking branch tip; fall back to FETCH_HEAD
    if "$GIT_BIN" rev-parse --verify -q origin/HEAD >/dev/null; then
      "$GIT_BIN" reset --hard origin/HEAD
    elif "$GIT_BIN" rev-parse --verify -q origin/main >/dev/null; then
      "$GIT_BIN" reset --hard origin/main
    else
      "$GIT_BIN" reset --hard FETCH_HEAD
    fi
  ); then
    write_status soft-fail "git fetch/reset failed"
    soft_fail "git fetch/reset failed (network/auth/remote). Will retry next timer."
  fi
fi

mkdir -p "$CREDENTIALS_DEST_DIR"
# Mirror drop into credentials appdata; keep local neo-ssh.pub / REGISTER notes.
if ! "$RSYNC_BIN" -a --delete \
  --exclude '.git/' \
  --exclude 'neo-ssh' \
  --exclude 'neo-ssh.pub' \
  --exclude 'REGISTER-SSH-KEY.txt' \
  --exclude 'neo-credentials-overlay.md' \
  --exclude 'imported.env' \
  "$CREDENTIALS_SYNC_DIR"/ "$CREDENTIALS_DEST_DIR"/; then
  write_status soft-fail "rsync failed"
  soft_fail "rsync into credentials dir failed. Will retry next timer."
fi

if [[ -n "${CREDENTIALS_UID:-}" && -n "${CREDENTIALS_GID:-}" ]]; then
  chown -R "$CREDENTIALS_UID:$CREDENTIALS_GID" "$CREDENTIALS_SYNC_DIR" "$CREDENTIALS_DEST_DIR" || true
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl cat "$OVERLAY_UNIT" >/dev/null 2>&1; then
    if ! systemctl start "$OVERLAY_UNIT"; then
      write_status soft-fail "overlay-import start failed"
      soft_fail "overlay-import unit failed to start. Will retry next timer."
    fi
  else
    log "overlay-import unit not present; rsync only"
  fi
fi

write_status ok "synced"
log "sync completed"
exit 0
