# Optional timer: git-fetch private customer credentials repo over SSH deploy key.
# Off by default (sync.enable = false) until Gitea SSH is reachable on the edge.
{...}: {
  flake.modules.nixos.credentials-sync = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.credentials;
      syncCfg = cfg.sync;
      uid = toString config.neo.core.uid;
      gid = toString config.neo.core.gid;
      syncScript = ../../../scripts/sync-customer-repo.sh;
      knownHostsFile =
        if syncCfg.knownHosts != null
        then pkgs.writeText "gitea-ssh.known_hosts" (syncCfg.knownHosts + "\n")
        else null;
      # ssh://git@host:port/customers/<slug>.git — slug from machine-local settings only.
      gitUrl = "ssh://${syncCfg.remoteUser}@${syncCfg.remoteHost}:${toString syncCfg.remotePort}/customers/${cfg.customerRepoSlug or "UNSET"}.git";
      statusFile = "${cfg.credentialsPath}/sync-status";
    in {
      config = mkIf (cfg.enabled && syncCfg.enable) {
        systemd.services."neo-credentials-sync" = {
          description = "Sync Heimcloud private credentials repo (deploy key over SSH)";
          after = [
            "network-online.target"
            "neo-credentials-ssh-pubkey.service"
            "neo-credentials-deploy-key.service"
          ];
          wants = ["network-online.target"];
          serviceConfig = {
            Type = "oneshot";
            # Soft failures exit 0 inside the script; hard misconfig exits 1.
            # Runs as root so it can start overlay-import; chowns to homeserver.
          };
          path = [
            pkgs.coreutils
            pkgs.openssh
            pkgs.git
            pkgs.rsync
            pkgs.systemd
          ];
          environment = {
            CREDENTIALS_SYNC_DIR = cfg.syncDir;
            CREDENTIALS_DEST_DIR = cfg.credentialsPath;
            CREDENTIALS_DEPLOY_KEY = cfg.deployKeyPrivateKeyPath;
            CREDENTIALS_GIT_URL = gitUrl;
            CREDENTIALS_KNOWN_HOSTS = toString knownHostsFile;
            CREDENTIALS_SSH_BIN = "${pkgs.openssh}/bin/ssh";
            CREDENTIALS_GIT_BIN = "${pkgs.git}/bin/git";
            CREDENTIALS_RSYNC_BIN = "${pkgs.rsync}/bin/rsync";
            CREDENTIALS_OVERLAY_UNIT = "neo-credentials-overlay-import.service";
            CREDENTIALS_STATUS_FILE = statusFile;
            CREDENTIALS_UID = uid;
            CREDENTIALS_GID = gid;
          };
          script = ''
            set -euo pipefail
            # homeserver must read the deploy key and write sync/credentials dirs.
            exec ${pkgs.bash}/bin/bash ${syncScript}
          '';
        };

        systemd.timers."neo-credentials-sync" = {
          description = "Timer for Heimcloud credentials repo sync";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = syncCfg.schedule;
            Persistent = true;
            Unit = "neo-credentials-sync.service";
          };
        };

        # Ensure syncDir exists with homeserver ownership (Fleet may pre-create).
        systemd.tmpfiles.rules = [
          "d ${cfg.syncDir} 0700 ${uid} ${gid} -"
          "d ${cfg.credentialsPath} 0755 ${uid} ${gid} -"
        ];
      };
    };
}
