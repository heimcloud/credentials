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
  customerRepoSlug = "<REPO_SLUG>";  # optional; set only in machine-local settings, never commit a real slug
  # syncDir = "/var/neo/DATA/AppData/credentials-sync";  # git working tree when sync.enable
  # deployKeyPrivateKeyPath = "/home/homeserver/.ssh/id_ed25519";  # default
  # neoSshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA…";  # optional consistency check
  # sync.enable = false;  # keep off until edge SSH :2222 works
};
```

`deployKeyPrivateKeyPath` (default `/home/homeserver/.ssh/id_ed25519`) is the **single source of truth** for the machine deploy key. Separate oneshot `neo-credentials-deploy-key` derives `${appdata}/credentials/neo-ssh.pub` with `ssh-keygen -y` when the private exists; compares orphan/expected keys by SHA256 fingerprint (no cmp/diffutils); mismatches, helper failures, or a missing key log a WARNING and write `.deploy-key-status` (`ok|orphan_mismatch|expected_mismatch|missing_key|unknown`) then **exit 0** (never degrades activation). Orphan `credentials/neo-ssh` is not deleted. Rotate with `neo-homeserver-ssh-key rotate`, then re-submit the derived pub.

Optional automatic pull: `sync.enable = true` (off by default) + `customerRepoSlug` + `syncDir` + pinned `sync.knownHosts` — see `docs/gitea-ssh-edge-plan.md`. Do not enable until Gitea SSH `:2222` is reachable on the edge.

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


## Path S / Path H — attach deploy key after SSH save

Shop **Customer Portal** (Path S) and the **factory** (Path H) POST the Neo SSH
**public** key with a staff/provisioning token:

`POST /api/internal/provisioning/customers/:id/ssh-key` `{ "public_key": "ssh-ed25519 …" }`

Shop stores `neo_ssh_public_key` and enqueues job_type **`attach_gitea_deploy_key`**.
HQ then attaches a **read-only** Gitea deploy key on `customers/<repo_slug>`:

```bash
export PROVISIONING_API_TOKEN_FILE=…   # or PROVISIONING_API_TOKEN=
export GITEA_TOKEN_FILE=…              # or GITEA_TOKEN=

# By customer id (GET Shop customer → attach if pubkey present):
node provisioner/sync-deploy-keys.mjs --customer-id N

# From pending attach jobs (prefer attach_gitea_deploy_key → claim → attach → complete):
node provisioner/sync-deploy-keys.mjs --from-jobs

# Or let run.mjs pick attach jobs preferentially:
node provisioner/run.mjs --once
```

Labs already use the homeserver `.pub` as the RO deploy key (same attach/rotate
path). Repos stay private; never touch **agwanti**.


## Ops auto-fix GitHub token (opt-in, ops host only)

Optional fine-grained GitHub token so the Hermes Ops auto-fix loop can **push
fix branches to `heimcloud/neo`**. Customer Neos leave this unset.

### Settings key

```toml
[services.credentials.ops]
autofixForkPushToken = "github_pat_…"   # or omit / leave null → feature off
```

Full option path: `neo.services.credentials.ops.autofixForkPushToken` (default `null`).

### What gets installed

| Piece | Detail |
|-------|--------|
| Token file | `/run/heimcloud-autofix/github-token` — tmpfs, dir mode `0700`, file mode `0400`, owner `hermes` |
| Materialize | Activation script (+ optional `heimcloud-autofix-materialize-token.service`) reads `/etc/neo/settings.toml` at **runtime** and writes the file (never puts the value in unit `Environment=`, never interpolates it into Nix) |
| Wrapper | `heimcloud-autofix-env <cmd…>` — for the child only: `GIT_CONFIG_GLOBAL` → store gitconfig with `credential."https://github.com/heimcloud/".helper` + `credential.useHttpPath = true`, and `GH_TOKEN` from the token file |
| Helper | `heimcloud-autofix-git-credential` — git credential helper that reads the token file |
| Check | `heimcloud-autofix-env --check` → exit `0` if token file present/non-empty, else `1` |

`nix.conf` `access-tokens`, Hermes `~/.gitconfig`, and `gh` `hosts.yml` are **not** touched. Nix flake fetches, `neo update` / auto-update stay unauthenticated.

### Ops job-queue runner

```bash
# Triage-only when no token (non-zero --check → skip push / stay triage):
if heimcloud-autofix-env --check; then
  heimcloud-autofix-env hermes --yolo chat -Q --source tool --max-turns 40     -s heimcloud-ops-fix --query-file "$prompt"
