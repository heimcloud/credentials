#!/usr/bin/env bash
# Materialize autofixForkPushToken from settings.toml → tmpfs token file.
# Never fails the unit for a missing/null token (feature off).
set +x
set -eu

TOKEN_FILE="${HEIMCLOUD_AUTOFIX_TOKEN_FILE:-/run/heimcloud-autofix/github-token}"
TOKEN_DIR="$(dirname "$TOKEN_FILE")"
SETTINGS="${HEIMCLOUD_AUTOFIX_SETTINGS:-/etc/neo/settings.toml}"
EXTRACT="@extract@"
OWNER_USER="${HEIMCLOUD_AUTOFIX_OWNER:-hermes}"
OWNER_GROUP="${HEIMCLOUD_AUTOFIX_GROUP:-hermes}"

if ! id -u "$OWNER_USER" >/dev/null 2>&1; then
  echo "heimcloud-autofix: user $OWNER_USER absent; skip materialize"
  exit 0
fi

mkdir -p "$TOKEN_DIR"
chmod 0700 "$TOKEN_DIR"
chown "$OWNER_USER:$OWNER_GROUP" "$TOKEN_DIR"

# Remove stale token first so a cleared settings key disables the feature.
rm -f "$TOKEN_FILE"

if [[ ! -f "$SETTINGS" ]]; then
  echo "heimcloud-autofix: no settings.toml at $SETTINGS; feature off"
  exit 0
fi

token="$("$EXTRACT" "$SETTINGS" || true)"
if [[ -z "${token}" ]]; then
  echo "heimcloud-autofix: autofixForkPushToken unset; feature off"
  exit 0
fi

umask 077
# Write via temp + rename; never echo token.
tmp="${TOKEN_FILE}.tmp.$$"
# printf %s avoids trailing issues; no set -x above
printf '%s\n' "$token" > "$tmp"
chown "$OWNER_USER:$OWNER_GROUP" "$tmp"
chmod 0400 "$tmp"
mv -f "$tmp" "$TOKEN_FILE"
# Confirm mode without revealing contents
echo "heimcloud-autofix: materialized token file mode=$(stat -c '%a' "$TOKEN_FILE") owner=$(stat -c '%U:%G' "$TOKEN_FILE")"
