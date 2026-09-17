# Customer repo access — SSH deploy keys

## Hard rules
1. Repos on `git.heimcloud.site` are **always private**. Never flip visibility to public.
2. New Gitea repos are `customers/<repo_slug>` only (`repo_slug` = unique Crockford base32, 10 chars, alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`).
3. Legacy **customer-1** keeps `customers/customer-1` (deploy-key proof path). No new numeric repos.
4. Customer Neo machines pull via a **read-only Gitea deploy key** bound to that repo only.
5. Key material is the Neo machine **SSH public key**. Rotation re-submits; old deploy key is removed.
6. Never touch production customer **agwanti**.

## Implement status (2026-09-15)

| Piece | Status |
|-------|--------|
| Shop columns `repo_slug`, `neo_ssh_public_key`, `gitea_deploy_key_id` | Shop main `2e35d7b` (Fleet redeploying) |
| Shop `POST /customers/:id/ssh-key`, `GET /customers/:id`, `PATCH\|POST /customers/:id` | Shop main `2e35d7b` |
| Jobs include `repo_slug`, `has_ssh_key`, `neo_ssh_public_key`, `gitea_deploy_key_id` | Shop main `2e35d7b` |
| Provisioner: private repo at `customers/<repo_slug>` (legacy `customer-1`) | **done** |
| Provisioner: attach/rotate read-only deploy key `neo-customer-<id>` | **done** |
| `provisioner/attach-key.mjs` | **done** |
| `provisioner/sync-deploy-keys.mjs` + job_type `attach_gitea_deploy_key` | **done** |
| Plugin option `neo.services.credentials.neoSshPublicKey` | **done** |
| `scripts/register-ssh-key.mjs` → Shop ssh-key | **done** (clear 404 if Shop not live yet) |
| PATCH `gitea_deploy_key_id` back to Shop after attach | **done** |

## Shop API (Bearer / `X-Provisioning-Token`)

Base: `https://shop.heimcloud.site/api/internal/provisioning`

- `POST /customers/:id/ssh-key` `{ "public_key": "ssh-ed25519 AAAA…", "gitea_deploy_key_id"? }`
- `GET /customers/:id`
- `PATCH` or `POST /customers/:id` `{ "gitea_deploy_key_id": "42" }`
- Jobs list/claim include `repo_slug`, `has_ssh_key`, `neo_ssh_public_key`, `gitea_deploy_key_id`

Shop **stores** the pubkey and slug. Credentials **attaches** the Gitea deploy key (`read_only: true`) and PATCHes the Gitea key id back.

## Provisioner flow
1. Claim job → prefer Shop `repo_slug` (mint matching Crockford-10 generator only as fallback).
2. `ensurePrivateRepo` at `customers/<repo_slug>` (or `customers/customer-1` for id 1). Always `private: true`.
3. Write stub files.
4. If `neo_ssh_public_key` (job field, payload, or `NEO_SSH_PUBLIC_KEY` test override) is present:
   - delete existing keys titled `neo-customer-<id>` or prefix `neo-`
   - `POST /repos/{owner}/{repo}/keys` `{ title: "neo-customer-<id>", key, read_only: true }`
   - PATCH Shop `gitea_deploy_key_id`
   - `result_json.deploy_key_attached=true`, `gitea_deploy_key_id`
5. If absent: `deploy_key_attached=false`, notes `awaiting neo_ssh_public_key`.

## Path S / Path H (portal / factory SSH save)
1. Portal or factory `POST /customers/:id/ssh-key` with the Neo **public** key.
2. Shop stores `neo_ssh_public_key` and enqueues **`attach_gitea_deploy_key`**.
3. HQ: `node provisioner/sync-deploy-keys.mjs --from-jobs` (or `--customer-id N`), or `run.mjs --once` (prefers attach jobs).
4. Worker claims → `attachOrRotateDeployKey` (RO) → PATCH `gitea_deploy_key_id` → complete.
5. Labs already use the homeserver `.pub` as the RO key (same path).

## Rotation
Re-submit the new public key (plugin/script or Shop). Credentials deletes managed deploy keys and adds the new read-only key. Until that runs, git fetch with the new Neo key fails (by design).

## Explicit non-goals
- Making repos public “until key arrives”
- Storing Neo **private** keys at Heimcloud
- Shared deploy key across customers
- Access to `agwanti` or any production customer host
