# Public IP stub — write Hostkey placeholder only.
{...}: {
  flake.modules.nixos.public-ip = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.public_ip;
      stubContent = ''
        # Heimcloud public IP / Hostkey stub
        # Replace with real dedicated IP assignment when provisioned.
        HOSTKEY_SERVER_ID=stub
        PUBLIC_IPV4=0.0.0.0
        PUBLIC_IP_STATUS=pending_reseller
      '';
    in {
      config = mkIf cfg.enabled {
        systemd.services."neo-credentials-public-ip-stub" = {
          description = "Write public_ip credentials stub placeholder";
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
