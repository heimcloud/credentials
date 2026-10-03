# Heimcloud credentials — Neo SSH public key + private config-drop sync/import.
{...}: {
  flake.modules.nixos.credentials-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      # The Hermes skill moved to reporter.neo (neo.services.reporter.skill).
      # A leftover [services.credentials.skill] in settings.toml would otherwise
      # fail evaluation ("option does not exist") and stop auto-updates; keep a
      # hidden catch-all and warn instead.
      config.warnings = lib.optional (config.neo.services.credentials.skill != {}) ''
        neo.services.credentials.skill is ignored: the heimcloud-ops-ingest skill
        is now provided by reporter.neo. Use [services.reporter.skill] instead and
        delete [services.credentials.skill] from settings.toml.
      '';
      # Removed: services.credentials.ops.autofixForkPushToken (moved to
      # autofix.neo). Kept as a hidden catch-all so other plugins can still
      # probe `cred.ops.<key> or null`, and so a leftover key fails with a
      # pointer instead of "option does not exist". (mkRemovedOptionModule
      # cannot reach into this submodule.)
      config.assertions = [
        {
          assertion = !(config.neo.services.credentials.ops ? autofixForkPushToken);
          message = ''
            neo.services.credentials.ops.autofixForkPushToken has been removed:
            the autofix GitHub token now belongs to the autofix.neo plugin. Set
            [services.autofix.github] tokenFile (preferred) or token, then drop
            [services.credentials.ops] from settings.toml.
          '';
        }
      ];
      options.neo.services.credentials = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Heimcloud credentials (config drop sync + Neo SSH deploy-key registration)" {rank = 0;};
              neoSshPublicKey = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Optional OpenSSH **public** key expected to match
                  `deployKeyPrivateKeyPath`. Soft consistency check only
                  (WARNING + `.deploy-key-status`); never fails activation.
                  When the private key exists, `neo-ssh.pub` is derived via
                  `ssh-keygen -y`. Never a private key. Rotate by rotating
                  the homeserver key (or the configured private path) and
                  re-running scripts/register-ssh-key.mjs with the derived pub.
                '';
                rank = 10;
              };
              deployKeyPrivateKeyPath = mkOption {
                type = types.str;
                default = "/home/homeserver/.ssh/id_ed25519";
                description = ''
                  Single source of truth for this machine's Gitea deploy-key
                  **private** key. Defaults to the Neo homeserver key created
                  by core activation. When present, public material under
                  credentialsPath (`neo-ssh.pub`) is derived from this file
                  by `neo-credentials-deploy-key` (soft warnings only; never
                  fails the unit). Do not invent a parallel
                  `credentials/neo-ssh` private key — an orphan mismatch is
                  warned and left in place.
                '';
                rank = 15;
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
                  base32 id). Sent as the incident reporter id (reporter.neo), the
                  optional sync timer, and documented in meta.json / overlay
                  summary. Set only in machine-local settings — never commit a
                  real slug.
                '';
                rank = 25;
              };
              skill = lib.mkOption {
                type = types.attrsOf types.anything;
                default = {};
                internal = true;
                visible = false;
                description = "Removed: the Hermes skill is provided by reporter.neo (services.reporter.skill). Any key here is ignored with a warning.";
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
                  deploy-key sync into appdata). When `sync.enable` is true this
                  path is required (git working tree; e.g. appdata/credentials-sync).
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
              sync = mkOption {
                type = types.submodule {
                  options = {
                    enable = mkEnableOption ''
                      Periodically git-fetch the private customer credentials
                      repo over SSH (deploy key) into syncDir, rsync into
                      credentialsPath, and run overlay-import. Off by default
                      until Gitea SSH on the edge is reachable. Requires
                      customerRepoSlug and syncDir.
                    '' {rank = 0;};
                    remoteHost = mkOption {
                      type = types.str;
                      default = "git.heimcloud.site";
                      description = "Gitea SSH hostname (SSH_DOMAIN).";
                      rank = 10;
                    };
                    remotePort = mkOption {
                      type = types.port;
                      default = 2222;
                      description = "Gitea SSH port advertised to clients (SSH_PORT).";
                      rank = 20;
                    };
                    remoteUser = mkOption {
                      type = types.str;
                      default = "git";
                      description = "SSH user for Gitea (usually git).";
                      rank = 30;
                    };
                    schedule = mkOption {
                      type = types.str;
                      default = "*:0/15";
                      description = "systemd OnCalendar expression for the sync timer.";
                      rank = 40;
                    };
                    knownHosts = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = ''
                        Pinned SSH host-key line(s) for remoteHost (contents of a
                        known_hosts entry, e.g. from ssh-keyscan -p 2222). Required
                        when sync.enable is true — StrictHostKeyChecking=yes.
                        Never commit a private key here.
                      '';
                      rank = 50;
                    };
                  };
                };
                default = {};
                description = "Optional automatic pull of the private customer credentials repo.";
                rank = 55;
              };
              ops = lib.mkOption {
                type = types.attrsOf types.anything;
                default = {};
                internal = true;
                visible = false;
                description = "Removed (autofix token moved to autofix.neo). Any key here fails evaluation with a pointer.";
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
            };
        };
        default = {};
        description = "Heimcloud credentials / config-drop importer + Neo SSH public key";
      };
    };
}
