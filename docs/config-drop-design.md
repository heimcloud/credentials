# Credentials as Neo config drop

**Status: CEO SIGN-OFF** — implement with import **C**: secrets → appdata files mode 0600; non-secrets → settings.toml keys.

## Mental model
Private Gitea `customers/<repo_slug>` is a **config drop** for **existing** Neo services.
The Heimcloud credentials plugin syncs files into Neo settings/appdata (or documents exact `neo.services.*` keys).
It does **not** invent parallel entitlement stub services (`public_ip`, `airvpn`, `hermes_entitlement`, …).

Keep Heimcloud-specific exceptions: `ops/` ingest token + SSH pubkey register/rotate to Heimcloud.
Keep Hermes skill name **`heimcloud-ops-ingest`** stable.

## Repo tree (`layout_version` 2)
```
README.md
meta.json                 # layout_version:2, customer_id, repo_slug, services[], ops_ingest_url
layout_version            # file containing "2"
ops/ingest.token
heimcloud/neo_ssh_public_key.pub   # optional
rathole/                  # was public_ip — maps neo.services.rathole
  settings.env            # TOKEN=, REMOTE_ADDR=, PORT=, NAME=, CERTIFICATE_ONLY=
vpn/                      # was airvpn — maps neo.services.vpn
  settings.env            # VPN_SERVICE_PROVIDER=airvpn, WIREGUARD_*, SERVER_COUNTRIES=
swag/
  domain.txt
  email.txt
backup/                   # was backups — maps neo.services.backup
  settings.env            # HOST=, USER=, SSH_KEY_PATH=
hermes/
  llm.env                 # PROVIDER=, API_KEY=, MODEL= → core neo.services.hermes.llm
```

Shop entitlement ids keep SKU names (`public_ip`, `airvpn`, `backups`, `hermes`); provisioner maps them → folders above.

## File → `neo.services.*` mapping

| Drop path | Neo target | Notes |
|-----------|------------|--------|
| `rathole/*` | `neo.services.rathole` | `token`, `remoteAddr`, `port`, `name`, `certificateOnly`. Public IP product = rathole client toward Heimcloud streamproxy. |
| `vpn/*` | `neo.services.vpn` | Default provider `airvpn`. WireGuard keys sensitive — file mode 0600. |
| `swag/domain.txt`, `swag/email.txt` | `neo.services.swag.domain`, `.email` | TLS/domain drop. |
| `backup/*` | `neo.services.backup` | rsync-over-SSH host/user/key (`mkSshConnectionOptions`). |
| `hermes/llm.env` | `neo.services.hermes` **core** LLM options | Provider API key / model — configure existing Hermes, **no** `hermes_entitlement`. |
| `ops/ingest.token` | appdata `…/credentials/ops/ingest.token` | Heimcloud-only; skill `heimcloud-ops-ingest`. |
| `heimcloud/neo_ssh_public_key.pub` | Shop ssh-key API / deploy-key flow | Heimcloud-only register/rotate. |

## Plugin behavior
1. Remove stub modules: `public_ip`, `airvpn`, `backups`, `hermes-entitlement`.
2. Keep `neo.services.credentials` for: repo sync path, SSH pubkey register, ops token install, skill publish, overlay importer.
3. Importer (oneshot): secrets → appdata 0600; write `neo-credentials-overlay.md` / `imported.env` for non-secret settings.toml keys (hybrid C).
4. Provisioner stubs rewrite to the new tree (placeholders only).
5. `layout_version: 2` in meta.json; lab repos (hattori, thatch) migrate carefully. Never write real customer slugs in this repo.

## Explicit non-goals
- New `neo.services.public_ip` / `airvpn` / `backups` / `hermes_entitlement` options in the plugin
- Putting secrets in the public `github:heimcloud/credentials` flake
- Making customer repos public
