# Heimcloud Credentials (Neo plugin)

Per-customer **private** Gitea repos are a **config drop** for **existing** Neo services.
The plugin syncs secrets into appdata (mode `0600`) and documents `neo.services.*` keys for
`settings.toml` (**hybrid C**). It does **not** invent parallel entitlement stub services.

Heimcloud-specific pieces: `ops/ingest.token` + Neo SSH public-key register/rotate.
Hermes skill name **`heimcloud-ops-ingest`** stays stable.

**Repos are always private.** Access is a **read-only Gitea deploy key** from the customer Neo SSH **public** key. No real secrets in this public flake.

## Install (customer Neo)

1. Neo **Settings → core → plugins**
2. Add plugin flake: `github:heimcloud/credentials`
3. Enable **`neo.services.credentials.enabled`** (only plugin service — no `public_ip` / `airvpn` / `backups` / `hermes_entitlement` stubs)
4. Enable the **core / Neo** services you are entitled to (`rathole`, `vpn`, `swag`, `backup`, `hermes`) and apply values from the drop (see mapping below)
5. Rebuild / apply Neo. Sync the private Gitea repo `customers/<repo_slug>` into `credentialsPath` (or set `syncDir`), then the importer oneshot copies secrets → appdata

## Config drop tree (`layout_version` 2)

```
README.md
meta.json                 # layout_version:2, customer_id, repo_slug, services[], ops_ingest_url
layout_version            # file containing "2"
ops/ingest.token
heimcloud/neo_ssh_public_key.pub   # optional
rathole/                  # Shop SKU public_ip → neo.services.rathole
  settings.env            # TOKEN=, REMOTE_ADDR=, PORT=, NAME=, CERTIFICATE_ONLY=
vpn/                      # Shop SKU airvpn → neo.services.vpn
  settings.env            # VPN_SERVICE_PROVIDER=airvpn, WIREGUARD_*, SERVER_COUNTRIES=
swag/
  domain.txt
  email.txt
backup/                   # Shop SKU backups → neo.services.backup
  settings.env            # HOST=, USER=, SSH_KEY_PATH= or stub notes
hermes/
  llm.env                 # PROVIDER=, API_KEY=, MODEL= → core neo.services.hermes.llm
```

Provisioner Shop SKUs stay named `public_ip|airvpn|backups|hermes` → folders `rathole|vpn|backup|hermes`.

## File → `neo.services.*` mapping

| Drop path | Neo target | Env / field mapping |
|-----------|------------|---------------------|
| `rathole/settings.env` | `neo.services.rathole` | `TOKEN`→`token`, `REMOTE_ADDR`→`remoteAddr`, `PORT`→`port`, `NAME`→`name`, `CERTIFICATE_ONLY`→`certificateOnly` |
| `vpn/settings.env` | `neo.services.vpn` | `VPN_SERVICE_PROVIDER`→`vpnServiceProvider`, `WIREGUARD_PRIVATE_KEY`→`wireguardPrivateKey`, `WIREGUARD_PRESHARED_KEY`→`wireguardPresharedKey`, `WIREGUARD_ADDRESSES`→`wireguardAddresses`, `SERVER_COUNTRIES`→`serverCountries`, `FIREWALL_VPN_INPUT_PORTS`→`firewallVpnInputPorts` |
| `swag/domain.txt` | `neo.services.swag.domain` | plain text |
| `swag/email.txt` | `neo.services.swag.email` | plain text |
| `backup/settings.env` | `neo.services.backup` | `HOST`→`host`, `USER`→`user`, `SSH_KEY_PATH`→`sshKey` (`mkSshConnectionOptions`) |
| `hermes/llm.env` | **core** `neo.services.hermes.llm` | `PROVIDER`→`provider`, `API_KEY`→`apiKey`, `MODEL`→`model` — **not** a plugin service |
| `ops/ingest.token` | appdata `…/credentials/ops/ingest.token` | Bearer for skill **`heimcloud-ops-ingest`** |
| `heimcloud/neo_ssh_public_key.pub` | Shop ssh-key / deploy-key flow | Heimcloud-only register/rotate |

