# Write local copy of the configured Neo SSH public key (never a private key).
# Also ensure ops/ ingest token placeholder exists without clobbering synced secrets.
{...}: {
  flake.modules.nixos.credentials = {
    config,
    lib,
    ...
  }:
    with lib; let
      cfg = config.neo.services.credentials;
      howto = ''
        # Heimcloud credentials — register Neo SSH public key
        #
        # Settings → core → plugins → github:heimcloud/credentials
        # Set neo.services.credentials.neoSshPublicKey to your OpenSSH public key.
        # Then (HQ/ops token for now):
        #
        #   export PROVISIONING_API_TOKEN=…
        #   node scripts/register-ssh-key.mjs --customer-id ${cfg.customerId or "<id>"} \
        #     --public-key-file ${cfg.credentialsPath}/neo-ssh.pub
        #
        # Rotate by re-submitting a new public key. Old deploy keys are removed.
        # Repos stay private. Never commit or upload the private key.
      '';
      uid = toString config.neo.core.uid;
      gid = toString config.neo.core.gid;
    in {
      config = mkIf cfg.enabled {
        systemd.services."neo-credentials-ssh-pubkey" = {
          description = "Write Heimcloud Neo SSH public key placeholder / copy";
          wantedBy = ["multi-user.target"];
          before = ["multi-user.target"];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          script = lib.concatStringsSep "\n" (
            [
              (lib.neo.mkActivationScriptForDir config {
                dirPath = cfg.credentialsPath;
              })
              (lib.neo.mkActivationScriptForDir config {
                dirPath = "${cfg.credentialsPath}/ops";
              })
              (lib.neo.mkActivationScriptForFile config {
                filePath = "${cfg.credentialsPath}/REGISTER-SSH-KEY.txt";
                content = howto;
                mode = "0644";
              })
              # Placeholder only if missing — never clobber a token synced from the private repo.
              ''
                token="${cfg.credentialsPath}/ops/ingest.token"
                if [ ! -f "$token" ]; then
                  printf '%s\n' 'replace-from-private-repo' > "$token"
                  chown ${uid}:${gid} "$token"
                  chmod 0600 "$token"
                fi
              ''
            ]
            ++ lib.optional (cfg.neoSshPublicKey != null) (
              lib.neo.mkActivationScriptForFile config {
                filePath = "${cfg.credentialsPath}/neo-ssh.pub";
                content = cfg.neoSshPublicKey + "\n";
                mode = "0644";
              }
            )
          );
        };
      };
    };
}
