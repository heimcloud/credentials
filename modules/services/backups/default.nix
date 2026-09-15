# Backups stub — write rsync.net placeholder only.
{...}: {
  flake.modules.nixos.backups = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.backups;
      stubContent = ''
        # Heimcloud backups / rsync.net stub
        # Replace with real account + SSH key path when provisioned.
        RSYNC_HOST=stub.rsync.net
        RSYNC_USER=stub-user
        RSYNC_MODULE=stub-module
        RSYNC_STATUS=pending_reseller
      '';
    in {
      config = mkIf cfg.enabled {
        systemd.services."neo-credentials-backups-stub" = {
          description = "Write backups credentials stub placeholder";
          wantedBy = ["multi-user.target"];
          before = ["multi-user.target"];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          script = lib.concatStringsSep "\n" [
            (lib.neo.mkActivationScriptForDir config {
              dirPath = cfg.credentialsPath;
            })
            (lib.neo.mkActivationScriptForFile config {
              filePath = "${cfg.credentialsPath}/${cfg.stubFile}";
              content = stubContent;
              mode = "0600";
            })
          ];
        };
      };
    };
}
