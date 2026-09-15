# AirVPN — entitlement stub for Neo.
{...}: {
  flake.modules.nixos.airvpn-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.airvpn = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "AirVPN config stub" {rank = 0;};
              credentialsPath = mkOption {
                type = types.str;
                default = "${config.neo.core.volumes.appdata}/credentials/airvpn";
                description = "Directory for AirVPN config stubs.";
                rank = 10;
              };
              configFile = mkOption {
                type = types.str;
                default = "config.stub";
                description = "Relative filename under credentialsPath.";
                rank = 20;
              };
            }
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/credentials/airvpn"
            // lib.neo.mkServiceMeta {
              category = "Credentials/VPN";
              description = ''
                AirVPN entitlement stub. Writes a local OpenVPN/WireGuard
                placeholder until reseller APIs are wired. No outbound API calls.
              '';
              projectUrl = "https://github.com/heimcloud/credentials";
              githubUrl = "https://github.com/heimcloud/credentials";
            };
        };
        default = {};
        description = "AirVPN credentials stub";
      };
    };
}
