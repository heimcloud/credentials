# Heimcloud credentials — Neo SSH public key registration (deploy-key access).
{...}: {
  flake.modules.nixos.credentials-option = {
    config,
    lib,
    ...
  }:
    with lib;
    with {inherit (lib.neo) mkOption mkEnableOption;}; {
      options.neo.services.credentials = mkOption {
        type = types.submodule {
          options =
            {
              enabled = mkEnableOption "Heimcloud credentials (Neo SSH deploy-key registration)" {rank = 0;};
              neoSshPublicKey = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  OpenSSH **public** key for read-only Gitea deploy-key access
                  to this customer's private credentials repo. Never a private
                  key. Rotate by setting a new value and re-running
                  scripts/register-ssh-key.mjs.
                '';
                rank = 10;
              };
              customerId = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Heimcloud Shop customer id used when registering the SSH public key.";
                rank = 20;
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
                description = "Directory for local credential stubs and the registered public key copy.";
                rank = 40;
              };
            }
            // lib.neo.mkAppdata "${config.neo.core.volumes.appdata}/credentials"
            // lib.neo.mkServiceMeta {
              category = "Credentials";
              description = ''
                Register this Neo's SSH public key with Heimcloud so Shop/Credentials
                can attach a read-only Gitea deploy key to the private customer repo.
                Does not store or upload private keys.
              '';
              projectUrl = "https://github.com/heimcloud/credentials";
              githubUrl = "https://github.com/heimcloud/credentials";
            }
            // lib.neo.mkSkillOptions {enabled = true;};
        };
        default = {};
        description = "Heimcloud credentials / Neo SSH public key";
      };
    };
}