else
  # no fork-push token → triage path only; do not fail the worker
  hermes --yolo chat -Q … -s heimcloud-ops-triage …
fi
```

When the key is missing/null: no token file, wrapper still runs the command
without credentials, `--check` is non-zero. Activation **never** fails for a
missing token (or a missing `hermes` user).

### Token scope (recommended)

Create a **fine-grained** personal access token (heimcloud account) with:

- Resource: **`heimcloud/neo` only** (no access to `heimcloud/credentials`)
- Permission: **`contents: write`** (push fix branches)

A fine-grained token **cannot** open the upstream PR on `madebydamo/neo`
(cross-owner → 403). Interim flow after a successful push: post a **compare
link** for Damo to open the PR himself. (`pull_requests: write` on the fork
does not help for upstream.)

Prefer a fine-grained token over an account SSH key: an account SSH key could
push to `heimcloud/credentials` **main** (production).

`gh` itself cannot path-scope a token — the real limit is the fine-grained
token’s repository selection. The git credential helper is path-scoped to
`https://github.com/heimcloud/` via `GIT_CONFIG_GLOBAL` only for the wrapped child.

### Future: upstream PR credential

A later **GitHub App** (`heimcloud-autofix`) may add a second credential for
opening PRs on `madebydamo/neo`. The wrapper already reserves
`/run/heimcloud-autofix/pr-token` → `GH_PR_TOKEN` for that child process when
present; App/JWT support is **not** implemented yet. Callers can keep using
`heimcloud-autofix-env` unchanged.

### Store / logs / Environment

Neo’s homeserver template evaluates `settings.toml` with `builtins.fromTOML`
and installs `/etc/neo/settings.toml` from the store (mode `0600`). This plugin
**does not** reference `cfg.ops.autofixForkPushToken` in any derivation text,
so the value is not copied into unit scripts or `Environment=`. Materialize
extracts the key at runtime (`set +x`, no journal echo of the secret).

## Plugin layout

```
modules/services/credentials/
  option.nix              # Neo options (+ ops.autofixForkPushToken) + sync/import knobs
  default.nix             # SSH pubkey oneshot + config-drop importer (hybrid C)
  autofix-github.nix      # Runtime materialize + heimcloud-autofix-env wrapper
  skills.nix              # Hermes skill heimcloud-ops-ingest (skill.conf; Neo#2 publishes)
  supervise-preload.nix   # Override neo-hermes-supervise with -s heimcloud-ops-ingest
provisioner/    # Heimcloud-side job worker (not a Neo service)
              # run.mjs, attach-key.mjs, sync-deploy-keys.mjs
scripts/register-ssh-key.mjs
scripts/autofix/          # extract-token, git-credential helper, env wrapper, materialize
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

# Path S / Path H — after portal/factory ssh-key POST (attach_gitea_deploy_key):
node sync-deploy-keys.mjs --customer-id N
node sync-deploy-keys.mjs --from-jobs
```

### Shop API (Shop `main` tip)

- `GET  /api/internal/provisioning/jobs?status=pending&limit=50` — includes `repo_slug`, `has_ssh_key`, `neo_ssh_public_key`, `gitea_deploy_key_id`; job_type `provision_stub` or **`attach_gitea_deploy_key`**
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
5. With credentials + Hermes enabled (`superviseUpdates`), `skill.enabled = true` lets Neo#2 `getSkillServices` → `skillsTree` / `hermes-neo-skills` own the single publish path (AGENTS.md, `external_dirs`, `HERMES_HOME` symlink). Heimcloud replaces stock `neo-hermes-supervise` so each non-noop supervise run is `hermes chat … -s heimcloud-ops-ingest`, which preloads this skill into the system prompt. On **broken**, Hermes must POST JSON with `Authorization: Bearer $(cat …/ops/ingest.token)`.

Lab machines already have private repos under `customers/<repo_slug>`. Customer slugs are secrets: they live only in the Ops/Credentials environment and on the machine, never in any GitHub repo, PR, commit message, or CI log.

The nix plugin may create a **placeholder** `ops/ingest.token` containing `replace-from-private-repo` only if the file is missing. It never embeds live `OPS_INGEST_SECRET` values. Real tokens live only in the private customer repos / synced appdata.

## Related

- Shop: https://github.com/heimcloud/shop
- Gitea: https://git.heimcloud.site
- Design: [docs/config-drop-design.md](docs/config-drop-design.md)
- SSH access: [docs/ssh-access-design.md](docs/ssh-access-design.md)
- Legacy template repo `heimcloud/credentials-template` points here
