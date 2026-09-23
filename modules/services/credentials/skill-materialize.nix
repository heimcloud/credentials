# Durable Hermes publish path for heimcloud-ops-ingest (the only path).
#
# Hermes -s NAME prefers HERMES_HOME/skills; operators inspect that tree too.
# Dual publish (this symlink + neo-hermes-skills/external_dirs) made the name
# ambiguous and hermes -s failed closed on Fleet labs. credentials skill.enabled
# defaults to false so getSkillServices skips external_dirs; this module still
# reads skill.conf and symlinks into HERMES_HOME/skills (rebuild-stable store
# target, hermes:hermes). Until Neo#2 materializes the whole skillsTree here,
# keep this path. Do not edit SOUL.md; no competing oneshot.
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
