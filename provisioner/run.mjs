#!/usr/bin/env node
/**
 * Heimcloud credentials provisioner
 *
 *   node provisioner/run.mjs --once
 *   node provisioner/run.mjs --once --dry-run
 *
 * Creates private Gitea repos customers/<repo_slug> (legacy customer-1
 * keeps customers/customer-1). Attaches a read-only deploy key when a
 * Neo SSH public key is present.
 *
 * Also claims Shop job_type **attach_gitea_deploy_key** (portal/factory SSH
 * save) → RO deploy key attach → complete + PATCH gitea_deploy_key_id.
 * Prefer sync-deploy-keys.mjs for attach-only batch; run.mjs handles either.
 * Never flips repos public. Never touches agwanti.
 */

import {
  listJobs,
  claimJob,
  completeJob,
  failJob,
  getCustomer,
  patchCustomerDeployKeyId,
} from "./lib/shop.mjs";
import {
  ensurePrivateRepo,
  writeStubFiles,
  repoUrlFor,
  attachOrRotateDeployKey,
} from "./lib/gitea.mjs";
import { normalizeServices, buildRepoFiles } from "./lib/stubs.mjs";
import { extractNeoSshPublicKey } from "./lib/pubkey.mjs";
import {
  assertSafeCustomerId,
  extractShopRepoSlug,
  generateRepoSlug,
  isLegacyNumericCustomer,
  resolveRepoName,
} from "./lib/slug.mjs";

function parseArgs(argv) {
  const flags = new Set(argv.slice(2));
  return {
    once: flags.has("--once") || !flags.has("--loop"),
    dryRun: flags.has("--dry-run"),
    help: flags.has("--help") || flags.has("-h"),
  };
}

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

async function resolveSlugForJob(job, customerId) {
  let slug = extractShopRepoSlug(job);
  if (slug) return slug;
  try {
    const data = await getCustomer(customerId);
    slug = extractShopRepoSlug(data.customer || data);
    if (slug) return slug;
  } catch (err) {
    log(`shop GET customer ${customerId}: ${err.message}`);
  }
  if (isLegacyNumericCustomer(customerId)) return null;
  const minted = generateRepoSlug(10);
  log(`minted fallback repo_slug=${minted} for customer ${customerId}`);
  return minted;
}

const ATTACH_JOB_TYPES = new Set([
  "attach_gitea_deploy_key",
  "attach_deploy_key",
]);

function isAttachDeployKeyJob(job) {
  const t = String(job?.job_type || "").trim();
  return ATTACH_JOB_TYPES.has(t);
}

/**
 * Path S / Path H follow-up: Shop already stored the pubkey and enqueued
 * attach_gitea_deploy_key. Claim → RO deploy key → PATCH → complete.
 * Does not rewrite stub files or re-run provision_stub.
 */
async function processAttachDeployKeyJob(job, { dryRun }) {
  const customerId = assertSafeCustomerId(job.customer_id);
  let repoSlug = extractShopRepoSlug(job);
  let pubkey = extractNeoSshPublicKey(job);

  if (!pubkey || !repoSlug) {
    try {
      const data = await getCustomer(customerId);
      const cust = data.customer || data;
      if (!pubkey) pubkey = extractNeoSshPublicKey(cust);
      if (!repoSlug) repoSlug = extractShopRepoSlug(cust);
    } catch (err) {
      log(`shop GET customer ${customerId}: ${err.message}`);
    }
  }

  const repoName = resolveRepoName({ customerId, repoSlug });
  log(
    `attach job #${job.id} type=${job.job_type} customer=${customerId} slug=${repoSlug || "(legacy)"} repo=${repoName} has_key=${Boolean(pubkey)}`,
  );

  if (dryRun) {
    log(`[dry-run] would claim job #${job.id}`);
    log(`[dry-run] would attach read-only deploy key neo-customer-${customerId} on customers/${repoName}`);
    return {
      dryRun: true,
      job_type: job.job_type,
      repo_name: repoName,
      repo_slug: repoSlug,
      deploy_key_attached: Boolean(pubkey),
    };
  }

  if (!pubkey) {
    throw new Error(
      `attach_gitea_deploy_key job #${job.id}: no neo_ssh_public_key`,
    );
  }

  const claimed = await claimJob(job.id, { worker: "credentials" });
  log(`claimed job #${job.id}`, (claimed.job || job).status || "claimed");

  try {
    const attached = await attachOrRotateDeployKey({
      customerId,
      repoName,
      repoSlug,
      publicKey: pubkey,
    });
    const gitea_deploy_key_id = attached.id ?? null;
    log(
      `deploy key attached title=${attached.title} id=${gitea_deploy_key_id} read_only=true`,
    );
    try {
      await patchCustomerDeployKeyId(customerId, gitea_deploy_key_id);
      log(`patched Shop gitea_deploy_key_id=${gitea_deploy_key_id}`);
    } catch (patchErr) {
      log(`Shop PATCH gitea_deploy_key_id: ${patchErr.message}`);
    }

    const result_json = {
      job_type: "attach_gitea_deploy_key",
      repo_name: repoName,
      repo_slug: repoSlug,
      org: process.env.GITEA_ORG_CUSTOMERS || "customers",
      deploy_key_attached: true,
      gitea_deploy_key_id,
      deploy_key_fingerprint: attached.fingerprint || null,
      title: attached.title,
      read_only: true,
    };
    const notes = `RO deploy key ${attached.title} id=${gitea_deploy_key_id} on customers/${repoName}`;
    const done = await completeJob(job.id, { notes, result_json });
    log(`completed job #${job.id}`, done.job?.status || "done");
    return result_json;
  } catch (err) {
    log(`FAIL job #${job.id}:`, err.message);
    try {
      await failJob(job.id, { notes: `attach_gitea_deploy_key error: ${err.message}` });
    } catch (failErr) {
      log(`could not mark job failed:`, failErr.message);
    }
    throw err;
  }
}

