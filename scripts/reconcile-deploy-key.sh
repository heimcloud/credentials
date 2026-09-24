#!/usr/bin/env bash
# Single source of truth for the machine deploy keypair:
#   private = CREDENTIALS_DEPLOY_KEY (default homeserver id_ed25519)
#   public  = derived via ssh-keygen -y, written to CREDENTIALS_PUB_OUT
#
# Fails loudly on mismatch between:
#   - derived pub vs optional expected pub file/string
#   - orphan CREDENTIALS_ORPHAN_PRIVATE (e.g. appdata/neo-ssh) vs source private
#
# Never prints private key material. Fingerprints only.
set -euo pipefail

log() { echo "neo-credentials-deploy-key: $*" >&2; }

: "${CREDENTIALS_DEPLOY_KEY:?deploy key path unset}"
: "${CREDENTIALS_PUB_OUT:?pub out path unset}"
SSH_KEYGEN="${CREDENTIALS_SSH_KEYGEN:-ssh-keygen}"

if [[ ! -f "$CREDENTIALS_DEPLOY_KEY" ]]; then
  log "ERROR: private key missing at configured deploy key path"
  exit 1
fi

derived="$("$SSH_KEYGEN" -y -f "$CREDENTIALS_DEPLOY_KEY")"
derived_fp="$("$SSH_KEYGEN" -E sha256 -lf "$CREDENTIALS_DEPLOY_KEY" | awk '{print $2}')"
log "source private fingerprint ${derived_fp}"

# Orphan private at credentialsPath/neo-ssh (legacy mistaken keypair)
if [[ -n "${CREDENTIALS_ORPHAN_PRIVATE:-}" && -f "$CREDENTIALS_ORPHAN_PRIVATE" ]]; then
  if ! cmp -s "$CREDENTIALS_DEPLOY_KEY" "$CREDENTIALS_ORPHAN_PRIVATE"; then
    orphan_fp="$("$SSH_KEYGEN" -E sha256 -lf "$CREDENTIALS_ORPHAN_PRIVATE" | awk '{print $2}')"
    log "ERROR: orphan private key at neo-ssh does not match source deploy key"
    log "ERROR: source=${derived_fp} orphan=${orphan_fp}"
    log "ERROR: remove the orphan or point deployKeyPrivateKeyPath at the intended key"
    exit 1
  fi
fi

# Optional expected public key (from neoSshPublicKey option materialised to a file)
if [[ -n "${CREDENTIALS_EXPECTED_PUB:-}" && -f "$CREDENTIALS_EXPECTED_PUB" ]]; then
  expected="$(tr -d '\n' <"$CREDENTIALS_EXPECTED_PUB" | sed 's/[[:space:]]\+$//')"
  # Compare key type + material only (ignore comment)
  derived_core="$(printf '%s\n' "$derived" | awk '{print $1" "$2}')"
  expected_core="$(printf '%s\n' "$expected" | awk '{print $1" "$2}')"
  if [[ "$derived_core" != "$expected_core" ]]; then
    # Write expected to temp for fingerprint
    tmp="$(mktemp)"
    printf '%s\n' "$expected" >"$tmp"
    expected_fp="$("$SSH_KEYGEN" -E sha256 -lf "$tmp" | awk '{print $2}')"
    rm -f "$tmp"
    log "ERROR: neoSshPublicKey does not match private key at deployKeyPrivateKeyPath"
    log "ERROR: derived=${derived_fp} neoSshPublicKey=${expected_fp}"
    exit 1
  fi
fi

# Existing pub out mismatch → reconcile by overwriting from derived
if [[ -f "$CREDENTIALS_PUB_OUT" ]]; then
  existing_core="$(awk '{print $1" "$2}' "$CREDENTIALS_PUB_OUT")"
  derived_core="$(printf '%s\n' "$derived" | awk '{print $1" "$2}')"
  if [[ "$existing_core" != "$derived_core" ]]; then
    log "WARNING: ${CREDENTIALS_PUB_OUT} mismatched source private; reconciling from ssh-keygen -y"
  fi
fi

umask 022
mkdir -p "$(dirname "$CREDENTIALS_PUB_OUT")"
printf '%s\n' "$derived" >"$CREDENTIALS_PUB_OUT"
chmod 0644 "$CREDENTIALS_PUB_OUT"
log "wrote derived public key to pub out path"
exit 0
