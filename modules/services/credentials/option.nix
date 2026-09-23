# Heimcloud credentials — Neo SSH public key + private config-drop sync/import.
{...}: {
  flake.modules.nixos.credentials-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.credentials = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Heimcloud credentials (config drop sync + Neo SSH deploy-key registration)" {rank = 0;};
              neoSshPublicKey = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  OpenSSH **public** key for read-only Gitea deploy-key access
                  to this customer's private credentials repo. Never a private
                  key. Rotate by setting a new value and re-running
                  scripts/register-ssh-key.mjs.
                '';
                rank = 10;
              };
              customerId = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Heimcloud Shop customer id used when registering the SSH public key.";
                rank = 20;
              };
              customerRepoSlug = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Private Gitea repo slug under `customers/<slug>` (Shop Crockford
                  base32 id). Used by Hermes skill heimcloud-ops-ingest and
                  documented in meta.json / overlay summary.
                '';
                rank = 25;
              };
              shopBaseUrl = mkOption {
                type = types.str;
                default = "https://shop.heimcloud.site";
                description = "Shop origin for POST /api/internal/provisioning/customers/:id/ssh-key.";
                rank = 30;
              };
              credentialsPath = mkOption {
                type = types.str;
                default = "${config.neo.core.volumes.appdata}/credentials";
                description = ''
                  Appdata directory for synced secrets (mode 0600) and overlay
                  notes. Target for the config-drop importer.
                '';
                rank = 40;
              };
              syncDir = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Optional path to a checked-out / rsynced private customer
                  config-drop tree (layout_version 2). When null, the importer
                  looks for the drop under `credentialsPath` itself (after
                  deploy-key sync into appdata).
                '';
                rank = 45;
              };
              importOverlay = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  When true, oneshot imports secrets from the drop into
                  credentialsPath (0600) and writes neo-credentials-overlay.md
                  summarizing non-secret settings.toml keys (hybrid C).
                '';
                rank = 50;
              };
              reportUpdateFailures = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  When true, hook neo-auto-update / neo-docker-updater to a
                  deterministic oneshot that POSTs failures to Heimcloud ops
                  (`ops/ingest.token`) without waiting on Hermes LLM. Skill
                  heimcloud-ops-ingest remains for manual operator reports.
                '';
                rank = 55;
              };
            }
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/credentials"
            // lib.neo.mkServiceMeta {
              category = "Credentials";
              description = ''
                Sync Heimcloud private customer config-drop into Neo: secrets →
                appdata files (0600); document neo.services.* keys for
                settings.toml. Registers this Neo's SSH public key as a
                read-only Gitea deploy key. Does not invent parallel entitlement
                stub services.
              '';
              projectUrl = "https://github.com/heimcloud/credentials";
              githubUrl = "https://github.com/heimcloud/credentials";
            }
            // lib.neo.mkSkillOptions {enabled = true;};
        };
        default = {};
        description = "Heimcloud credentials / config-drop importer + Neo SSH public key";
      };
    };
}
