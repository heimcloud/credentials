#!/usr/bin/env bash
# Wrap a command with Heimcloud Ops auto-fix GitHub credentials for the child only.
# - git: the credential helper heimcloud-autofix-git-credential is injected via
#   GIT_CONFIG_COUNT/KEY/VALUE (appended to any ambient entries), scoped to
#   https://github.com/heimcloud/ only:
#     credential.https://github.com/heimcloud/.helper      = ""  (reset list)
#     credential.https://github.com/heimcloud/.helper      = <helper>
#     credential.https://github.com/heimcloud/.useHttpPath = true
#   The caller's own git config (~/.gitconfig: user.name/email, ...) is kept.
# - GH_TOKEN ← fork-push token file (gh cannot path-scope; rely on fine-grained repo selection)
# Reserved for a future GitHub App credential (upstream PR on madebydamo/neo):
#   if /run/heimcloud-autofix/pr-token exists, export GH_PR_TOKEN for callers that opt in.
# Does NOT touch nix.conf, ~/.gitconfig, or gh hosts.yml.
set +x
set -eu

TOKEN_FILE="${HEIMCLOUD_AUTOFIX_TOKEN_FILE:-/run/heimcloud-autofix/github-token}"
PR_TOKEN_FILE="${HEIMCLOUD_AUTOFIX_PR_TOKEN_FILE:-/run/heimcloud-autofix/pr-token}"
# Absolute store paths substituted by Nix (scripts/autofix/package.nix);
# overridable for tests. These values are never compared against anything:
# a non-executable value (e.g. the unsubstituted repo source) falls back to a
# PATH lookup of the installed command.
HELPER="${HEIMCLOUD_AUTOFIX_GIT_HELPER:-@helper@}"
GIT_BIN="${HEIMCLOUD_AUTOFIX_GIT:-@git@}"

CRED_URL="https://github.com/heimcloud/"
CHECK_URL="https://github.com/heimcloud/neo"

usage() {
  cat >&2 <<'EOF2'
usage: heimcloud-autofix-env [--check] [--] <command> [args...]

  --check   exit 0 if the fork-push token file is present, non-empty and
            readable AND git under this wrapper resolves the autofix
            credential helper for https://github.com/heimcloud/neo and gets
            a password from it; else non-zero (message on stderr, token
            never printed)
  <command> run with the git credential helper + GH_TOKEN set for this
            child only when the token file exists; otherwise run
            unauthenticated
EOF2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

# Usable = non-empty AND readable by the caller (a root-owned leftover must
# read as "no token" → triage path, never a wrapper failure).
usable() {
  [[ -s "$1" && -r "$1" ]]
}

# resolve_exe <preferred path> <command name>: print an absolute executable.
resolve_exe() {
  local p
  if [[ "$1" == /* && -x "$1" && ! -d "$1" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  p="$(command -v -- "$2" 2>/dev/null || true)"
  if [[ "$p" == /* && -x "$p" && ! -d "$p" ]]; then
    printf '%s\n' "$p"
    return 0
  fi
  return 1
}

# Append the scoped credential-helper config to GIT_CONFIG_COUNT/KEY/VALUE.
# Sets HELPER_PATH. Returns non-zero (and changes nothing) when the helper
# cannot be found; never exits the wrapper.
HELPER_PATH=""
setup_git_env() {
  local helper n
  helper="$(resolve_exe "$HELPER" heimcloud-autofix-git-credential)" || return 1
  # git runs an absolute helper path through the shell: allow only plain
  # path characters (store paths always qualify).
  [[ "$helper" =~ ^/[A-Za-z0-9/._+-]+$ ]] || return 1
  n="${GIT_CONFIG_COUNT:-0}"
  if [[ "$n" =~ ^[0-9]{1,4}$ ]]; then
    n=$((10#$n))
  else
    # A malformed ambient count would make every git call die anyway.
    n=0
  fi
  export "GIT_CONFIG_KEY_$n=credential.${CRED_URL}.helper" "GIT_CONFIG_VALUE_$n="
  n=$((n + 1))
  export "GIT_CONFIG_KEY_$n=credential.${CRED_URL}.helper" "GIT_CONFIG_VALUE_$n=$helper"
  n=$((n + 1))
  export "GIT_CONFIG_KEY_$n=credential.${CRED_URL}.useHttpPath" "GIT_CONFIG_VALUE_$n=true"
  n=$((n + 1))
  export GIT_CONFIG_COUNT="$n"
  HELPER_PATH="$helper"
  return 0
}

check_fail() {
  echo "heimcloud-autofix-env --check: $*" >&2
  exit 1
}

# Drop any ambient GitHub auth so autofix never inherits a broader token.
unset GH_TOKEN GH_PR_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL || true

if [[ "$1" == "--check" ]]; then
  # Feature off (no/unreadable token) stays a silent exit 1 → triage path.
  if ! usable "$TOKEN_FILE"; then
    exit 1
  fi
  if ! setup_git_env; then
    check_fail "git credential helper heimcloud-autofix-git-credential not found or not executable"
  fi
  if ! git="$(resolve_exe "$GIT_BIN" git)"; then
    check_fail "git not found"
  fi
  # Run from / so an unreadable caller cwd cannot break the check.
  got="$(cd / && "$git" config --get-urlmatch credential.helper "$CHECK_URL" 2>/dev/null || true)"
  if [[ "$got" != "$HELPER_PATH" ]]; then
    # Do not print the other value: a helper string may embed a secret.
    check_fail "git config --get-urlmatch credential.helper $CHECK_URL does not resolve to $HELPER_PATH under the wrapper"
  fi
  # Ask git for credentials the way a push would; never prompt, never print.
  has_password=0
  while IFS= read -r line; do
    if [[ "$line" == password=?* ]]; then
      has_password=1
    fi
  done < <(cd / && printf 'protocol=https\nhost=github.com\npath=heimcloud/neo.git\n\n' |
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' SSH_ASKPASS='' \
      "$git" credential fill 2>/dev/null || true)
  unset line
  if [[ "$has_password" != 1 ]]; then
    check_fail "git credential fill for $CHECK_URL returned no password under the wrapper"
  fi
  exit 0
fi

if [[ "$1" == "--" ]]; then
  shift
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

if usable "$TOKEN_FILE"; then
  # Word-splitting intentionally avoided; token is a single line.
  GH_TOKEN="$(tr -d '\n' < "$TOKEN_FILE" 2>/dev/null || true)"
  if [[ -n "$GH_TOKEN" ]]; then
    export GH_TOKEN
    if ! setup_git_env; then
      echo "heimcloud-autofix-env: WARNING git credential helper not found; git over https stays unauthenticated" >&2
    fi
  else
    unset GH_TOKEN
  fi
  # Future optional upstream-PR credential (GitHub App) — export if present
  # and readable; absent/unreadable/empty is silently ignored.
  if usable "$PR_TOKEN_FILE"; then
    GH_PR_TOKEN="$(tr -d '\n' < "$PR_TOKEN_FILE" 2>/dev/null || true)"
    if [[ -n "$GH_PR_TOKEN" ]]; then
      export GH_PR_TOKEN
    else
      unset GH_PR_TOKEN
    fi
  fi
fi

exec "$@"
