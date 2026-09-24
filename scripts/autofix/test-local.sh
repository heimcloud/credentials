#!/usr/bin/env bash
# Local validation of extract + materialize + wrapper (dummy token; no nix).
set +x
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AF="$ROOT/scripts/autofix"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SETTINGS="$TMP/settings.toml"
TOKEN_FILE="$TMP/run/heimcloud-autofix/github-token"
GITCONFIG="$TMP/heimcloud-autofix.gitconfig"
HELPER="$AF/git-credential-helper.sh"
EXTRACT="$AF/extract-token.py"

mkdir -p "$(dirname "$TOKEN_FILE")"
chmod 0700 "$(dirname "$TOKEN_FILE")"

DUMMY='ghp_DUMMY_TEST_TOKEN_DO_NOT_USE_9f3a2b1c'

cat > "$SETTINGS" <<EOF
[services.credentials]
enabled = true

[services.credentials.ops]
autofixForkPushToken = "$DUMMY"
EOF

echo "== extract =="
got="$("$EXTRACT" "$SETTINGS")"
if [[ "$got" != "$DUMMY" ]]; then
  echo "FAIL: extract mismatch" >&2
  exit 1
fi
echo "extract ok (value not printed)"

echo "== extract missing key =="
cat > "$TMP/empty.toml" <<'EOF'
[services.credentials]
enabled = true
EOF
got2="$("$EXTRACT" "$TMP/empty.toml" || true)"
if [[ -n "$got2" ]]; then
  echo "FAIL: expected empty extract" >&2
  exit 1
fi
echo "missing key → empty ok"

echo "== materialize =="
# Adapt materialize for local user (no hermes)
export HEIMCLOUD_AUTOFIX_TOKEN_FILE="$TOKEN_FILE"
export HEIMCLOUD_AUTOFIX_SETTINGS="$SETTINGS"
export HEIMCLOUD_AUTOFIX_OWNER="$(id -un)"
export HEIMCLOUD_AUTOFIX_GROUP="$(id -gn)"
# Inline materialize with local extract (no @extract@ subst)
set +x
token="$("$EXTRACT" "$SETTINGS" || true)"
rm -f "$TOKEN_FILE"
printf '%s\n' "$token" > "$TOKEN_FILE"
chmod 0400 "$TOKEN_FILE"
mode="$(stat -c '%a' "$TOKEN_FILE")"
if [[ "$mode" != "400" ]]; then
  echo "FAIL: mode=$mode want 400" >&2
  exit 1
fi
# Ensure dummy never appears in this script's stdout from here on for the "confirm" lines
echo "materialize ok mode=$mode"

echo "== gitconfig + helper =="
sed "s|@helper@|$HELPER|g" "$AF/gitconfig.in" > "$GITCONFIG"
export HEIMCLOUD_AUTOFIX_TOKEN_FILE="$TOKEN_FILE"
out="$(printf 'protocol=https\nhost=github.com\npath=heimcloud/neo\n\n' | "$HELPER" get)"
if ! grep -q 'username=x-access-token' <<<"$out"; then
  echo "FAIL: helper username" >&2
  exit 1
fi
if ! grep -q "password=$DUMMY" <<<"$out"; then
  echo "FAIL: helper password" >&2
  exit 1
fi
# Refuse non-heimcloud path
out2="$(printf 'protocol=https\nhost=github.com\npath=other/repo\n\n' | "$HELPER" get || true)"
if [[ -n "$out2" ]]; then
  echo "FAIL: helper should refuse other/repo" >&2
  exit 1
fi
echo "helper ok (scoped)"

echo "== wrapper --check / env =="
WRAPPER="$TMP/heimcloud-autofix-env"
sed "s|@gitconfig@|$GITCONFIG|g" "$AF/heimcloud-autofix-env.sh" > "$WRAPPER"
chmod +x "$WRAPPER"
export HEIMCLOUD_AUTOFIX_TOKEN_FILE="$TOKEN_FILE"
export HEIMCLOUD_AUTOFIX_GITCONFIG="$GITCONFIG"
"$WRAPPER" --check
# Child sees GH_TOKEN; parent dump must not be used — verify via env print in child
child="$("$WRAPPER" bash -c 'printf %s "$GH_TOKEN"')"
if [[ "$child" != "$DUMMY" ]]; then
  echo "FAIL: child GH_TOKEN" >&2
  exit 1
fi
# Confirm wrapper stdout for a benign command does not include token when cmd is echo hi
benign="$("$WRAPPER" echo hi)"
if [[ "$benign" == *"DUMMY"* ]]; then
  echo "FAIL: token leaked in benign output" >&2
  exit 1
fi
if [[ "$benign" != "hi" ]]; then
  echo "FAIL: wrapper exec" >&2
  exit 1
fi
# Absent token
rm -f "$TOKEN_FILE"
if "$WRAPPER" --check; then
  echo "FAIL: --check should fail without token" >&2
  exit 1
fi
out3="$("$WRAPPER" bash -c 'echo TOK=${GH_TOKEN-EMPTY}')"
if [[ "$out3" != "TOK=EMPTY" ]]; then
  echo "FAIL: expected no GH_TOKEN when absent, got $out3" >&2
  exit 1
fi
echo "wrapper ok"

echo "== materialize absent key does not fail =="
export HEIMCLOUD_AUTOFIX_SETTINGS="$TMP/empty.toml"
rm -f "$TOKEN_FILE"
# simulate materialize exit 0 path
token="$("$EXTRACT" "$TMP/empty.toml" || true)"
if [[ -n "$token" ]]; then
  echo "FAIL" >&2
  exit 1
fi
echo "absent key ok"

echo "ALL LOCAL CHECKS PASSED"
