#!/usr/bin/env node
/**
 * Heimcloud credentials provisioner
 *
 *   node provisioner/run.mjs --once
 *   node provisioner/run.mjs --once --dry-run
 *
 * Env:
 *   SHOP_BASE_URL              default https://shop.heimcloud.site
 *   PROVISIONING_API_TOKEN     shop internal API token (Bearer)
 *   GITEA_BASE_URL             default https://git.heimcloud.site
 *   GITEA_TOKEN                Gitea API token
 *   GITEA_ORG_CUSTOMERS        default customers
 *   GITEA_ORG_HEIM             default heimcloud (reserved)
 */

import { listJobs, claimJob, completeJob, failJob } from "./lib/shop.mjs";
import {
  ensurePrivateRepo,
  writeStubFiles,
  repoUrlFor,
  assertSafeCustomerId,
} from "./lib/gitea.mjs";
import { normalizeServices, buildRepoFiles } from "./lib/stubs.mjs";

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

async function processJob(job, { dryRun }) {
  const customerId = job.customer_id;
  assertSafeCustomerId(customerId);
  const email = job.email || job.payload?.email || null;
  const services = normalizeServices(job.payload || {});
  const repoName = `customer-${customerId}`;
  const repoUrl = repoUrlFor(customerId);

  log(
    `job #${job.id} customer=${customerId} email=${email} services=${services.join(",") || "(all stubs)"}`,
  );

  if (dryRun) {
    const files = buildRepoFiles({ customerId, email, job, services });
    log(`[dry-run] would claim job #${job.id}`);
    log(`[dry-run] would ensure private repo ${repoUrl}`);
    log(`[dry-run] would write files: ${files.map((f) => f.path).join(", ")}`);
    log(`[dry-run] would complete with result_json.repo_url=${repoUrl}`);
    return { dryRun: true, repo_url: repoUrl, files: files.map((f) => f.path) };
  }

  const claimed = await claimJob(job.id, { worker: "credentials" });
  log(`claimed job #${job.id}`, claimed.job?.status || "claimed");

  try {
    const repo = await ensurePrivateRepo({
      customerId,
      description: `Stub credentials for ${email || `customer ${customerId}`} (Heimcloud)`,
    });
    log(
      `repo ${repo.created ? "created" : "exists"}: ${repo.html_url || repoUrl}`,
    );

    const files = buildRepoFiles({ customerId, email, job, services });
    await writeStubFiles(customerId, files);
    log(`wrote ${files.length} stub files to ${repoName}`);

    const result_json = {
      repo_url: repo.clone_url || repoUrl,
      html_url: repo.html_url || null,
      repo_name: repoName,
      org: process.env.GITEA_ORG_CUSTOMERS || "customers",
      services: services.length ? services : ["hermes", "backups", "airvpn", "public_ip"],
      stub: true,
    };

    const done = await completeJob(job.id, {
      notes: `credentials repo ${repoName}`,
      result_json,
    });
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

Claim pending shop provisioning jobs and create private Gitea
customer-<id> repos with stub credential files only.

Environment:
  SHOP_BASE_URL, PROVISIONING_API_TOKEN
  GITEA_BASE_URL, GITEA_TOKEN, GITEA_ORG_CUSTOMERS
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
          customer_id: 999001,
          order_id: null,
          job_type: "provision_stub",
          status: "pending",
          email: "demo+dry-run@heimcloud.site",
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

  // Process first pending job in --once mode
  const job = jobs[0];
  const result = await processJob(job, opts);
  log("result", JSON.stringify(result));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
