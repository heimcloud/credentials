#!/usr/bin/env bash
# Git credential helper scoped via credential."https://github.com/heimcloud/".helper
# Reads /run/heimcloud-autofix/github-token (hermes-owned, 0400). Never logs the token.
set +x
set -eu
TOKEN_FILE="${HEIMCLOUD_AUTOFIX_TOKEN_FILE:-/run/heimcloud-autofix/github-token}"

op="${1:-}"
case "$op" in
  get)
    if [[ ! -r "$TOKEN_FILE" ]]; then
      exit 0
    fi
    # Parse credential request from stdin (host=, protocol=, path=).
    host=""
    protocol=""
    path=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && break
      case "$line" in
        host=*) host="${line#host=}" ;;
        protocol=*) protocol="${line#protocol=}" ;;
        path=*) path="${line#path=}" ;;
      esac
    done
    if [[ "$protocol" != "https" || "$host" != "github.com" ]]; then
      exit 0
    fi
    # Path-scoped helper is registered only for https://github.com/heimcloud/
    # Still refuse anything that is clearly not under heimcloud/.
    if [[ -n "$path" && "$path" != heimcloud/* && "$path" != heimcloud ]]; then
      exit 0
    fi
    token="$(tr -d '\n' < "$TOKEN_FILE")"
    if [[ -z "$token" ]]; then
      exit 0
    fi
    printf 'username=x-access-token\npassword=%s\n' "$token"
    ;;
  store|erase)
    # Ephemeral token file — do not persist via git credential store.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
