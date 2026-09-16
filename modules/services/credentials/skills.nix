# Hermes skill: report Neo update/activate failures to Heimcloud ops ingest.
{...}: {
  flake.modules.nixos.credentials-skills = {
    config,
    lib,
    ...
  }: let
    cfg = config.neo.services.credentials;
    domain = config.neo.services.swag.domain or null;
    credsDir = cfg.credentialsPath;
    tokenPath = "${credsDir}/ops/ingest.token";
    metaPath = "${credsDir}/meta.json";
    defaultOpsUrl = "https://ops.heimcloud.site/api/incidents";
  in {
    config.neo.services.credentials.skill.conf = lib.neo.mkServiceSkill {
      service = "credentials";
      inherit cfg domain;
      name = "heimcloud-ops-ingest";
      description = "POST Neo update/activate failures to Heimcloud ops";
      tags = ["neo" "heimcloud" "ops" "incidents" "credentials"];
      title = "Heimcloud · Ops incident ingest";
      body = ''
        ## When to Use
        After a **Neo update / activate / dependency failure**, or a **nightly (`neo-auto-update`) failure**, file an incident with Heimcloud ops so HQ can see customer impact. Also use when the operator asks you to report a broken Neo generation or failed activate to Heimcloud.

        Pair with `neo-update-supervisor`: after you classify a run as **broken** (or a hard activate failure), POST an incident here in addition to any local Hermes notify. Do **not** POST on clean runs.

        ## Credentials (this machine)
        - Bearer token file (single line): `${tokenPath}`
        - Customer / ops metadata: `${metaPath}` (same credentials tree)
        - Default ingest URL: `${defaultOpsUrl}`
        - **Never** paste the token into chat, Telegram, notifications, or SKILL notes. Read it only via `cat` into curl `Authorization`.

        ## Resolve customer + URL
        1. If `${metaPath}` exists, read:
           - `repo_slug` / `customer_repo_slug` → `customer_repo_slug`
           - `ops_ingest_url` (optional) → override ingest URL; else use `${defaultOpsUrl}`
        2. If meta is missing, still POST when the token file exists; set `customer_repo_slug` to `"unknown"` and note that in `target_hint`.

        ## JSON body fields
        | Field | Required | Notes |
        |-------|----------|-------|
        | `report_hash` | yes | Stable id for this incident (e.g. sha256 of unit+neo_version+log excerpt head, or updater run id). Dedup-friendly. |
        | `neo_version` | yes | Neo / nixos generation hint (`neo --version`, or generation path / settings). |
        | `unit` | yes | Failed unit or workflow (`neo-auto-update`, `neo activate`, flake input name, etc.). |
        | `logs_excerpt` | yes | Short tail of relevant journal / updater `.log` (truncate; strip secrets). |
        | `customer_repo_slug` | yes | From `meta.json` `repo_slug`. |
        | `severity` | yes | One of: `info`, `warning`, `error`, `critical`. Activate/update hard fail → `error` or `critical`. |
        | `target_hint` | yes | What broke / what to look at (unit, flake input, host). |
        | `machine` | optional | Hostname / Neo machine id if known. |

        ## curl (no secrets in argv history — prefer file redirect)
        ```bash
        CREDS="${credsDir}"
        TOKEN_FILE="$CREDS/ops/ingest.token"
        META="$CREDS/meta.json"
        OPS_URL="${defaultOpsUrl}"
        SLUG="unknown"
        if [ -f "$META" ]; then
          SLUG=$(jq -r '.repo_slug // .customer_repo_slug // "unknown"' "$META")
          U=$(jq -r '.ops_ingest_url // empty' "$META")
          [ -n "$U" ] && OPS_URL="$U"
        fi
        test -s "$TOKEN_FILE" || { echo "missing ops ingest token"; exit 1; }

        # Build JSON in a temp file; Authorization reads token from file (never echo it).
        jq -n \
          --arg report_hash "$REPORT_HASH" \
          --arg neo_version "$NEO_VERSION" \
          --arg unit "$UNIT" \
          --arg logs_excerpt "$LOGS_EXCERPT" \
          --arg customer_repo_slug "$SLUG" \
          --arg severity "$SEVERITY" \
          --arg target_hint "$TARGET_HINT" \
          --arg machine "$(hostname -s 2>/dev/null || true)" \
          '{
            report_hash: $report_hash,
            neo_version: $neo_version,
            unit: $unit,
            logs_excerpt: $logs_excerpt,
            customer_repo_slug: $customer_repo_slug,
            severity: $severity,
            target_hint: $target_hint,
            machine: (if $machine == "" then null else $machine end)
          }' > /tmp/heimcloud-ops-incident.json

        curl -sS -X POST "$OPS_URL" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
          --data-binary @/tmp/heimcloud-ops-incident.json
        rm -f /tmp/heimcloud-ops-incident.json
        ```

        ## Procedures
        1. Confirm failure from updater marker / `systemctl --failed` / activate logs (see `neo-update-supervisor`).
        2. Ensure `${tokenPath}` exists (synced from private Gitea `customers/<slug>` via deploy key). Placeholder `replace-from-private-repo` means sync is incomplete — do not POST.
        3. Fill fields; POST as above.
        4. Tell the operator only that an incident was filed (HTTP status / `report_hash`) — **never** the bearer value.

        ## Pitfalls
        - Token lives only under appdata credentials; the nix plugin never embeds secrets.
        - Do not invent tokens. Do not write the bearer into MEMORY or chat.
        - Truncate logs; redact API keys, SSH keys, and `.env` contents.
        - Lab private repos (e.g. hattori / thatch) already ship `ops/ingest.token` + `meta.json` — sync them, then this skill works.

        ## Verification
        - `test -s ${tokenPath}` and file is not the placeholder string
        - `jq . ${metaPath}` shows `repo_slug`
        - A dry POST is only for confirmed failures; expect 2xx from ops ingest
      '';
    };
  };
}