**Import (hybrid C):** secrets files → appdata `0600`; non-secrets → Neo `settings.toml` / UI. After import, see `neo-credentials-overlay.md` and `imported.env` under `credentialsPath`.

## Register this Neo’s SSH public key

Heimcloud never needs the **private** key. Paste or set the OpenSSH **public** key, then submit it to Shop. Credentials attaches a read-only deploy key to `customers/<repo_slug>` (legacy **customer-1** stays `customers/customer-1`).

### Option (Neo)

```nix
neo.services.credentials = {
  enabled = true;
  customerId = "1";  # Shop customer id
  customerRepoSlug = "KAKJWG9RM5";  # optional; also in meta.json
  # syncDir = "/var/lib/neo/synced-credentials";  # optional checkout path
  neoSshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA… comment";
};
```

`neoSshPublicKey` is `nullOr str`. Rotate by setting a new public key and re-submitting. A copy is written to `${appdata}/credentials/neo-ssh.pub`.

### Script (HQ / ops — Bearer token)

```bash
export SHOP_BASE_URL=https://shop.heimcloud.site
export PROVISIONING_API_TOKEN=…   # or PROVISIONING_API_TOKEN_FILE=

node scripts/register-ssh-key.mjs --customer-id 1 --public-key-file ~/.ssh/id_ed25519.pub
# or: cat ~/.ssh/id_ed25519.pub | node scripts/register-ssh-key.mjs --customer-id 1
```

`POST /api/internal/provisioning/customers/:id/ssh-key`  
Body: `{ "public_key": "ssh-ed25519 AAAA…" }`  
Auth: `Authorization: Bearer $PROVISIONING_API_TOKEN` (customer-facing auth may come later).

If Shop returns **404**, the ssh-key endpoint is not live yet — the script errors clearly. Attach directly to Gitea in the meantime:

```bash
export GITEA_TOKEN_FILE=/path/to/gitea.token   # never print the token
node provisioner/attach-key.mjs --customer-id 1 --public-key-file ~/.ssh/id_ed25519.pub
```

### Rotate

Re-submit a new public key (plugin option + script, or Shop). The provisioner / `attach-key` removes existing keys titled `neo-customer-<id>` or prefix `neo-`, then adds the new **read-only** key. Failed pulls until re-submit are intentional.

## Plugin layout

```
modules/services/credentials/
  option.nix    # Neo options (+ mkSkillOptions) + sync/import knobs
  default.nix   # SSH pubkey oneshot + config-drop importer (hybrid C)
  skills.nix    # Hermes skill heimcloud-ops-ingest
provisioner/    # Heimcloud-side job worker (not a Neo service)
scripts/register-ssh-key.mjs
docs/ssh-access-design.md
docs/config-drop-design.md
```

Same flake-file + import-tree shape as `github:heimcloud/shop` and `nix flake init -t github:madebydamo/neo#plugin`.

**Removed** (do not reintroduce): `modules/services/{public_ip,airvpn,backups,hermes-entitlement}`.

## Provisioner (Heimcloud ops)

Claims pending shop jobs and creates **private** Gitea repos `customers/<repo_slug>` with layout_version **2** placeholders, then attaches a read-only deploy key when the Neo pubkey is present.

