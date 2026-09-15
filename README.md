# Heimcloud Credentials (Neo plugin)

Per-customer private credential repos + Neo entitlement stubs for Hermes (xAI), backups (rsync.net), AirVPN, and public IP (Hostkey).

**Stubs only** — no real reseller API calls.

## Install (customer Neo)

1. Neo **Settings → core → plugins**
2. Add plugin flake: `github:heimcloud/credentials`
3. Enable the services you are entitled to:
   - `neo.services.hermes.enabled`
   - `neo.services.backups.enabled`
   - `neo.services.airvpn.enabled`
   - `neo.services.public_ip.enabled`
4. Rebuild / apply Neo. Each service writes a local placeholder under appdata (`…/credentials/<service>/`).

Your private Gitea repo (provisioned by Heimcloud) is the source of truth for stub files; copy or sync as needed until automated sync lands.

## Plugin layout

```
modules/services/{hermes,backups,airvpn,public_ip}/
  option.nix    # Neo options + service meta
  default.nix   # oneshot stub file writers (no containers)
provisioner/    # Heimcloud-side job worker (not a Neo service)
```

Same flake-file + import-tree shape as `github:heimcloud/shop` and `nix flake init -t github:madebydamo/neo#plugin`.

## Provisioner (Heimcloud ops)

Claims pending shop jobs and creates private Gitea repos `customers/customer-<id>` with stub files.

### Env

| Variable | Default | Notes |
|----------|---------|--------|
| `SHOP_BASE_URL` | `https://shop.heimcloud.site` | Shop origin |
| `PROVISIONING_API_TOKEN` | — | Bearer / `X-Provisioning-Token` |
| `GITEA_BASE_URL` | `https://git.heimcloud.site` | |
| `GITEA_TOKEN` | — | API token with org repo write |
| `GITEA_ORG_CUSTOMERS` | `customers` | |
| `GITEA_ORG_HEIM` | `heimcloud` | reserved |

### CLI

```bash
cd provisioner
export PROVISIONING_API_TOKEN=…
export GITEA_TOKEN=…   # or: export GITEA_TOKEN=$(cat /path/to/gitea-credentials.token)

node run.mjs --once --dry-run   # no claim / no writes
node run.mjs --once             # claim → create repo → stubs → complete
```

### Shop API (already on heimcloud/shop main)

- `GET  /api/internal/provisioning/jobs?status=pending&limit=50`
- `POST /api/internal/provisioning/jobs/:id/claim` `{"worker":"credentials"}`
- `POST /api/internal/provisioning/jobs/:id/complete` `{"notes","result_json"}`
- `POST /api/internal/provisioning/jobs/:id/fail` `{"notes"}`

`result_json` is merged into the job payload as `result` (includes `repo_url`).

### Stub files written

- `hermes/token.stub`
- `backups/rsync.stub`
- `airvpn/config.stub`
- `public_ip/hostkey.stub`
- `meta.json`
- `README.md`

Never targets production customer **agwanti**.

## Related

- Shop: https://github.com/heimcloud/shop
- Gitea: https://git.heimcloud.site
- Legacy template repo `heimcloud/credentials-template` points here
