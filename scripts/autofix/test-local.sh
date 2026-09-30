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

echo "== materialize (real script) =="
# Run scripts/autofix/materialize.sh with the local user as owner (no hermes).
export HEIMCLOUD_AUTOFIX_TOKEN_FILE="$TOKEN_FILE"
export HEIMCLOUD_AUTOFIX_SETTINGS="$SETTINGS"
export HEIMCLOUD_AUTOFIX_EXTRACT="$EXTRACT"
export HEIMCLOUD_AUTOFIX_OWNER="$(id -un)"
export HEIMCLOUD_AUTOFIX_GROUP="$(id -gn)"
MAT="$AF/materialize.sh"
TOKEN_DIR="$(dirname "$TOKEN_FILE")"
PR_TOKEN_FILE="$TOKEN_DIR/pr-token"
want_owner="$(id -un):$(id -gn)"
set +x

check_dir() {
  local m o
  m="$(stat -c '%a' "$TOKEN_DIR")"; o="$(stat -c '%U:%G' "$TOKEN_DIR")"
  if [[ "$m" != "700" || "$o" != "$want_owner" ]]; then
    echo "FAIL: dir mode=$m owner=$o want 700 $want_owner ($1)" >&2
    exit 1
  fi
}
check_token() {
  local m o
  m="$(stat -c '%a' "$TOKEN_FILE")"; o="$(stat -c '%U:%G' "$TOKEN_FILE")"
  if [[ "$m" != "400" || "$o" != "$want_owner" ]]; then
    echo "FAIL: token mode=$m owner=$o want 400 $want_owner ($1)" >&2
    exit 1
  fi
  if [[ "$(cat "$TOKEN_FILE")" != "$DUMMY" ]]; then
    echo "FAIL: token content mismatch ($1)" >&2
    exit 1
  fi
}

# Pre-existing dir with the wrong mode (what a stale tmpfiles rule leaves) +
# a reserved pr-token that materialize must leave alone.
chmod 0755 "$TOKEN_DIR"
printf 'reserved-pr\n' > "$PR_TOKEN_FILE"
chmod 0400 "$PR_TOKEN_FILE"
out="$(bash "$MAT")"
if [[ "$out" == *"$DUMMY"* ]]; then
  echo "FAIL: materialize printed the token" >&2
  exit 1
fi
check_dir "first run"
check_token "first run"
[[ -f "$PR_TOKEN_FILE" ]] || { echo "FAIL: pr-token removed" >&2; exit 1; }
if compgen -G "$TOKEN_DIR/.github-token.tmp.*" >/dev/null; then
  echo "FAIL: temp file left behind" >&2
  exit 1
fi
# Idempotent: second run (token file already 0400) still succeeds.
bash "$MAT" >/dev/null
check_dir "second run"
check_token "second run"
echo "materialize ok (dir 700, token 400, owner $want_owner, idempotent, pr-token kept)"

echo "== materialize edge cases never fail =="
# Missing key → token removed, exit 0, pr-token kept.
HEIMCLOUD_AUTOFIX_SETTINGS="$TMP/empty.toml" bash "$MAT" >/dev/null
[[ ! -e "$TOKEN_FILE" ]] || { echo "FAIL: stale token kept for null key" >&2; exit 1; }
[[ -f "$PR_TOKEN_FILE" ]] || { echo "FAIL: pr-token removed (null key)" >&2; exit 1; }
check_dir "null key"
# Explicitly empty value → feature off.
printf '[services.credentials.ops]\nautofixForkPushToken = ""\n' > "$TMP/blank.toml"
HEIMCLOUD_AUTOFIX_SETTINGS="$TMP/blank.toml" bash "$MAT" >/dev/null
[[ ! -e "$TOKEN_FILE" ]] || { echo "FAIL: token for empty value" >&2; exit 1; }
# No settings file → exit 0.
HEIMCLOUD_AUTOFIX_SETTINGS="$TMP/nope.toml" bash "$MAT" >/dev/null
# Unknown owner → skip, exit 0.
HEIMCLOUD_AUTOFIX_OWNER="heimcloud-no-such-user-$$" bash "$MAT" >/dev/null
# Unexpected error (parent not writable) → warning, still exit 0.
mkdir -p "$TMP/ro"; chmod 0500 "$TMP/ro"
if ! HEIMCLOUD_AUTOFIX_TOKEN_FILE="$TMP/ro/sub/github-token" bash "$MAT" >/dev/null 2>&1; then
  echo "FAIL: materialize exited non-zero on error" >&2
  exit 1
fi
chmod 0700 "$TMP/ro"
# Restore token for the helper/wrapper checks below.
bash "$MAT" >/dev/null
check_token "restore"
echo "edge cases ok (all exit 0)"

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
export HEIMCLOUD_AUTOFIX_PR_TOKEN_FILE="$PR_TOKEN_FILE"
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
# Reserved pr-token: exported when readable, ignored when unreadable/absent.
child_pr="$("$WRAPPER" bash -c 'printf %s "${GH_PR_TOKEN-NONE}"')"
if [[ "$child_pr" != "reserved-pr" ]]; then
  echo "FAIL: expected GH_PR_TOKEN from reserved pr-token" >&2
  exit 1
fi
if [[ "$(id -u)" != 0 ]]; then
  chmod 0000 "$PR_TOKEN_FILE"
  child_pr2="$("$WRAPPER" bash -c 'printf %s "${GH_PR_TOKEN-NONE}:${GH_TOKEN:+set}"')"
  if [[ "$child_pr2" != "NONE:set" ]]; then
    echo "FAIL: unreadable pr-token should be ignored, got $child_pr2" >&2
    exit 1
  fi
  chmod 0400 "$PR_TOKEN_FILE"
fi
rm -f "$PR_TOKEN_FILE"
child_pr3="$("$WRAPPER" bash -c 'printf %s "${GH_PR_TOKEN-NONE}"')"
[[ "$child_pr3" == "NONE" ]] || { echo "FAIL: GH_PR_TOKEN without pr-token" >&2; exit 1; }
echo "pr-token reserved path ok"
# Unreadable fork-push token → --check non-zero (triage), wrapper still runs.
if [[ "$(id -u)" != 0 ]]; then
  chmod 0000 "$TOKEN_FILE"
  if "$WRAPPER" --check; then
    echo "FAIL: --check should fail for unreadable token" >&2
    exit 1
  fi
  out4="$("$WRAPPER" bash -c 'echo TOK=${GH_TOKEN-EMPTY}')"
  [[ "$out4" == "TOK=EMPTY" ]] || { echo "FAIL: unreadable token, got $out4" >&2; exit 1; }
  chmod 0400 "$TOKEN_FILE"
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