`repo_slug` is Shop’s unique Crockford base32 id (10 chars, alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`). Prefer the slug on job list/claim. Fallback mint uses the **same** Shop generator. Legacy customer **id 1** keeps `customers/customer-1`. **No new numeric repos.** Never targets **agwanti**.

### Env

| Variable | Default | Notes |
|----------|---------|--------|
| `SHOP_BASE_URL` | `https://shop.heimcloud.site` | Shop origin |
| `PROVISIONING_API_TOKEN` | — | Bearer / `X-Provisioning-Token` |
| `PROVISIONING_API_TOKEN_FILE` | — | Read token from file |
| `GITEA_BASE_URL` | `https://git.heimcloud.site` | |
| `GITEA_TOKEN` | — | API token with org repo write |
| `GITEA_TOKEN_FILE` | — | Read token from file (never printed) |
| `GITEA_ORG_CUSTOMERS` | `customers` | |
| `GITEA_ORG_HEIM` | `heimcloud` | reserved |
| `NEO_SSH_PUBLIC_KEY` / `NEO_SSH_PUBLIC_KEY_FILE` / `TEST_NEO_SSH_PUBLIC_KEY` | — | test override if Shop has not shipped the key yet |

### CLI

```bash
cd provisioner
export PROVISIONING_API_TOKEN=…          # or TOKEN_FILE
export GITEA_TOKEN=…                     # or GITEA_TOKEN_FILE

node run.mjs --once --dry-run
node run.mjs --once

# Follow-up after Shop stores a key (or for proof on customer-1):
node attach-key.mjs --customer-id 1 --public-key-file /path/to/id_ed25519.pub
```

### Shop API (Shop main `2e35d7b`)

- `GET  /api/internal/provisioning/jobs?status=pending&limit=50` — includes `repo_slug`, `has_ssh_key`, `neo_ssh_public_key`, `gitea_deploy_key_id`
- `POST /api/internal/provisioning/jobs/:id/claim` `{"worker":"credentials"}`
- `POST /api/internal/provisioning/jobs/:id/complete` `{"notes","result_json"}`
- `POST /api/internal/provisioning/jobs/:id/fail` `{"notes"}`
- `GET  /api/internal/provisioning/customers/:id`
- `POST /api/internal/provisioning/customers/:id/ssh-key` `{ "public_key", "gitea_deploy_key_id"? }`
- `PATCH`/`POST /api/internal/provisioning/customers/:id` `{ "gitea_deploy_key_id" }`

### Stub files written (layout 2)

- `rathole/settings.env` (SKU `public_ip`)
- `vpn/settings.env` (SKU `airvpn`)
- `backup/settings.env` (SKU `backups`)
- `hermes/llm.env` (SKU `hermes` → core Hermes LLM)
- `swag/domain.txt`, `swag/email.txt`
- `ops/ingest.token` (placeholder `replace-from-private-repo`; HQ replaces with real bearer)
- `layout_version` (`2`)
- `meta.json` (`layout_version: 2`, `repo_slug`, `ops_ingest_url`, `sku_map`)
- `heimcloud/neo_ssh_public_key.pub` (optional placeholder)
- `README.md`

## Lab ops wiring (incident ingest)

Heimcloud ops collects Neo update/activate failures from customer machines via:

`POST https://ops.heimcloud.site/api/incidents`

### Customer Neo setup

1. Add plugin flake: `github:heimcloud/credentials`
2. Enable:
   - `neo.services.credentials.enabled = true`
   - Hermes on the Neo host (`neo.services.hermes.enabled` — Neo core Hermes, so skills materialize)
3. Register the Neo SSH **public** key (deploy key) and sync the private Gitea repo `customers/<repo_slug>` into appdata credentials (e.g. `${config.neo.core.volumes.appdata}/credentials`).
4. After sync + importer:
   - `ops/ingest.token` — single-line bearer (mode `0600`); **never** paste into chat
   - `meta.json` — `repo_slug` / optional `ops_ingest_url`
   - `neo-credentials-overlay.md` — mapping notes for the operator
5. With credentials + Hermes enabled, Hermes publishes skill **`heimcloud-ops-ingest`** (from `modules/services/credentials/skills.nix`). On Neo update/activate or nightly update failure, Hermes POSTs JSON using `Authorization: Bearer $(cat …/ops/ingest.token)`.

Lab private repos (already provisioned — do not recreate):

- hattori → `https://git.heimcloud.site/customers/KAKJWG9RM5`
- thatch → `https://git.heimcloud.site/customers/W4ZGSG7SYJ`

The nix plugin may create a **placeholder** `ops/ingest.token` containing `replace-from-private-repo` only if the file is missing. It never embeds live `OPS_INGEST_SECRET` values. Real tokens live only in the private customer repos / synced appdata.

## Related

- Shop: https://github.com/heimcloud/shop
- Gitea: https://git.heimcloud.site
- Design: [docs/config-drop-design.md](docs/config-drop-design.md)
- SSH access: [docs/ssh-access-design.md](docs/ssh-access-design.md)
- Legacy template repo `heimcloud/credentials-template` points here
