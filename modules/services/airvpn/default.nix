# AirVPN stub — write config placeholder only.
{...}: {
  flake.modules.nixos.airvpn = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.airvpn;
      stubContent = ''
        # Heimcloud AirVPN config stub
        # Replace with real .ovpn / WireGuard profile when provisioned.
        # remote stub.airvpn.example 1194
        AIRVPN_STATUS=pending_reseller
      '';
    in {
      config = mkIf cfg.enabled {
        systemd.services."neo-credentials-airvpn-stub" = {
          description = "Write AirVPN credentials stub placeholder";
          wantedBy = ["multi-user.target"];
          before = ["multi-user.target"];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          script = lib.concatStringsSep "\n" [
            (lib.neo.mkActivationScriptForDir config {
              dirPath = cfg.credentialsPath;
            })
            (lib.neo.mkActivationScriptForFile config {
              filePath = "${cfg.credentialsPath}/${cfg.configFile}";
              content = stubContent;
              mode = "0600";
            })
          ];
        };
      };
    };
}
