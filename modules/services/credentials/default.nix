# Write Neo SSH public key (derived from deploy-key private); ensure ops ingest
# placeholder; import config-drop secrets → appdata (0600) and write overlay
# notes for settings.toml (hybrid C).
# Does NOT create parallel neo.services.public_ip / airvpn / backups / hermes_entitlement.
{...}: {
  flake.modules.nixos.credentials = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.credentials;
      howto = ''
        # Heimcloud credentials — register Neo SSH public key
        #
        # Settings → core → plugins → github:heimcloud/credentials
        # Deploy key private path (single source of truth):
        #   ${cfg.deployKeyPrivateKeyPath}
        # Public material is derived on activation to:
        #   ${cfg.credentialsPath}/neo-ssh.pub
        # Then (HQ/ops token for now):
        #
        #   export PROVISIONING_API_TOKEN=…
        #   node scripts/register-ssh-key.mjs --customer-id ${cfg.customerId or "<id>"} \
        #     --public-key-file ${cfg.credentialsPath}/neo-ssh.pub
        #
        # Rotate by rotating the homeserver key (neo-homeserver-ssh-key rotate)
        # and re-submitting the derived public key. Old deploy keys are removed.
        # Repos stay private. Never commit or upload the private key.
        #
        # Config drop (layout_version 2) syncs into this tree. Secrets land in
        # appdata mode 0600; apply non-secrets via settings.toml — see
        # neo-credentials-overlay.md after import.
      '';
      uid = toString config.neo.core.uid;
      gid = toString config.neo.core.gid;
      dropRoot =
        if cfg.syncDir != null
        then cfg.syncDir
        else cfg.credentialsPath;
      dest = cfg.credentialsPath;
      reconcileScript = ../../../scripts/reconcile-deploy-key.sh;
      expectedPubFile =
        if cfg.neoSshPublicKey != null
        then
          pkgs.writeText "neo-ssh-expected.pub" (cfg.neoSshPublicKey + "\n")
        else null;
    in {
      config = mkIf cfg.enabled {
        assertions = [
          {
            assertion = !(cfg.sync.enable && cfg.customerRepoSlug == null);
            message = "neo.services.credentials.sync.enable requires customerRepoSlug (set only in machine-local settings).";
          }
          {
            assertion = !(cfg.sync.enable && cfg.syncDir == null);
            message = "neo.services.credentials.sync.enable requires syncDir (git working tree, e.g. appdata/credentials-sync).";
          }
          {
            assertion = !(cfg.sync.enable && cfg.sync.knownHosts == null);
            message = "neo.services.credentials.sync.enable requires sync.knownHosts (pinned SSH host key for StrictHostKeyChecking=yes).";
          }
        ];

        systemd.services."neo-credentials-ssh-pubkey" = {
          description = "Reconcile Heimcloud Neo deploy-key public material from private key";
          wantedBy = ["multi-user.target"];
          before = ["multi-user.target"];
          after = ["local-fs.target"];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          path = [pkgs.coreutils pkgs.openssh pkgs.gawk pkgs.gnused];
          script = lib.concatStringsSep "\n" (
            [
              (lib.neo.mkActivationScriptForDir config {
                dirPath = cfg.credentialsPath;
              })
              (lib.neo.mkActivationScriptForDir config {
                dirPath = "${cfg.credentialsPath}/ops";
              })
              (lib.neo.mkActivationScriptForFile config {
                filePath = "${cfg.credentialsPath}/REGISTER-SSH-KEY.txt";
                content = howto;
                mode = "0644";
              })
              # Placeholder only if missing — never clobber a token synced from the private repo.
              ''
                token="${cfg.credentialsPath}/ops/ingest.token"
                if [ ! -f "$token" ]; then
                  printf '%s\n' 'replace-from-private-repo' > "$token"
                  chown ${uid}:${gid} "$token"
                  chmod 0600 "$token"
                fi
              ''
              # Single source of truth: derive neo-ssh.pub from deployKeyPrivateKeyPath.
              # Fail loudly if neoSshPublicKey or orphan credentials/neo-ssh diverge.
              ''
                export CREDENTIALS_DEPLOY_KEY=${lib.escapeShellArg cfg.deployKeyPrivateKeyPath}
                export CREDENTIALS_PUB_OUT=${lib.escapeShellArg "${cfg.credentialsPath}/neo-ssh.pub"}
                export CREDENTIALS_ORPHAN_PRIVATE=${lib.escapeShellArg "${cfg.credentialsPath}/neo-ssh"}
                export CREDENTIALS_SSH_KEYGEN=${lib.escapeShellArg "${pkgs.openssh}/bin/ssh-keygen"}
                ${optionalString (expectedPubFile != null) ''
                  export CREDENTIALS_EXPECTED_PUB=${lib.escapeShellArg expectedPubFile}
                ''}
                ${pkgs.bash}/bin/bash ${reconcileScript}
                chown ${uid}:${gid} "$CREDENTIALS_PUB_OUT" || true
              ''
            ]
          );
        };

        systemd.services."neo-credentials-overlay-import" = mkIf cfg.importOverlay {
          description = "Import Heimcloud config-drop secrets to appdata (hybrid C)";
          wantedBy = ["multi-user.target"];
          after = ["neo-credentials-ssh-pubkey.service"];
          before = ["multi-user.target"];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          path = [pkgs.coreutils pkgs.gnused pkgs.gawk];
          script = ''
            set -euo pipefail
            DROP="${dropRoot}"
            DEST="${dest}"
            UID_="${uid}"
            GID_="${gid}"

            mkdir -p "$DEST" "$DEST/ops" "$DEST/rathole" "$DEST/vpn" "$DEST/swag" "$DEST/backup" "$DEST/hermes" "$DEST/heimcloud"
            chown "$UID_:$GID_" "$DEST" "$DEST/ops" "$DEST/rathole" "$DEST/vpn" "$DEST/swag" "$DEST/backup" "$DEST/hermes" "$DEST/heimcloud"

            # Copy a file if present; secrets get 0600. Never invent fake neo.services stubs.
            # When DROP == DEST (syncDir defaults to credentialsPath), skip install —
            # same-file would fail with "… and itself are the same file".
            copy_secret() {
              local src="$1" dst="$2"
              if [ -f "$src" ]; then
                if [ "$src" = "$dst" ]; then
                  chown "$UID_:$GID_" "$dst" || true
                  chmod 0600 "$dst" || true
                else
                  install -m 0600 -o "$UID_" -g "$GID_" "$src" "$dst"
                fi
              fi
            }
            copy_plain() {
              local src="$1" dst="$2"
              if [ -f "$src" ]; then
                if [ "$src" = "$dst" ]; then
                  chown "$UID_:$GID_" "$dst" || true
                  chmod 0644 "$dst" || true
                else
                  install -m 0644 -o "$UID_" -g "$GID_" "$src" "$dst"
                fi
              fi
            }

            copy_secret "$DROP/ops/ingest.token" "$DEST/ops/ingest.token"

            copy_secret "$DROP/rathole/settings.env" "$DEST/rathole/settings.env"
            copy_secret "$DROP/vpn/settings.env" "$DEST/vpn/settings.env"
            copy_plain "$DROP/swag/domain.txt" "$DEST/swag/domain.txt"
            copy_plain "$DROP/swag/email.txt" "$DEST/swag/email.txt"
            copy_secret "$DROP/backup/settings.env" "$DEST/backup/settings.env"
            copy_secret "$DROP/hermes/llm.env" "$DEST/hermes/llm.env"
            copy_plain "$DROP/heimcloud/neo_ssh_public_key.pub" "$DEST/heimcloud/neo_ssh_public_key.pub"
            copy_plain "$DROP/meta.json" "$DEST/meta.json"
            copy_plain "$DROP/layout_version" "$DEST/layout_version"

            # Operator summary — document neo.services.* keys; do not invent stub services.
            OVERLAY="$DEST/neo-credentials-overlay.md"
            {
              echo "# Neo credentials overlay (hybrid C)"
              echo
              echo "Generated by neo-credentials-overlay-import. Secrets live under"
              echo "\`$DEST\` (mode 0600). Apply non-secrets in settings.toml / Neo UI."
              echo
              echo "| Drop file | Neo target | Notes |"
              echo "|-----------|------------|--------|"
              echo "| \`rathole/settings.env\` | \`neo.services.rathole\` | TOKEN→token, REMOTE_ADDR→remoteAddr, PORT→port, NAME→name, CERTIFICATE_ONLY→certificateOnly |"
              echo "| \`vpn/settings.env\` | \`neo.services.vpn\` | VPN_SERVICE_PROVIDER→vpnServiceProvider, WIREGUARD_*→wireguard*, SERVER_COUNTRIES→serverCountries |"
              echo "| \`swag/domain.txt\` | \`neo.services.swag.domain\` | plain text |"
              echo "| \`swag/email.txt\` | \`neo.services.swag.email\` | plain text |"
              echo "| \`backup/settings.env\` | \`neo.services.backup\` | HOST→host, USER→user, SSH_KEY_PATH→sshKey (mkSshConnectionOptions) |"
              echo "| \`hermes/llm.env\` | \`neo.services.hermes.llm\` | PROVIDER→provider, API_KEY→apiKey, MODEL→model (**core** Hermes) |"
              echo "| \`ops/ingest.token\` | appdata credentials/ops | skill **heimcloud-ops-ingest** Bearer |"
              echo
              echo "## Detected drop"
              if [ -f "$DROP/layout_version" ]; then
                echo "- layout_version: \`$(tr -d '\n' < "$DROP/layout_version")\`"
              else
                echo "- layout_version: (missing)"
              fi
              if [ -f "$DROP/meta.json" ]; then
                echo "- meta.json present"
              fi
              for f in rathole/settings.env vpn/settings.env swag/domain.txt swag/email.txt backup/settings.env hermes/llm.env ops/ingest.token; do
                if [ -f "$DROP/$f" ]; then echo "- present: \`$f\`"; else echo "- absent: \`$f\`"; fi
              done
              echo
              echo "Shop SKUs \`public_ip|airvpn|backups|hermes\` map to folders \`rathole|vpn|backup|hermes\`."
              echo "Do **not** enable removed plugin stubs (public_ip, airvpn, backups, hermes_entitlement)."
            } > "$OVERLAY"
            chown "$UID_:$GID_" "$OVERLAY"
            chmod 0644 "$OVERLAY"

            # Optional imported.env with non-secret keys only (no API keys / tokens).
            IMPORTED="$DEST/imported.env"
            {
              echo "# Non-secret hints from config drop — apply via Neo settings (hybrid C)"
              echo "# Secrets remain in */settings.env and hermes/llm.env (0600); do not paste them here."
              if [ -f "$DEST/swag/domain.txt" ]; then
                echo "SWAG_DOMAIN=$(tr -d '\n' < "$DEST/swag/domain.txt")"
              fi
              if [ -f "$DEST/swag/email.txt" ]; then
                echo "SWAG_EMAIL=$(tr -d '\n' < "$DEST/swag/email.txt")"
              fi
              if [ -f "$DEST/rathole/settings.env" ]; then
                grep -E '^(REMOTE_ADDR|PORT|NAME|CERTIFICATE_ONLY)=' "$DEST/rathole/settings.env" 2>/dev/null || true
              fi
              if [ -f "$DEST/vpn/settings.env" ]; then
                grep -E '^(VPN_SERVICE_PROVIDER|SERVER_COUNTRIES|FIREWALL_VPN_INPUT_PORTS)=' "$DEST/vpn/settings.env" 2>/dev/null || true
              fi
              if [ -f "$DEST/backup/settings.env" ]; then
                grep -E '^(HOST|USER)=' "$DEST/backup/settings.env" 2>/dev/null || true
              fi
              if [ -f "$DEST/hermes/llm.env" ]; then
                grep -E '^(PROVIDER|MODEL)=' "$DEST/hermes/llm.env" 2>/dev/null || true
              fi
            } > "$IMPORTED"
            chown "$UID_:$GID_" "$IMPORTED"
            chmod 0644 "$IMPORTED"
          '';
        };
      };
    };
}
