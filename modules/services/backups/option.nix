# Backups (rsync.net later) — entitlement stub for Neo.
{...}: {
  flake.modules.nixos.backups-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.backups = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Backups / rsync.net stub" {rank = 0;};
              credentialsPath = mkOption {
                type = types.str;
                default = "${config.neo.core.volumes.appdata}/credentials/backups";
                description = "Directory for rsync.net stub credentials.";
                rank = 10;
              };
              stubFile = mkOption {
                type = types.str;
                default = "rsync.stub";
                description = "Relative filename under credentialsPath.";
                rank = 20;
              };
            }
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/credentials/backups"
            // lib.neo.mkServiceMeta {
              category = "Credentials/Backups";
              description = ''
                Backups entitlement stub. Local rsync.net placeholder until
                reseller provisioning is wired. No outbound API calls.
              '';
              projectUrl = "https://github.com/heimcloud/credentials";
              githubUrl = "https://github.com/heimcloud/credentials";
            };
        };
        default = {};
        description = "Backups (rsync.net) credentials stub";
      };
    };
}
