#!/usr/bin/env node
/**
 * Register / rotate a customer's Neo SSH public key with Shop.
 *
 *   node scripts/register-ssh-key.mjs --customer-id 1 --public-key-file KEY.pub
 *   cat KEY.pub | node scripts/register-ssh-key.mjs --customer-id 1
 *
 * POST https://shop.heimcloud.site/api/internal/provisioning/customers/:id/ssh-key
 * Body: { "public_key": "ssh-ed25519 AAAA…" }
 * Auth: Bearer PROVISIONING_API_TOKEN (HQ/ops). Customer-facing auth later.
 *
 * If the endpoint is not live yet (HTTP 404), errors clearly.
 * Refuses agwanti. Never prints tokens. Never uploads a private key.
 */
import { readFileSync, existsSync } from "node:fs";
import { isValidSshPublicKey } from "../provisioner/lib/pubkey.mjs";
import { assertSafeCustomerId } from "../provisioner/lib/slug.mjs";
import { registerCustomerSshKey } from "../provisioner/lib/shop.mjs";

function parseArgs(argv) {
  const out = { customerId: null, publicKeyFile: null, publicKey: null, help: false };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--help" || a === "-h") out.help = true;
    else if (a === "--customer-id") out.customerId = args[++i];
    else if (a === "--public-key-file") out.publicKeyFile = args[++i];
    else if (a === "--public-key") out.publicKey = args[++i];
  }
  return out;
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function loadPublicKey({ publicKey, publicKeyFile }) {
  if (publicKey) return String(publicKey).trim();
  if (publicKeyFile && publicKeyFile !== "-") {
    if (!existsSync(publicKeyFile)) {
      throw new Error(`public key file not found: ${publicKeyFile}`);
    }
    return readFileSync(publicKeyFile, "utf8").trim();
  }
  if (publicKeyFile === "-" || !process.stdin.isTTY) {
    const fromStdin = (await readStdin()).trim();
    if (fromStdin) return fromStdin;
  }
  throw new Error("provide --public-key-file PATH, --public-key, or stdin");
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    console.log(`Usage:
  node scripts/register-ssh-key.mjs --customer-id 1 --public-key-file KEY.pub
  cat KEY.pub | node scripts/register-ssh-key.mjs --customer-id 1

POSTs the OpenSSH public key to Shop:
  POST $SHOP_BASE_URL/api/internal/provisioning/customers/:id/ssh-key
  { "public_key": "ssh-ed25519 AAAA…" }

Env: SHOP_BASE_URL (default https://shop.heimcloud.site)
     PROVISIONING_API_TOKEN or PROVISIONING_API_TOKEN_FILE

After Shop stores the key, attach it to Gitea:
  node provisioner/attach-key.mjs --customer-id N --public-key-file KEY.pub
`);
    process.exit(0);
  }
  if (!opts.customerId) throw new Error("--customer-id is required");
  const customerId = assertSafeCustomerId(opts.customerId);
  const key = await loadPublicKey(opts);
  if (!isValidSshPublicKey(key)) {
    throw new Error("not a valid OpenSSH public key (refusing private key material)");
  }
  const res = await registerCustomerSshKey(customerId, key);
  const out = {
    id: res.id ?? customerId,
    repo_slug: res.repo_slug ?? null,
    has_ssh_key: res.has_ssh_key ?? true,
    gitea_deploy_key_id: res.gitea_deploy_key_id ?? null,
    key_fingerprint: res.key_fingerprint ?? null,
  };
  console.log(JSON.stringify(out, null, 2));
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
