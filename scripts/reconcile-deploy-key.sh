#!/usr/bin/env bash
# Single source of truth for the machine deploy keypair:
#   private = CREDENTIALS_DEPLOY_KEY (default homeserver id_ed25519)
#   public  = derived via ssh-keygen -y, written to CREDENTIALS_PUB_OUT
#             only when the private key exists
#
# Soft checks only — never fails the unit / activation:
#   missing private, orphan neo-ssh mismatch, neoSshPublicKey mismatch
#   → WARNING (fingerprints only) + status file + exit 0
# Does not delete or move an orphan private key.
#
# Status file (CREDENTIALS_STATUS_FILE): state=ok|orphan_mismatch|expected_mismatch|missing_key
# Never prints private key material.
set -euo pipefail

log() { echo "neo-credentials-deploy-key: $*" >&2; }
warn() { echo "neo-credentials-deploy-key: WARNING: $*" >&2; }

: "${CREDENTIALS_DEPLOY_KEY:?deploy key path unset}"
: "${CREDENTIALS_PUB_OUT:?pub out path unset}"
SSH_KEYGEN="${CREDENTIALS_SSH_KEYGEN:-ssh-keygen}"
STATUS_FILE="${CREDENTIALS_STATUS_FILE:-}"

write_status() {
  local state="$1" msg="$2"
  if [[ -n "$STATUS_FILE" ]]; then
    umask 022
    mkdir -p "$(dirname "$STATUS_FILE")"
    printf 'state=%s\nts=%s\nmsg=%s\n' "$state" "$(date -Iseconds 2>/dev/null || date)" "$msg" >"$STATUS_FILE"
  fi
}

if [[ ! -f "$CREDENTIALS_DEPLOY_KEY" ]]; then
  warn "private key missing at configured deploy key path — skipping neo-ssh.pub derive"
  write_status missing_key "deploy key private file missing"
  exit 0
fi

derived="$("$SSH_KEYGEN" -y -f "$CREDENTIALS_DEPLOY_KEY")"
derived_fp="$("$SSH_KEYGEN" -E sha256 -lf "$CREDENTIALS_DEPLOY_KEY" | awk '{print $2}')"
log "source private fingerprint ${derived_fp}"

state="ok"
msg="derived pub from deploy key"

# Orphan private at credentialsPath/neo-ssh (legacy mistaken keypair) — warn only
if [[ -n "${CREDENTIALS_ORPHAN_PRIVATE:-}" && -f "$CREDENTIALS_ORPHAN_PRIVATE" ]]; then
  if ! cmp -s "$CREDENTIALS_DEPLOY_KEY" "$CREDENTIALS_ORPHAN_PRIVATE"; then
    orphan_fp="$("$SSH_KEYGEN" -E sha256 -lf "$CREDENTIALS_ORPHAN_PRIVATE" | awk '{print $2}')"
    warn "orphan private key at neo-ssh does not match source deploy key"
    warn "source=${derived_fp} orphan=${orphan_fp}"
    warn "leave orphan in place; remove manually or point deployKeyPrivateKeyPath at the intended key"
    state="orphan_mismatch"
    msg="orphan neo-ssh fingerprint ${orphan_fp} != source ${derived_fp}"
  fi
fi

# Optional expected public key (from neoSshPublicKey option) — warn only
if [[ -n "${CREDENTIALS_EXPECTED_PUB:-}" && -f "$CREDENTIALS_EXPECTED_PUB" ]]; then
  expected="$(tr -d '\n' <"$CREDENTIALS_EXPECTED_PUB" | sed 's/[[:space:]]\+$//')"
  derived_core="$(printf '%s\n' "$derived" | awk '{print $1" "$2}')"
  expected_core="$(printf '%s\n' "$expected" | awk '{print $1" "$2}')"
  if [[ "$derived_core" != "$expected_core" ]]; then
    tmp="$(mktemp)"
    printf '%s\n' "$expected" >"$tmp"
    expected_fp="$("$SSH_KEYGEN" -E sha256 -lf "$tmp" | awk '{print $2}')"
    rm -f "$tmp"
    warn "neoSshPublicKey does not match private key at deployKeyPrivateKeyPath"
    warn "derived=${derived_fp} neoSshPublicKey=${expected_fp}"
    if [[ "$state" == "ok" ]]; then
      state="expected_mismatch"
      msg="neoSshPublicKey fingerprint ${expected_fp} != source ${derived_fp}"
    fi
  fi
fi

# Write derived pub whenever private exists (source of truth), even if warnings fired.
if [[ -f "$CREDENTIALS_PUB_OUT" ]]; then
  existing_core="$(awk '{print $1" "$2}' "$CREDENTIALS_PUB_OUT" 2>/dev/null || true)"
  derived_core="$(printf '%s\n' "$derived" | awk '{print $1" "$2}')"
  if [[ -n "$existing_core" && "$existing_core" != "$derived_core" ]]; then
    warn "existing neo-ssh.pub mismatched source private; overwriting from ssh-keygen -y"
  fi
fi

umask 022
mkdir -p "$(dirname "$CREDENTIALS_PUB_OUT")"
printf '%s\n' "$derived" >"$CREDENTIALS_PUB_OUT"
chmod 0644 "$CREDENTIALS_PUB_OUT"
log "wrote derived public key to pub out path"

write_status "$state" "$msg"
exit 0
