# Hermes stub — write placeholder token file only (no reseller API).
{...}: {
  flake.modules.nixos.hermes = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.hermes;
      stubContent = ''
        # Heimcloud Hermes token stub
        # Replace with real xAI / Hermes credentials when provisioned.
        # DO NOT commit real secrets to git.
        HERMES_API_KEY=stub-replace-me
        HERMES_STATUS=pending_reseller
      '';
    in {
      config = mkIf cfg.enabled {
        systemd.services."neo-credentials-hermes-stub" = {
          description = "Write Hermes credentials stub placeholder";
          wantedBy = ["multi-user.target"];
          before = ["multi-user.target"];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          script = lib.concatStringsSep "\n" [
            (lib.neo.mkActivationScriptForDir config {
              dirPath = cfg.credentialsPath;
            })
            (lib.neo.mkActivationScriptForFile config {
              filePath = "${cfg.credentialsPath}/${cfg.tokenFile}";
              content = stubContent;
              mode = "0600";
            })
          ];
        };
      };
    };
}
