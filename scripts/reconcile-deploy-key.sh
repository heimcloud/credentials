#!/usr/bin/env bash
# Single source of truth for the machine deploy keypair:
#   private = CREDENTIALS_DEPLOY_KEY (default homeserver id_ed25519)
#   public  = derived via ssh-keygen -y, written to CREDENTIALS_PUB_OUT
#             only when the private key exists
#
# Soft checks only — never fails the unit / activation:
#   missing private, orphan neo-ssh mismatch, neoSshPublicKey mismatch,
#   helper/fingerprint failures → WARNING (fingerprints only) + status file + exit 0
# Does not delete or move an orphan private key.
#
# Status file (CREDENTIALS_STATUS_FILE):
#   state=ok|orphan_mismatch|expected_mismatch|missing_key|unknown
# Never prints private key material.
# Compares keys by SHA256 fingerprint (ssh-keygen -lf); never uses cmp/diff.
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

# SHA256 fingerprint of a private or public key file; empty + return 1 on failure.
fingerprint_of() {
  local f="$1" out fp
  if ! out="$("$SSH_KEYGEN" -E sha256 -lf "$f" 2>/dev/null)"; then
    return 1
  fi
  fp="$(printf '%s\n' "$out" | awk '{print $2; exit}')"
  if [[ -z "$fp" ]]; then
    return 1
  fi
  printf '%s\n' "$fp"
}

# type + base64 blob of an OpenSSH public key line (ignores comment / trailing space).
pubkey_core() {
  printf '%s\n' "$1" | awk '{print $1" "$2; exit}'
}

set_unknown() {
  local reason="$1"
  warn "$reason"
  if [[ "$state" == "ok" ]]; then
    state="unknown"
    msg="$reason"
  fi
}

if [[ ! -f "$CREDENTIALS_DEPLOY_KEY" ]]; then
  warn "private key missing at configured deploy key path — skipping neo-ssh.pub derive"
  write_status missing_key "deploy key private file missing"
  exit 0
fi

derived=""
if ! derived="$("$SSH_KEYGEN" -y -f "$CREDENTIALS_DEPLOY_KEY" 2>/dev/null)"; then
  warn "ssh-keygen -y failed on deploy key — skipping neo-ssh.pub derive"
  write_status unknown "ssh-keygen -y failed on deploy key"
  exit 0
fi

derived_fp=""
if ! derived_fp="$(fingerprint_of "$CREDENTIALS_DEPLOY_KEY")"; then
  warn "could not fingerprint source deploy key — continuing without fingerprint"
  derived_fp=""
fi
if [[ -n "$derived_fp" ]]; then
  log "source private fingerprint ${derived_fp}"
else
  log "source private fingerprint unavailable"
fi

state="ok"
msg="derived pub from deploy key"

# Orphan private at credentialsPath/neo-ssh (legacy mistaken keypair) — warn only.
# Compare by fingerprint only; never byte-compare private keys (avoids cmp/diffutils).
if [[ -n "${CREDENTIALS_ORPHAN_PRIVATE:-}" && -f "$CREDENTIALS_ORPHAN_PRIVATE" ]]; then
  orphan_fp=""
  if ! orphan_fp="$(fingerprint_of "$CREDENTIALS_ORPHAN_PRIVATE")"; then
    set_unknown "could not fingerprint orphan private key at neo-ssh; not classifying as mismatch"
  elif [[ -z "$derived_fp" ]]; then
    set_unknown "source fingerprint unavailable; cannot classify orphan neo-ssh"
  elif [[ "$orphan_fp" != "$derived_fp" ]]; then
    warn "orphan private key at neo-ssh does not match source deploy key"
    warn "source=${derived_fp} orphan=${orphan_fp}"
    warn "leave orphan in place; remove manually or point deployKeyPrivateKeyPath at the intended key"
    state="orphan_mismatch"
    msg="orphan neo-ssh fingerprint ${orphan_fp} != source ${derived_fp}"
  else
    log "orphan neo-ssh fingerprint matches source (${derived_fp})"
  fi
fi

# Optional expected public key (from neoSshPublicKey option) — warn only
if [[ -n "${CREDENTIALS_EXPECTED_PUB:-}" && -f "$CREDENTIALS_EXPECTED_PUB" ]]; then
  expected="$(tr -d '\n' <"$CREDENTIALS_EXPECTED_PUB" | sed 's/[[:space:]]\+$//')"
  derived_core="$(pubkey_core "$derived")"
  expected_core="$(pubkey_core "$expected")"
  if [[ -z "$derived_core" || -z "$expected_core" ]]; then
    set_unknown "could not parse derived or expected public key for comparison"
  elif [[ "$derived_core" != "$expected_core" ]]; then
    expected_fp=""
    tmp="$(mktemp)"
    printf '%s\n' "$expected" >"$tmp"
    expected_fp="$(fingerprint_of "$tmp" || true)"
    rm -f "$tmp"
    warn "neoSshPublicKey does not match private key at deployKeyPrivateKeyPath"
    warn "derived=${derived_fp:-unavailable} neoSshPublicKey=${expected_fp:-unavailable}"
    if [[ "$state" == "ok" || "$state" == "unknown" ]]; then
      state="expected_mismatch"
      msg="neoSshPublicKey fingerprint ${expected_fp:-unavailable} != source ${derived_fp:-unavailable}"
    fi
  fi
fi

# Write derived pub whenever private exists (source of truth), even if warnings fired.
if [[ -f "$CREDENTIALS_PUB_OUT" ]]; then
  existing_core="$(pubkey_core "$(tr -d '\n' <"$CREDENTIALS_PUB_OUT" || true)")"
  derived_core="$(pubkey_core "$derived")"
  if [[ -n "$existing_core" && -n "$derived_core" && "$existing_core" != "$derived_core" ]]; then
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
