#!/usr/bin/env node
/**
 * Attach or rotate a read-only Gitea deploy key for an existing customer repo.
 *
 *   node attach-key.mjs --customer-id 1 --public-key-file /path/to/key.pub
 *   cat key.pub | node attach-key.mjs --customer-id 1
 *   node attach-key.mjs --customer-id 2 --repo-slug AB3DHK7M2Q --public-key-file /path
 *
 * Uses GITEA_TOKEN or GITEA_TOKEN_FILE. Never prints tokens.
 * Refuses agwanti. Legacy customer-1 → customers/customer-1.
 * If Shop is live, PATCH gitea_deploy_key_id (and optionally register the pubkey).
 */
import { readFileSync, existsSync } from "node:fs";
import { attachOrRotateDeployKey, listDeployKeys, orgCustomers } from "./lib/gitea.mjs";
import { isValidSshPublicKey } from "./lib/pubkey.mjs";
import {
  assertSafeCustomerId,
  extractShopRepoSlug,
  isLegacyNumericCustomer,
  isValidRepoSlug,
  resolveRepoName,
} from "./lib/slug.mjs";
import {
  getCustomer,
  patchCustomerDeployKeyId,
  registerCustomerSshKey,
} from "./lib/shop.mjs";

function parseArgs(argv) {
  const out = {
    customerId: null,
    repoSlug: process.env.REPO_SLUG || null,
    publicKeyFile: null,
    publicKey: null,
    registerShop: true,
    help: false,
  };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--help" || a === "-h") out.help = true;
    else if (a === "--customer-id") out.customerId = args[++i];
    else if (a === "--repo-slug") out.repoSlug = args[++i];
    else if (a === "--public-key-file") out.publicKeyFile = args[++i];
    else if (a === "--public-key") out.publicKey = args[++i];
    else if (a === "--no-shop") out.registerShop = false;
    else if (a === "--") break;
    else if (!a.startsWith("-") && !out.customerId) out.customerId = a;
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
  node provisioner/attach-key.mjs --customer-id 1 --public-key-file KEY.pub
  cat KEY.pub | node provisioner/attach-key.mjs --customer-id 1
  node provisioner/attach-key.mjs --customer-id N --repo-slug SLUG --public-key-file KEY.pub

Env: GITEA_TOKEN or GITEA_TOKEN_FILE
     PROVISIONING_API_TOKEN (optional; PATCH Shop gitea_deploy_key_id)
     --no-shop skips Shop register/PATCH
`);
    process.exit(0);
  }

  if (!opts.customerId) {
    throw new Error("--customer-id is required");
  }
  const customerId = assertSafeCustomerId(opts.customerId);

  let repoSlug = opts.repoSlug && isValidRepoSlug(opts.repoSlug) ? opts.repoSlug : opts.repoSlug;
  if (repoSlug && !isValidRepoSlug(repoSlug) && !isLegacyNumericCustomer(customerId)) {
    throw new Error(`invalid --repo-slug (need Crockford 8–10): ${repoSlug}`);
  }
  if (!isLegacyNumericCustomer(customerId) && !repoSlug) {
    try {
      const data = await getCustomer(customerId);
      repoSlug = extractShopRepoSlug(data.customer || data);
    } catch (err) {
      console.error(`shop GET customer failed: ${err.message}`);
    }
  }

  const repoName = resolveRepoName({ customerId, repoSlug });
  const key = await loadPublicKey(opts);
  if (!isValidSshPublicKey(key)) {
    throw new Error("not a valid OpenSSH public key (refusing private key material)");
  }

  const attached = await attachOrRotateDeployKey({
    customerId,
    repoName,
    repoSlug,
    publicKey: key,
  });

  const org = orgCustomers();
  const listed = await listDeployKeys(org, repoName);
  const proof = listed.find((k) => String(k.id) === String(attached.id)) || attached;

  const result = {
    customer_id: customerId,
    repo_name: repoName,
    repo_slug: repoSlug || null,
    title: attached.title,
    gitea_deploy_key_id: attached.id,
    read_only: proof.read_only === true || attached.read_only === true,
    fingerprint: attached.fingerprint,
    shop_registered: false,
    shop_patched: false,
  };

  if (opts.registerShop) {
    try {
      await registerCustomerSshKey(customerId, key, {
        giteaDeployKeyId: attached.id,
      });
      result.shop_registered = true;
    } catch (err) {
      console.error(`Shop ssh-key: ${err.message}`);
    }
    try {
      await patchCustomerDeployKeyId(customerId, attached.id);
      result.shop_patched = true;
    } catch (err) {
      console.error(`Shop PATCH gitea_deploy_key_id: ${err.message}`);
    }
  }

  console.log(JSON.stringify(result, null, 2));
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
