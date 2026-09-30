# Optional GitHub fork-push token for Hermes Ops auto-fix loop.
#
# Neo evaluates settings.toml via builtins.fromTOML into config.neo at activate
# time (and copies the file into the store for /etc/neo/settings.toml). This
# module deliberately never interpolates cfg.ops.autofixForkPushToken into any
# derivation, Environment=, or unit script text. Activation reads the live
# settings file path at runtime and writes the value to tmpfs only.
{...}: {
  flake.modules.nixos.credentials-autofix-github = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cfg = config.neo.services.credentials;
      # Store scripts (no secrets) — built by scripts/autofix/package.nix so
      # scripts/autofix/test-local.sh can build and test the exact same thing.
      autofixPkgs = import ../../../scripts/autofix/package.nix {
        inherit pkgs lib;
        owner = hermesUser;
        group = hermesGroup;
      };
      inherit (autofixPkgs) extract helper envWrapper materialize;

      # Owner of the token dir + file: the Hermes gateway user/group
      # (services.hermes-agent.{user,group}, default "hermes"). `or` keeps
      # evaluation working when the hermes-agent module is not imported.
      hermesUser = config.services.hermes-agent.user or "hermes";
      hermesGroup = config.services.hermes-agent.group or "hermes";

      # Only reference the owner in tmpfiles when NixOS actually declares it:
      # systemd-tmpfiles fails the whole run (systemd-tmpfiles-setup /
      # -resetup) on an unknown user/group, which must never happen.
      hermesDeclared =
        (config.users.users ? ${hermesUser})
        && (config.users.groups ? ${hermesGroup});

      tokenDir = "/run/heimcloud-autofix";
      tokenPath = "${tokenDir}/github-token";
    in {
      config = mkIf cfg.enabled {
        # Store scripts only (no secrets). Ops job-queue runner calls the wrapper.
        environment.systemPackages = [envWrapper helper extract];

        # Token dir on tmpfs, owned by the same user/group materialize chowns the
        # token to. tmpfiles re-applies owner/mode at boot and on every switch
        # (systemd-tmpfiles-resetup), so it must match — a root owner here locked
        # hermes out of the token. Falls back to root only when the hermes
        # user/group is not declared (materialize then skips anyway).
        # `d` never touches dir contents (github-token, reserved pr-token).
        systemd.tmpfiles.rules = [
          (
            if hermesDeclared
            then "d ${tokenDir} 0700 ${hermesUser} ${hermesGroup} -"
            else "d ${tokenDir} 0700 root root -"
          )
        ];

        # Run on every switch/boot so settings.toml edits are picked up even when
        # this unit text is unchanged (RemainAfterExit oneshot would skip).
        system.activationScripts.heimcloud-autofix-token = {
          deps = ["users" "etc"];
          text = ''
            ${materialize}
          '';
        };

        # Also expose a oneshot for operators (`systemctl start …`) after manual
        # settings edits without a full switch — same script, still no secret in unit text.
        systemd.services.heimcloud-autofix-materialize-token = {
          description = "Materialize Heimcloud Ops autofix fork-push GitHub token to tmpfs";
          # Activation PATH already has these; plain units do not ship getent.
          path = [pkgs.coreutils pkgs.getent];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${materialize}";
          };
        };

        # Non-secret pointer for operators / docs.
        environment.etc."heimcloud/autofix-token-path".text = ''
          ${tokenPath}
        '';
      };
    };
}
