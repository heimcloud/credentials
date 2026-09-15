# Hermes (xAI tokens later) — entitlement stub for Neo.
{...}: {
  flake.modules.nixos.hermes-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.hermes = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Hermes AI token stub (xAI reseller later)" {rank = 0;};
              credentialsPath = mkOption {
                type = types.str;
                default = "${config.neo.core.volumes.appdata}/credentials/hermes";
                description = "Directory for Hermes token stubs (customer credentials repo or local placeholders).";
                rank = 10;
              };
              tokenFile = mkOption {
                type = types.str;
                default = "token.stub";
                description = "Relative filename under credentialsPath for the token stub.";
                rank = 20;
              };
            }
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/credentials/hermes"
            // lib.neo.mkServiceMeta {
              category = "Credentials/AI";
              description = ''
                Hermes entitlement stub. Writes a local token placeholder until
                xAI reseller APIs are wired. No outbound API calls.
              '';
              projectUrl = "https://github.com/heimcloud/credentials";
              githubUrl = "https://github.com/heimcloud/credentials";
            };
        };
        default = {};
        description = "Hermes (xAI) credentials stub";
      };
    };
}
