# Durable Hermes publish path for heimcloud-ops-ingest.
#
# Neo publishes plugin skills only via services.hermes-agent.settings.skills.external_dirs
# (neo-hermes-skills store tree). Hermes -s NAME resolves through skill_view(), which
# *should* scan external_dirs — but Fleet labs (hattori/thatch) saw the skill in the
# store tree while `~/.hermes/skills` lacked it, and `hermes … -s heimcloud-ops-ingest`
# failed closed (ValueError). Operators and tips also inspect HERMES_HOME/skills.
#
# Until Neo materializes the whole skillsTree into HERMES_HOME/skills, this plugin
# symlinks our owned skill name into the local skills dir (rebuild-stable store
# target, hermes:hermes). Do not edit SOUL.md; no competing oneshot.
{...}: {
  flake.modules.nixos.credentials-skill-materialize = {
    config,
    lib,
    pkgs,
    ...
  }:
    with lib; let
      cred = config.neo.services.credentials;
      hermes = config.neo.services.hermes;
      skillConf = cred.skill.conf or null;
      enable =
        (cred.enabled or false)
        && (hermes.enabled or false)
        && skillConf != null;

      skillName = skillConf.name;
      hermesHome = "${hermes.stateDir}/.hermes";
      localSkills = "${hermesHome}/skills";
      dest = "${localSkills}/${skillName}";

      # Flat skill dir matching Neo neo-hermes-skills layout: <name>/SKILL.md
      skillStore = pkgs.runCommand "heimcloud-${skillName}-skill" {} ''
        mkdir -p "$out"
        cp ${pkgs.writeText "${skillName}-SKILL.md" skillConf.content} "$out/SKILL.md"
      '';
    in {
      config = mkIf enable {
        assertions = [
          {
            assertion = skillName == "heimcloud-ops-ingest";
            message = "credentials skill-materialize expects skill name heimcloud-ops-ingest (got ${skillName}).";
          }
        ];

        # After hermes-agent-setup so HERMES_HOME exists; before SOUL seed is fine.
        system.activationScripts.heimcloud-ops-ingest-skill = lib.stringAfter ["users" "hermes-agent-setup"] ''
          set -euo pipefail
          skills_dir="${localSkills}"
          dest="${dest}"
          src="${skillStore}"
          mkdir -p "$skills_dir"

          # Plugin owns this skill name. Replace missing, stale store symlinks, or
          # prior hand-copies (real dirs) so -s always resolves after activate.
          if [ -L "$dest" ]; then
            rm -f "$dest"
          elif [ -d "$dest" ]; then
            rm -rf "$dest"
          elif [ -e "$dest" ]; then
            rm -f "$dest"
          fi

          ln -sfn "$src" "$dest"
          chown -h hermes:hermes "$dest" 2>/dev/null || true
          # Ensure parent tree is hermes-owned when we created it.
          chown hermes:hermes "$skills_dir" 2>/dev/null || true
          chown hermes:hermes "${hermesHome}" 2>/dev/null || true
        '';
      };
    };
}
