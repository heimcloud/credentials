# Public IP (Hostkey later) — entitlement stub for Neo.
{...}: {
  flake.modules.nixos.public-ip-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.public_ip = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Public IP / Hostkey stub" {rank = 0;};
              credentialsPath = mkOption {
                type = types.str;
                default = "${config.neo.core.volumes.appdata}/credentials/public_ip";
                description = "Directory for Hostkey / public IP stubs.";
                rank = 10;
              };
              stubFile = mkOption {
                type = types.str;
                default = "hostkey.stub";
                description = "Relative filename under credentialsPath.";
                rank = 20;
              };
            }
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/credentials/public_ip"
            // lib.neo.mkServiceMeta {
              category = "Credentials/Network";
              description = ''
                Public IP entitlement stub (Hostkey later). Local placeholder
                only — no outbound reseller API calls.
              '';
              projectUrl = "https://github.com/heimcloud/credentials";
              githubUrl = "https://github.com/heimcloud/credentials";
            };
        };
        default = {};
        description = "Public IP (Hostkey) credentials stub";
      };
    };
}
