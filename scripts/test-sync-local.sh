#!/usr/bin/env bash
# Local validation of reconcile-deploy-key + sync-customer-repo against a
# throwaway bare repo and ed25519 key. No network, no real slug.
set +x
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECON="$ROOT/scripts/reconcile-deploy-key.sh"
SYNC="$ROOT/scripts/sync-customer-repo.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SSH_KEYGEN="$(command -v ssh-keygen || true)"
if [[ -z "$SSH_KEYGEN" ]]; then
  SSH_KEYGEN="$(ls -1 /nix/store/*/bin/ssh-keygen 2>/dev/null | head -1 || true)"
fi
GIT="$(command -v git || true)"
RSYNC="$(command -v rsync || true)"
SSH="$(command -v ssh || true)"
if [[ -z "$SSH_KEYGEN" || -z "$GIT" || -z "$RSYNC" || -z "$SSH" ]]; then
  echo "NEED: ssh-keygen git rsync ssh (e.g. nix-shell -p openssh rsync git)" >&2
  exit 2
fi

echo "== generate throwaway key =="
"$SSH_KEYGEN" -t ed25519 -N "" -f "$TMP/deploy" -C "test@local" >/dev/null
chmod 600 "$TMP/deploy"

echo "== reconcile: derive pub =="
export CREDENTIALS_DEPLOY_KEY="$TMP/deploy"
export CREDENTIALS_PUB_OUT="$TMP/out/neo-ssh.pub"
export CREDENTIALS_STATUS_FILE="$TMP/out/.deploy-key-status"
export CREDENTIALS_SSH_KEYGEN="$SSH_KEYGEN"
mkdir -p "$TMP/out"
bash "$RECON"
[[ -f "$TMP/out/neo-ssh.pub" ]]
fp1="$("$SSH_KEYGEN" -E sha256 -lf "$TMP/deploy" | awk '{print $2}')"
fp2="$("$SSH_KEYGEN" -E sha256 -lf "$TMP/out/neo-ssh.pub" | awk '{print $2}')"
[[ "$fp1" == "$fp2" ]]
grep -q 'state=ok' "$TMP/out/.deploy-key-status"
echo "reconcile ok fp match"

echo "== reconcile: missing key warns, exit 0, no pub write =="
rm -f "$TMP/out/neo-ssh.pub"
export CREDENTIALS_DEPLOY_KEY="$TMP/missing-key"
export CREDENTIALS_STATUS_FILE="$TMP/out/.deploy-key-status-missing"
set +e
bash "$RECON" >"$TMP/missing.out" 2>"$TMP/missing.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: missing key should exit 0 got $rc" >&2; exit 1; }
grep -q 'WARNING' "$TMP/missing.err"
grep -q 'state=missing_key' "$TMP/out/.deploy-key-status-missing"
[[ ! -f "$TMP/out/neo-ssh.pub" ]]
export CREDENTIALS_DEPLOY_KEY="$TMP/deploy"
export CREDENTIALS_STATUS_FILE="$TMP/out/.deploy-key-status"
echo "missing key → warn + exit 0 ok"

echo "== reconcile: orphan mismatch warns, exit 0, keeps orphan, still writes pub =="
"$SSH_KEYGEN" -t ed25519 -N "" -f "$TMP/orphan" -C "orphan@local" >/dev/null
export CREDENTIALS_ORPHAN_PRIVATE="$TMP/orphan"
set +e
bash "$RECON" >"$TMP/orphan.out" 2>"$TMP/orphan.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: orphan mismatch should exit 0 got $rc" >&2; exit 1; }
grep -q 'WARNING' "$TMP/orphan.err"
grep -q 'orphan' "$TMP/orphan.err"
grep -q 'state=orphan_mismatch' "$TMP/out/.deploy-key-status"
[[ -f "$TMP/orphan" ]]  # not deleted
[[ -f "$TMP/out/neo-ssh.pub" ]]
unset CREDENTIALS_ORPHAN_PRIVATE
echo "orphan mismatch → warn + exit 0 ok"

echo "== reconcile: expected pub mismatch warns, exit 0 =="
"$SSH_KEYGEN" -t ed25519 -N "" -f "$TMP/other" -C "other@local" >/dev/null
"$SSH_KEYGEN" -y -f "$TMP/other" >"$TMP/other.pub"
export CREDENTIALS_EXPECTED_PUB="$TMP/other.pub"
set +e
bash "$RECON" >"$TMP/expected.out" 2>"$TMP/expected.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: expected mismatch should exit 0 got $rc" >&2; exit 1; }
grep -q 'WARNING' "$TMP/expected.err"
grep -q 'neoSshPublicKey' "$TMP/expected.err"
grep -q 'state=expected_mismatch' "$TMP/out/.deploy-key-status"
unset CREDENTIALS_EXPECTED_PUB
echo "expected pub mismatch → warn + exit 0 ok"

