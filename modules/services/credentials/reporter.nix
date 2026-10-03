# Incident reporting via reporter.neo (github:heimcloud/reporter.neo).
#
# This plugin no longer ships its own Hermes skill or supervise override: it
# imports reporter.neo and points it at the Heimcloud ops ingest endpoint with
# the synced bearer token. Every value is mkDefault, so settings.toml
# ([services.reporter]) can still override it per machine.
#
# The skill name stays `heimcloud-ops-ingest` so existing Hermes sessions and
# operator habits keep working. reporter.neo is deduplicated by module key, so
# also listing it in core.plugins is harmless.
{inputs, ...}: {
  flake.modules.nixos.credentials-reporter = {
    config,
    lib,
    ...
  }: let
    cred = config.neo.services.credentials;
    credsDir = cred.credentialsPath;
  in {
    imports = [inputs.reporter.nixosModules.default];

    config = lib.mkIf cred.enabled {
      neo.services.reporter = {
        enabled = lib.mkDefault true;
        endpoint = lib.mkDefault "https://ops.heimcloud.site/api/incidents";
        tokenFile = lib.mkDefault "${credsDir}/ops/ingest.token";
        # meta.json (synced drop): repo_slug / ops_ingest_url override at report time.
        overridesFile = lib.mkDefault "${credsDir}/meta.json";
        reporterId = lib.mkIf (cred.customerRepoSlug != null) (lib.mkDefault cred.customerRepoSlug);
        skillName = lib.mkDefault "heimcloud-ops-ingest";
      };
    };
  };
}
