# Deterministic Heimcloud ops incident POST on Neo update failure (no Hermes LLM).
# Complements skill heimcloud-ops-ingest (manual / operator). Auto path must not
# depend on neo-update-supervisor remembering a second skill.
{...}: {
  flake.modules.nixos.credentials-ops-report = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.credentials;
      report = cfg.enabled && (cfg.reportUpdateFailures or false);
      systemUpdaterOn = config.neo.services.system-updater.enabled or false;
      dockerUpdaterOn = config.neo.services.docker-updater.enabled or false;
      credsDir = cfg.credentialsPath;
      tokenPath = "${credsDir}/ops/ingest.token";
      metaPath = "${credsDir}/meta.json";
      defaultOpsUrl = "https://ops.heimcloud.site/api/incidents";
      placeholder = "replace-from-private-repo";

      systemMarker =
        if systemUpdaterOn
        then "${config.neo.services.system-updater.appdata}/last.json"
        else "";
      dockerMarker =
        if dockerUpdaterOn
        then "${config.neo.services.docker-updater.appdata}/last.json"
        else "";

      reportScript = pkgs.writeShellScriptBin "neo-heimcloud-ops-report" ''
        set -euo pipefail
        kind=''${1:-}
        case "$kind" in
          system)
            marker=${systemMarker}
            unit=neo-auto-update.service
            ;;
          docker)
            marker=${dockerMarker}
            unit=neo-docker-updater.service
            ;;
          *)
            echo "usage: neo-heimcloud-ops-report system|docker" >&2
            exit 2
            ;;
        esac

        TOKEN_FILE=${tokenPath}
        META=${metaPath}
        PLACEHOLDER=${placeholder}
        OPS_URL=${defaultOpsUrl}

        if [ ! -s "$TOKEN_FILE" ]; then
          echo "heimcloud-ops-report: missing token at $TOKEN_FILE — skip"
          exit 0
        fi
        TOKEN=$(tr -d '\n\r' < "$TOKEN_FILE")
        if [ -z "$TOKEN" ] || [ "$TOKEN" = "$PLACEHOLDER" ]; then
          echo "heimcloud-ops-report: placeholder or empty token — skip (sync private repo)"
          exit 0
        fi

        SLUG="unknown"
        if [ -f "$META" ]; then
          SLUG=$(${pkgs.jq}/bin/jq -r '.repo_slug // .customer_repo_slug // "unknown"' "$META")
          U=$(${pkgs.jq}/bin/jq -r '.ops_ingest_url // empty' "$META")
          [ -n "$U" ] && OPS_URL="$U"
        fi
        ${
          if cfg.customerRepoSlug != null
          then ''
            if [ "$SLUG" = "unknown" ]; then SLUG=${lib.escapeShellArg cfg.customerRepoSlug}; fi
          ''
          else ""
        }

        failed=false
        in_progress=false
        if [ -n "$marker" ] && [ -f "$marker" ]; then
          failed=$(${pkgs.jq}/bin/jq -r '.failed // false' "$marker")
          in_progress=$(${pkgs.jq}/bin/jq -r '.in_progress // false' "$marker")
          echo "marker $marker failed=$failed in_progress=$in_progress"
        else
          echo "no marker at ''${marker:-"(unset)"}"
        fi

        unit_failed=false
        if ${pkgs.systemd}/bin/systemctl is-failed --quiet "$unit" 2>/dev/null; then
          unit_failed=true
          echo "$unit is failed"
        fi

        if [ "$failed" != true ] && [ "$in_progress" != true ] && [ "$unit_failed" != true ]; then
          echo "heimcloud-ops-report: no failure — skip"
          exit 0
        fi

        NEO_VERSION="unknown"
        if command -v neo >/dev/null 2>&1; then
          NEO_VERSION=$(neo --version 2>/dev/null | head -1 || true)
          [ -z "$NEO_VERSION" ] && NEO_VERSION="unknown"
        fi

        LOGS=""
        if [ -n "$marker" ] && [ -f "$marker" ]; then
          logf=$(${pkgs.jq}/bin/jq -r '.log // .log_path // empty' "$marker" 2>/dev/null || true)
          if [ -n "$logf" ] && [ -f "$logf" ]; then
            LOGS=$(tail -n 80 "$logf" 2>/dev/null || true)
          fi
        fi
        if [ -z "$LOGS" ]; then
          LOGS=$(${pkgs.systemd}/bin/journalctl -u "$unit" -n 80 --no-pager -o cat 2>/dev/null || true)
        fi
        # Truncate + strip obvious secret-ish lines
        LOGS=$(printf '%s\n' "$LOGS" | ${pkgs.gnused}/bin/sed -E '/(Bearer |Authorization:|api[_-]?key|TOKEN=|PRIVATE)/Id' | head -c 12000)

        HOST=$(hostname -s 2>/dev/null || hostname || echo unknown)
        TARGET="heimcloud-ops-report:$kind:$HOST"
        # Stable-ish hash for dedup within a short window; include marker mtime if present
        MTIME="0"
        if [ -n "$marker" ] && [ -f "$marker" ]; then
          MTIME=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
        fi
        REPORT_HASH=$(printf '%s\n' "$unit|$NEO_VERSION|$SLUG|$MTIME|$failed|$in_progress|$unit_failed" \
          | ${pkgs.coreutils}/bin/sha256sum | awk '{print $1}')

        TMP=$(mktemp)
        ${pkgs.jq}/bin/jq -n \
          --arg report_hash "$REPORT_HASH" \
          --arg neo_version "$NEO_VERSION" \
          --arg unit "$unit" \
          --arg logs_excerpt "$LOGS" \
          --arg customer_repo_slug "$SLUG" \
          --arg severity "error" \
          --arg target_hint "$TARGET" \
          --arg machine "$HOST" \
          '{
            report_hash: $report_hash,
            neo_version: $neo_version,
            unit: $unit,
            logs_excerpt: $logs_excerpt,
            customer_repo_slug: $customer_repo_slug,
            severity: $severity,
            target_hint: $target_hint,
            machine: (if $machine == "" then null else $machine end)
          }' > "$TMP"

        echo "heimcloud-ops-report: POSTing to ops (slug=$SLUG hash=$REPORT_HASH)"
        code=$(${pkgs.curl}/bin/curl -sS -o /tmp/heimcloud-ops-report-resp.json -w '%{http_code}' \
          -X POST "$OPS_URL" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          --data-binary @"$TMP" || echo "000")
        rm -f "$TMP"
        echo "heimcloud-ops-report: HTTP $code"
        if [ -f /tmp/heimcloud-ops-report-resp.json ]; then
          ${pkgs.jq}/bin/jq -c . /tmp/heimcloud-ops-report-resp.json 2>/dev/null || cat /tmp/heimcloud-ops-report-resp.json || true
        fi
        case "$code" in
          200|201) exit 0 ;;
          *) exit 1 ;;
        esac
      '';
    in {
      config = mkIf report {
        environment.systemPackages = [reportScript];

        systemd.services.neo-heimcloud-ops-report-system = mkIf systemUpdaterOn {
          description = "Heimcloud ops ingest on neo-auto-update failure";
          after = ["network-online.target" "neo-auto-update.service"];
          wants = ["network-online.target"];
          path = [pkgs.jq pkgs.curl pkgs.systemd pkgs.coreutils pkgs.gnused pkgs.gnugrep];
          serviceConfig = {
            Type = "oneshot";
            # Root so we can read credentialsPath/ops/ingest.token (0600) and journals.
            User = "root";
            TimeoutStartSec = "2min";
            ExecStart = "${reportScript}/bin/neo-heimcloud-ops-report system";
          };
        };

        systemd.services.neo-heimcloud-ops-report-docker = mkIf dockerUpdaterOn {
          description = "Heimcloud ops ingest on neo-docker-updater failure";
          after = ["network-online.target" "neo-docker-updater.service"];
          wants = ["network-online.target"];
          path = [pkgs.jq pkgs.curl pkgs.systemd pkgs.coreutils pkgs.gnused pkgs.gnugrep];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            TimeoutStartSec = "2min";
            ExecStart = "${reportScript}/bin/neo-heimcloud-ops-report docker";
          };
        };

        systemd.services.neo-auto-update = mkIf systemUpdaterOn {
          onSuccess = ["neo-heimcloud-ops-report-system.service"];
          onFailure = ["neo-heimcloud-ops-report-system.service"];
        };

        systemd.services.neo-docker-updater = mkIf dockerUpdaterOn {
          onSuccess = ["neo-heimcloud-ops-report-docker.service"];
          onFailure = ["neo-heimcloud-ops-report-docker.service"];
        };
      };
    };
}
