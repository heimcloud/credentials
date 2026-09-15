# Heimcloud Credentials (Neo plugin)

Per-customer **private** credential repos + Neo entitlement stubs for Hermes (xAI), backups (rsync.net), AirVPN, and public IP (Hostkey).

**Stubs only** — no real reseller API calls. Repos are **always private**. Access is a **read-only Gitea deploy key** from the customer Neo SSH **public** key.

## Install (customer Neo)

1. Neo **Settings → core → plugins**
2. Add plugin flake: `github:heimcloud/credentials`
3. Enable the services you are entitled to:
   - `neo.services.credentials.enabled` — SSH public-key registration helper
   - `neo.services.hermes.enabled`
   - `neo.services.backups.enabled`
   - `neo.services.airvpn.enabled`
   - `neo.services.public_ip.enabled`
4. Rebuild / apply Neo. Each service writes a local placeholder under appdata (`…/credentials/<service>/`).

Your private Gitea repo (provisioned by Heimcloud) is the source of truth for stub files.

## Register this Neo’s SSH public key

Heimcloud never needs the **private** key. Paste or set the OpenSSH **public** key, then submit it to Shop. Credentials attaches a read-only deploy key to `customers/<repo_slug>` (legacy **customer-1** stays `customers/customer-1`).

### Option (Neo)

```nix
neo.services.credentials = {
  enabled = true;
  customerId = "1";  # Shop customer id
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

`attach-key.mjs` also PATCHes `gitea_deploy_key_id` back to Shop when that API is live.

### Rotate

Re-submit a new public key (plugin option + script, or Shop). The provisioner / `attach-key` removes existing keys titled `neo-customer-<id>` or prefix `neo-`, then adds the new **read-only** key. Failed pulls until re-submit are intentional.

## Plugin layout

```
modules/services/{credentials,hermes,backups,airvpn,public_ip}/
  option.nix    # Neo options + service meta
  default.nix   # oneshot stub / pubkey writers (no containers)
provisioner/    # Heimcloud-side job worker (not a Neo service)
scripts/register-ssh-key.mjs
docs/ssh-access-design.md
```

Same flake-file + import-tree shape as `github:heimcloud/shop` and `nix flake init -t github:madebydamo/neo#plugin`.

## Provisioner (Heimcloud ops)

Claims pending shop jobs and creates **private** Gitea repos `customers/<repo_slug>` with stub files, then attaches a read-only deploy key when the Neo pubkey is present.

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

On `processJob`, after `ensurePrivateRepo` + stubs:

- Pubkey from `job.neo_ssh_public_key` / `job.payload` / `job.has_ssh_key` body fields (once Shop ships them), else env override.
- If present: rotate managed keys, add `{ title: "neo-customer-<id>", key, read_only: true }`, PATCH Shop `gitea_deploy_key_id`, `result_json.deploy_key_attached=true`.
- If absent: `deploy_key_attached=false`, notes `awaiting neo_ssh_public_key`.

### Shop API (Shop main `2e35d7b`)

- `GET  /api/internal/provisioning/jobs?status=pending&limit=50` — includes `repo_slug`, `has_ssh_key`, `neo_ssh_public_key`, `gitea_deploy_key_id`
- `POST /api/internal/provisioning/jobs/:id/claim` `{"worker":"credentials"}`
- `POST /api/internal/provisioning/jobs/:id/complete` `{"notes","result_json"}`
- `POST /api/internal/provisioning/jobs/:id/fail` `{"notes"}`
- `GET  /api/internal/provisioning/customers/:id`
- `POST /api/internal/provisioning/customers/:id/ssh-key` `{ "public_key", "gitea_deploy_key_id"? }`
- `PATCH`/`POST /api/internal/provisioning/customers/:id` `{ "gitea_deploy_key_id" }`

`result_json` is merged into the job payload as `result` (includes `repo_url`, `repo_slug`, `deploy_key_attached`, `gitea_deploy_key_id`).

### Stub files written

- `hermes/token.stub`
- `backups/rsync.stub`
- `airvpn/config.stub`
- `public_ip/hostkey.stub`
- `meta.json`
- `README.md`

## Related

- Shop: https://github.com/heimcloud/shop
- Gitea: https://git.heimcloud.site
- Design: [docs/ssh-access-design.md](docs/ssh-access-design.md)
- Legacy template repo `heimcloud/credentials-template` points here