async function processJob(job, { dryRun }) {
  if (isAttachDeployKeyJob(job)) {
    return processAttachDeployKeyJob(job, { dryRun });
  }

  const customerId = job.customer_id;
  assertSafeCustomerId(customerId);
  const email = job.email || job.payload?.email || null;
  const services = normalizeServices(job.payload || {});

  let repoSlug = extractShopRepoSlug(job);
  if (!dryRun && !repoSlug && !isLegacyNumericCustomer(customerId)) {
    repoSlug = await resolveSlugForJob(job, customerId);
  }
  if (dryRun && !repoSlug && !isLegacyNumericCustomer(customerId)) {
    repoSlug = extractShopRepoSlug(job) || generateRepoSlug(10);
  }

  const repoName = resolveRepoName({ customerId, repoSlug });
  const repoUrl = repoUrlFor({ customerId, repoSlug, repoName });
  const pubkey = extractNeoSshPublicKey(job);

  log(
    `job #${job.id} customer=${customerId} slug=${repoSlug || "(legacy)"} repo=${repoName} email=${email} services=${services.join(",") || "(all stubs)"} has_key=${Boolean(pubkey)}`,
  );

  if (dryRun) {
    const files = buildRepoFiles({
      customerId,
      email,
      job,
      services,
      repoSlug,
      repoName,
    });
    log(`[dry-run] would claim job #${job.id}`);
    log(`[dry-run] would ensure private repo ${repoUrl}`);
    log(`[dry-run] would write files: ${files.map((f) => f.path).join(", ")}`);
    if (pubkey) {
      log(`[dry-run] would attach read-only deploy key neo-customer-${customerId}`);
    } else {
      log(`[dry-run] no neo_ssh_public_key — deploy_key_attached=false`);
    }
    return {
      dryRun: true,
      repo_url: repoUrl,
      repo_name: repoName,
      repo_slug: repoSlug,
      deploy_key_attached: Boolean(pubkey),
      files: files.map((f) => f.path),
    };
  }

  const claimed = await claimJob(job.id, { worker: "credentials" });
  const claimedJob = claimed.job || job;
  log(`claimed job #${job.id}`, claimedJob.status || "claimed");

  repoSlug = extractShopRepoSlug(claimedJob) || repoSlug;
  if (!repoSlug && !isLegacyNumericCustomer(customerId)) {
    repoSlug = await resolveSlugForJob(claimedJob, customerId);
  }
  const liveRepoName = resolveRepoName({ customerId, repoSlug });
  const livePubkey = extractNeoSshPublicKey(claimedJob) || pubkey;

  try {
    const repo = await ensurePrivateRepo({
      customerId,
      repoSlug,
      repoName: liveRepoName,
      description: `Stub credentials for ${email || `customer ${customerId}`} (Heimcloud)`,
    });
    log(
      `repo ${repo.created ? "created" : "exists"}: ${repo.html_url || repoUrlFor({ repoName: liveRepoName })}`,
    );

    const files = buildRepoFiles({
      customerId,
      email,
      job: claimedJob,
      services,
      repoSlug,
      repoName: liveRepoName,
    });
    await writeStubFiles(liveRepoName, files);
    log(`wrote ${files.length} stub files to ${liveRepoName}`);

    let deploy_key_attached = false;
    let gitea_deploy_key_id = null;
    let deploy_key_fingerprint = null;
    let notes = `credentials repo ${liveRepoName}`;

    if (livePubkey) {
      const attached = await attachOrRotateDeployKey({
        customerId,
        repoName: liveRepoName,
        repoSlug,
        publicKey: livePubkey,
      });
      deploy_key_attached = true;
      gitea_deploy_key_id = attached.id ?? null;
      deploy_key_fingerprint = attached.fingerprint || null;
      notes = `credentials repo ${liveRepoName}; deploy key ${attached.title} id=${gitea_deploy_key_id}`;
      log(
        `deploy key attached title=${attached.title} id=${gitea_deploy_key_id} read_only=true`,
      );
      try {
        await patchCustomerDeployKeyId(customerId, gitea_deploy_key_id);
        log(`patched Shop gitea_deploy_key_id=${gitea_deploy_key_id}`);
      } catch (patchErr) {
        log(`Shop PATCH gitea_deploy_key_id: ${patchErr.message}`);
      }
    } else {
      notes = `credentials repo ${liveRepoName}; awaiting neo_ssh_public_key`;
      log("no neo_ssh_public_key — deploy_key_attached=false");
    }

    const result_json = {
      repo_url: repo.clone_url || repoUrlFor({ repoName: liveRepoName }),
      html_url: repo.html_url || null,
      ssh_url: repo.ssh_url || null,
      repo_name: liveRepoName,
      repo_slug: repoSlug,
      legacy_path: isLegacyNumericCustomer(customerId),
      org: process.env.GITEA_ORG_CUSTOMERS || "customers",
      services: services.length
        ? services
        : ["hermes", "backups", "airvpn", "public_ip"],
      stub: true,
      deploy_key_attached,
      gitea_deploy_key_id,
      deploy_key_fingerprint,
    };

    const done = await completeJob(job.id, { notes, result_json });
    log(`completed job #${job.id}`, done.job?.status || "done");
    return result_json;
  } catch (err) {
    log(`FAIL job #${job.id}:`, err.message);
    try {
      await failJob(job.id, { notes: `provisioner error: ${err.message}` });
    } catch (failErr) {
      log(`could not mark job failed:`, failErr.message);
    }
    throw err;
  }
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    console.log(`Usage: node provisioner/run.mjs [--once] [--dry-run]

Claim pending shop provisioning jobs: provision_stub creates private
Gitea customers/<repo_slug> repos with stub files + optional RO deploy key;
attach_gitea_deploy_key only attaches/rotates the RO deploy key (Path S/H).

Environment:
  SHOP_BASE_URL, PROVISIONING_API_TOKEN, PROVISIONING_API_TOKEN_FILE
  GITEA_BASE_URL, GITEA_TOKEN, GITEA_TOKEN_FILE, GITEA_ORG_CUSTOMERS
  NEO_SSH_PUBLIC_KEY, NEO_SSH_PUBLIC_KEY_FILE, TEST_NEO_SSH_PUBLIC_KEY
`);
    process.exit(0);
  }

  log(
    `start once=${opts.once} dryRun=${opts.dryRun} shop=${process.env.SHOP_BASE_URL || "https://shop.heimcloud.site"} gitea=${process.env.GITEA_BASE_URL || "https://git.heimcloud.site"}`,
  );

  let jobs;
  try {
    jobs = await listJobs({ status: "pending", limit: 50 });
  } catch (err) {
    if (opts.dryRun) {
      log(`[dry-run] shop list failed (${err.message}) — synthesizing demo job`);
      jobs = [
        {
          id: 0,
          customer_id: 2,
          repo_slug: generateRepoSlug(10),
          order_id: null,
          job_type: "provision_stub",
          status: "pending",
          email: "demo+dry-run@heimcloud.site",
          has_ssh_key: false,
          neo_ssh_public_key: null,
          payload: {
            email: "demo+dry-run@heimcloud.site",
            services: ["hermes", "backups", "airvpn", "public_ip"],
            note: "dry-run synthetic",
          },
        },
      ];
    } else {
      throw err;
    }
  }

  log(`pending jobs: ${jobs.length}`);
  if (!jobs.length) {
    log("nothing to do");
    return;
  }

  // Prefer attach_gitea_deploy_key (portal/factory SSH save) over provision_stub.
  const attachJob = jobs.find((j) => isAttachDeployKeyJob(j));
  const job = attachJob || jobs[0];
  const result = await processJob(job, opts);
  log("result", JSON.stringify(result));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
