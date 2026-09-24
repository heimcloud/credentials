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
              ops = mkOption {
                type = types.submodule {
                  options = {
                    autofixForkPushToken = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = ''
                        Optional fine-grained GitHub token for the Hermes Ops
                        auto-fix loop to **push fix branches to heimcloud/neo
                        only**. Materialized at runtime to
                        `/run/heimcloud-autofix/github-token` (hermes, 0400,
                        tmpfs). This plugin never interpolates the value into
                        the Nix store, unit Environment=, or journal output.
                        Null / unset = feature off (triage-only fallback).
                        Prefer a fine-grained token with contents:write on
                        heimcloud/neo only — not an account SSH key (which
                        could push to heimcloud/credentials main).
                      '';
                      rank = 10;
                    };
                  };
                };
                default = {};
                description = ''
                  Heimcloud Ops host settings (auto-fix GitHub credentials).
                  Customer Neos leave this empty.
                '';
                rank = 60;
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
            # Neo#2 owns publish via getSkillServices → skillsTree + hermes-neo-skills
            # (AGENTS.md, external_dirs, HERMES_HOME symlink). Explicit true.
            // lib.neo.mkSkillOptions {enabled = true;};
        };
        default = {};
        description = "Heimcloud credentials / config-drop importer + Neo SSH public key";
      };
    };
}
