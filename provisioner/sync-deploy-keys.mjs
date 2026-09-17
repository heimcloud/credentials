#!/usr/bin/env node
/**
 * Attach/rotate read-only Gitea deploy keys after Shop stores a Neo SSH pubkey
 * (Path S portal / Path H factory → POST …/customers/:id/ssh-key).
 *
 * Shop enqueues job_type **attach_gitea_deploy_key** (customer_id + repo_slug +
 * pubkey). This worker claims those jobs, attaches the RO deploy key, PATCHes
 * gitea_deploy_key_id, and completes the job.
 *
 *   node sync-deploy-keys.mjs --customer-id 1 --customer-id 2
 *   node sync-deploy-keys.mjs --from-jobs
 *   node sync-deploy-keys.mjs --from-jobs --once   # --once is default
 *
 * Env: same as attach-key (GITEA_TOKEN*, PROVISIONING_API_TOKEN*, SHOP_BASE_URL,
 * GITEA_BASE_URL). Never prints tokens. Refuses agwanti. Repos stay private.
 */
import { attachOrRotateDeployKey, orgCustomers } from "./lib/gitea.mjs";
import { extractNeoSshPublicKey, isValidSshPublicKey } from "./lib/pubkey.mjs";
import {
  assertSafeCustomerId,
  deployKeyTitle,
  extractShopRepoSlug,
  isLegacyNumericCustomer,
  resolveRepoName,
} from "./lib/slug.mjs";
import {
  listJobs,
  claimJob,
  completeJob,
  failJob,
  getCustomer,
  patchCustomerDeployKeyId,
} from "./lib/shop.mjs";

/** Prefer this exact Shop job_type; accept a few aliases. */
const ATTACH_JOB_TYPES = new Set([
  "attach_gitea_deploy_key",
  "attach_deploy_key",
  "ensure_config_overlay",
]);

function parseArgs(argv) {
  const out = {
    customerIds: [],
    fromJobs: false,
    once: true,
    includeClaimed: false,
    dryRun: false,
    help: false,
  };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--help" || a === "-h") out.help = true;
    else if (a === "--customer-id") {
      const v = args[++i];
      if (v) out.customerIds.push(v);
    } else if (a === "--from-jobs") out.fromJobs = true;
    else if (a === "--once") out.once = true;
    else if (a === "--loop") out.once = false;
    else if (a === "--include-claimed") out.includeClaimed = true;
    else if (a === "--dry-run") out.dryRun = true;
    else if (!a.startsWith("-") && /^\d+$/.test(a)) out.customerIds.push(a);
  }
  return out;
}

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function customerRecord(data) {
  if (!data || typeof data !== "object") return {};
  if (data.customer && typeof data.customer === "object") return data.customer;
  return data;
}

function pubkeyFromCustomer(cust) {
  if (!cust || typeof cust !== "object") return null;
  return extractNeoSshPublicKey(cust) || extractNeoSshPublicKey({ payload: cust });
}

function isAttachJobType(jobType) {
  const t = String(jobType || "").trim();
  if (ATTACH_JOB_TYPES.has(t)) return true;
  // Soft match: attach*deploy*key / ensure*overlay
  const lower = t.toLowerCase();
  if (lower.includes("attach") && lower.includes("key")) return true;
  if (lower.includes("deploy_key") || lower.includes("deploy-key")) return true;
  return false;
}

async function resolveRepoSlug({ customerId, job, customer }) {
  let slug =
    extractShopRepoSlug(job) ||
    extractShopRepoSlug(customer) ||
    extractShopRepoSlug({ customer });
  if (slug) return slug;
  if (isLegacyNumericCustomer(customerId)) return null;
  throw new Error(
    `repo_slug required for customer ${customerId} (no new numeric repos)`,
  );
}

