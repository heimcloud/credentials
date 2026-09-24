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
      scriptsDir = ../../../scripts/autofix;

      # Strip the repo shebang; pin python3 from pkgs so PATH is enough.
      extractBody = let
        raw = builtins.readFile (scriptsDir + "/extract-token.py");
        lines = splitString "\n" raw;
        body =
          if lines != [] && hasPrefix "#!" (head lines)
          then concatStringsSep "\n" (tail lines)
          else raw;
      in
        body;

      extract = pkgs.writeScriptBin "heimcloud-autofix-extract-token" ''
        #!${pkgs.python3}/bin/python3
        ${extractBody}
      '';

      helper = pkgs.writeShellScriptBin "heimcloud-autofix-git-credential" (
        builtins.readFile (scriptsDir + "/git-credential-helper.sh")
      );

      gitconfig = pkgs.writeText "heimcloud-autofix.gitconfig" (
        replaceStrings
        ["@helper@"]
        ["${helper}/bin/heimcloud-autofix-git-credential"]
        (builtins.readFile (scriptsDir + "/gitconfig.in"))
      );

      envWrapper = pkgs.writeShellScriptBin "heimcloud-autofix-env" (
        replaceStrings
        ["@gitconfig@"]
        ["${gitconfig}"]
        (builtins.readFile (scriptsDir + "/heimcloud-autofix-env.sh"))
      );

      materialize = pkgs.writeShellScript "heimcloud-autofix-materialize" (
        replaceStrings
        ["@extract@"]
        ["${extract}/bin/heimcloud-autofix-extract-token"]
        (builtins.readFile (scriptsDir + "/materialize.sh"))
      );

      tokenPath = "/run/heimcloud-autofix/github-token";
    in {
      config = mkIf cfg.enabled {
        # Store scripts only (no secrets). Ops job-queue runner calls the wrapper.
        environment.systemPackages = [envWrapper helper extract];

        # Placeholder dir on tmpfs; materialize re-chowns to hermes when that user exists.
        systemd.tmpfiles.rules = [
          "d /run/heimcloud-autofix 0700 root root -"
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
