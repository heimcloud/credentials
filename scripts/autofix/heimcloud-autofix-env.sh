#!/usr/bin/env bash
# Wrap a command with Heimcloud Ops auto-fix GitHub credentials for the child only.
# - GIT_CONFIG_GLOBAL → store gitconfig with credential helper for github.com/heimcloud/
# - GH_TOKEN ← fork-push token file (gh cannot path-scope; rely on fine-grained repo selection)
# Reserved for a future GitHub App credential (upstream PR on madebydamo/neo):
#   if /run/heimcloud-autofix/pr-token exists, export GH_PR_TOKEN for callers that opt in.
# Does NOT touch nix.conf, ~/.gitconfig, or gh hosts.yml.
set +x
set -eu

TOKEN_FILE="${HEIMCLOUD_AUTOFIX_TOKEN_FILE:-/run/heimcloud-autofix/github-token}"
PR_TOKEN_FILE="${HEIMCLOUD_AUTOFIX_PR_TOKEN_FILE:-/run/heimcloud-autofix/pr-token}"
# Substituted at install time; overridable for tests.
GITCONFIG="${HEIMCLOUD_AUTOFIX_GITCONFIG:-@gitconfig@}"

usage() {
  cat >&2 <<'EOF'
usage: heimcloud-autofix-env [--check] [--] <command> [args...]

  --check   exit 0 if fork-push token file is present and non-empty; else 1
  <command> run with GIT_CONFIG_GLOBAL + GH_TOKEN set for this child only
            when the token file exists; otherwise run unauthenticated
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

if [[ "$1" == "--check" ]]; then
  if [[ -s "$TOKEN_FILE" ]]; then
    exit 0
  fi
  exit 1
fi

if [[ "$1" == "--" ]]; then
  shift
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

# Drop any ambient GitHub auth so autofix never inherits a broader token.
unset GH_TOKEN GH_PR_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL || true

if [[ -s "$TOKEN_FILE" ]]; then
  if [[ -n "$GITCONFIG" && "$GITCONFIG" != "@gitconfig@" && -f "$GITCONFIG" ]]; then
    export GIT_CONFIG_GLOBAL="$GITCONFIG"
  fi
  # Word-splitting intentionally avoided; token is a single line.
  GH_TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"
  export GH_TOKEN
  # Future optional upstream-PR credential (GitHub App) — export if present.
  if [[ -s "$PR_TOKEN_FILE" ]]; then
    GH_PR_TOKEN="$(tr -d '\n' < "$PR_TOKEN_FILE")"
    export GH_PR_TOKEN
  fi
fi

exec "$@"