echo "== reconcile: matching expected pub ok =="
"$SSH_KEYGEN" -y -f "$TMP/deploy" >"$TMP/match.pub"
export CREDENTIALS_EXPECTED_PUB="$TMP/match.pub"
bash "$RECON"
grep -q 'state=ok' "$TMP/out/.deploy-key-status"
unset CREDENTIALS_EXPECTED_PUB
echo "matching expected pub ok"

echo "== local bare repo + sshd- Free sync via file:// =="
# Use file:// remote (no SSH) by pointing GIT_SSH unused; we test soft-fail path
# for missing known_hosts and hard-misconfig, plus a file-protocol happy path
# by overriding CREDENTIALS_GIT_URL to a local bare repo and a wrapper ssh that
# never runs.
mkdir -p "$TMP/remote-work" "$TMP/bare" "$TMP/sync" "$TMP/dest"
cd "$TMP/remote-work"
git init -q -b main
git config user.email test@local
git config user.name test
mkdir -p ops
echo 'token-test' > ops/ingest.token
echo '2' > layout_version
echo '{"layout_version":2}' > meta.json
git add .
git commit -q -m 'initial drop'
git clone -q --bare "$TMP/remote-work" "$TMP/bare/drop.git"
# Ensure HEAD points at main for shallow clients
git -C "$TMP/bare/drop.git" symbolic-ref HEAD refs/heads/main

# known_hosts required even for file:// path (script always checks)
printf 'localhost ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForLocalTestOnly000000000000000\n' >"$TMP/known_hosts"

export CREDENTIALS_SYNC_DIR="$TMP/sync"
export CREDENTIALS_DEST_DIR="$TMP/dest"
export CREDENTIALS_DEPLOY_KEY="$TMP/deploy"
export CREDENTIALS_GIT_URL="file://$TMP/bare/drop.git"
export CREDENTIALS_KNOWN_HOSTS="$TMP/known_hosts"
export CREDENTIALS_GIT_BIN="$GIT"
export CREDENTIALS_RSYNC_BIN="$RSYNC"
export CREDENTIALS_SSH_BIN="$SSH"
export CREDENTIALS_STATUS_FILE="$TMP/status"
export CREDENTIALS_OVERLAY_UNIT="neo-credentials-overlay-import.service.does-not-exist"
# file:// does not use SSH; still fine
bash "$SYNC"
[[ -f "$TMP/dest/layout_version" ]]
[[ -f "$TMP/dest/ops/ingest.token" ]]
[[ -f "$TMP/status" ]]
grep -q 'state=ok' "$TMP/status"
# neo-ssh.pub must not be deleted by rsync exclude
echo "legacy" >"$TMP/dest/neo-ssh.pub"
bash "$SYNC"
grep -q 'legacy' "$TMP/dest/neo-ssh.pub"
echo "sync file:// happy path ok"

echo "== hard misconfig: empty known_hosts =="
: >"$TMP/known_hosts_empty"
export CREDENTIALS_KNOWN_HOSTS="$TMP/known_hosts_empty"
if bash "$SYNC" 2>"$TMP/kh.err"; then
  echo "FAIL: empty known_hosts should hard-fail" >&2
  exit 1
fi
grep -q 'known_hosts' "$TMP/kh.err"
echo "empty known_hosts → hard fail ok"

echo "== soft fail: bad remote exits 0 =="
export CREDENTIALS_KNOWN_HOSTS="$TMP/known_hosts"
export CREDENTIALS_GIT_URL="file:///no/such/repo.git"
export CREDENTIALS_SYNC_DIR="$TMP/sync-bad"
mkdir -p "$TMP/sync-bad"
# remove any partial
rm -rf "$TMP/sync-bad/.git"
set +e
bash "$SYNC" >"$TMP/soft.out" 2>"$TMP/soft.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: soft fail should exit 0 got $rc" >&2; cat "$TMP/soft.err" >&2; exit 1; }
grep -q 'WARNING' "$TMP/soft.err"
echo "soft fail → exit 0 ok"

echo "ALL TESTS PASSED"