async function attachForCustomer({
  customerId,
  publicKey,
  repoSlug,
  dryRun,
}) {
  const id = assertSafeCustomerId(customerId);
  if (!publicKey || !isValidSshPublicKey(publicKey)) {
    throw new Error(
      `customer ${id}: no valid neo_ssh_public_key (has_ssh_key alone is not enough)`,
    );
  }
  const name = resolveRepoName({ customerId: id, repoSlug });
  const title = deployKeyTitle(id);
  if (dryRun) {
    log(
      `[dry-run] would attach read-only deploy key title=${title} repo=customers/${name}`,
    );
    return {
      dryRun: true,
      customer_id: id,
      repo_name: name,
      repo_slug: repoSlug || null,
      title,
      deploy_key_attached: true,
    };
  }
  const attached = await attachOrRotateDeployKey({
    customerId: id,
    repoName: name,
    repoSlug,
    publicKey,
  });
  let shop_patched = false;
  try {
    await patchCustomerDeployKeyId(id, attached.id);
    shop_patched = true;
  } catch (err) {
    log(`Shop PATCH gitea_deploy_key_id: ${err.message}`);
  }
  return {
    customer_id: id,
    repo_name: name,
    repo_slug: repoSlug || null,
    org: orgCustomers(),
    title: attached.title || title,
    gitea_deploy_key_id: attached.id ?? null,
    read_only: true,
    fingerprint: attached.fingerprint || null,
    shop_patched,
    deploy_key_attached: true,
  };
}

async function syncCustomerId(customerId, { dryRun }) {
  const id = assertSafeCustomerId(customerId);
  const data = await getCustomer(id);
  const cust = customerRecord(data);
  const pubkey = pubkeyFromCustomer(cust);
  const hasFlag = Boolean(cust.has_ssh_key || data.has_ssh_key);
  if (!pubkey) {
    log(
      `customer ${id}: skip — no neo_ssh_public_key` +
        (hasFlag ? " (has_ssh_key=true but key body missing)" : ""),
    );
    return {
      customer_id: id,
      skipped: true,
      reason: "no_neo_ssh_public_key",
      has_ssh_key: hasFlag,
    };
  }
  const repoSlug = await resolveRepoSlug({
    customerId: id,
    customer: cust,
  });
  log(
    `customer ${id} slug=${repoSlug || "(legacy)"} attaching RO deploy key`,
  );
  return attachForCustomer({
    customerId: id,
    publicKey: pubkey,
    repoSlug,
    dryRun,
  });
}

async function processAttachJob(job, { dryRun }) {
  const customerId = assertSafeCustomerId(job.customer_id);
  const jobType = String(job.job_type || "");
  log(
    `job #${job.id} type=${jobType} customer=${customerId} status=${job.status}`,
  );

  if (jobType === "provision_stub") {
    log(`job #${job.id}: skip provision_stub (use run.mjs)`);
    return { skipped: true, reason: "provision_stub", job_id: job.id };
  }

  let repoSlug = extractShopRepoSlug(job);
  let pubkey = extractNeoSshPublicKey(job);

  if (!pubkey || !repoSlug) {
    try {
      const data = await getCustomer(customerId);
      const cust = customerRecord(data);
      pubkey = pubkey || pubkeyFromCustomer(cust);
      repoSlug = repoSlug || extractShopRepoSlug(cust);
    } catch (err) {
      log(`shop GET customer ${customerId}: ${err.message}`);
    }
  }

  if (!pubkey) {
    const msg = `job #${job.id}: no neo_ssh_public_key — skip (leave pending for retry)`;
    log(msg);
    return { skipped: true, reason: "no_key", job_id: job.id };
  }

  if (dryRun) {
    const name = resolveRepoName({ customerId, repoSlug });
    log(
      `[dry-run] would claim job #${job.id} and attach RO key to customers/${name}`,
    );
    return {
      dryRun: true,
      job_id: job.id,
      customer_id: customerId,
      repo_name: name,
      deploy_key_attached: true,
    };
  }

  if (job.status === "pending") {
    await claimJob(job.id, { worker: "credentials-sync-deploy-keys" });
    log(`claimed job #${job.id}`);
  }

  try {
    const result = await attachForCustomer({
      customerId,
      publicKey: pubkey,
      repoSlug,
      dryRun: false,
    });
    const notes = `RO deploy key ${result.title} id=${result.gitea_deploy_key_id} on customers/${result.repo_name}`;
    await completeJob(job.id, {
      notes,
      result_json: {
        ...result,
        job_type: jobType || "attach_gitea_deploy_key",
      },
    });
    log(`completed job #${job.id}`, notes);
    return { ...result, job_id: job.id, completed: true };
  } catch (err) {
    log(`FAIL job #${job.id}:`, err.message);
    try {
      await failJob(job.id, {
        notes: `sync-deploy-keys error: ${err.message}`,
      });
    } catch (failErr) {
      log(`could not mark job failed:`, failErr.message);
    }
    throw err;
  }
}

async function collectAttachJobs({ includeClaimed }) {
  const pending = await listJobs({ status: "pending", limit: 50 });
  let claimed = [];
  if (includeClaimed) {
    try {
      claimed = await listJobs({ status: "claimed", limit: 50 });
    } catch (err) {
      log(`list claimed jobs: ${err.message}`);
    }
  }
  const all = [...pending, ...claimed];
  return all.filter((j) => {
    const jt = String(j.job_type || "");
    if (jt === "provision_stub") return false;
    if (isAttachJobType(jt)) return true;
    // Jobs that only carry a pubkey update without a typed attach job:
    // leave those to --customer-id; do not claim unknown types.
    return false;
  });
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    console.log(`Usage:
  node provisioner/sync-deploy-keys.mjs --customer-id N [--customer-id M ...]
  node provisioner/sync-deploy-keys.mjs --from-jobs [--include-claimed] [--once]

Path S (Shop Customer Portal) / Path H (factory) POST the Neo SSH public key
to Shop; HQ runs this to attach a read-only Gitea deploy key on
customers/<repo_slug> and PATCH gitea_deploy_key_id.

Prefer Shop job_type **attach_gitea_deploy_key** (claim → attach → complete).
Do not re-claim provision_stub (that is run.mjs).

Env: GITEA_TOKEN or GITEA_TOKEN_FILE
     PROVISIONING_API_TOKEN or PROVISIONING_API_TOKEN_FILE
     SHOP_BASE_URL, GITEA_BASE_URL
`);
    process.exit(0);
  }

  if (!opts.fromJobs && !opts.customerIds.length) {
    throw new Error("provide --customer-id N and/or --from-jobs");
  }

  log(
    `start once=${opts.once} dryRun=${opts.dryRun} fromJobs=${opts.fromJobs} customers=${opts.customerIds.join(",") || "(none)"} shop=${process.env.SHOP_BASE_URL || "https://shop.heimcloud.site"}`,
  );

  const results = [];

  for (const cid of opts.customerIds) {
    try {
      results.push(await syncCustomerId(cid, opts));
    } catch (err) {
      log(`customer ${cid} FAIL:`, err.message);
      results.push({ customer_id: cid, error: err.message });
    }
  }

  if (opts.fromJobs) {
    let jobs;
    try {
      jobs = await collectAttachJobs({ includeClaimed: opts.includeClaimed });
    } catch (err) {
      if (opts.dryRun) {
        log(`[dry-run] shop list failed (${err.message})`);
        jobs = [];
      } else {
        throw err;
      }
    }
    log(`attach jobs: ${jobs.length}`);
    const toRun = opts.once ? jobs.slice(0, 1) : jobs;
    for (const job of toRun) {
      try {
        results.push(await processAttachJob(job, opts));
      } catch (err) {
        results.push({
          job_id: job.id,
          customer_id: job.customer_id,
          error: err.message,
        });
      }
    }
    if (!jobs.length && !opts.customerIds.length) {
      log("nothing to do");
    }
  }

  console.log(JSON.stringify({ results }, null, 2));
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
