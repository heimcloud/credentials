/**
 * Shop internal provisioning API client (Shop main 2e35d7b).
 * Base: SHOP_BASE_URL + /api/internal/provisioning
 * Auth: Bearer PROVISIONING_API_TOKEN or X-Provisioning-Token
 *
 *   POST /customers/:id/ssh-key  { public_key, gitea_deploy_key_id? }
 *   GET  /customers/:id
 *   PATCH|POST /customers/:id    { gitea_deploy_key_id }
 *   Jobs include repo_slug, has_ssh_key, neo_ssh_public_key, gitea_deploy_key_id
 */
import { readFileSync, existsSync } from "node:fs";

function baseUrl() {
  const raw = (process.env.SHOP_BASE_URL || "https://shop.heimcloud.site").replace(
    /\/$/,
    "",
  );
  return `${raw}/api/internal/provisioning`;
}

function token() {
  const env = (
    process.env.PROVISIONING_API_TOKEN ||
    process.env.SHOP_INTERNAL_SECRET ||
    ""
  ).trim();
  if (env) return env;
  const file = (process.env.PROVISIONING_API_TOKEN_FILE || "").trim();
  if (file) {
    if (!existsSync(file)) {
      throw new Error("PROVISIONING_API_TOKEN_FILE path does not exist");
    }
    return readFileSync(file, "utf8").trim();
  }
  return "";
}

function authHeaders() {
  const t = token();
  if (!t) {
    throw new Error(
      "PROVISIONING_API_TOKEN (or PROVISIONING_API_TOKEN_FILE) is required",
    );
  }
  return {
    Authorization: `Bearer ${t}`,
    "X-Provisioning-Token": t,
    Accept: "application/json",
    "Content-Type": "application/json",
  };
}

function shopNotLiveMessage(method, path, status) {
  if (status === 404) {
    return (
      `Shop ${method} ${path} is not live yet (HTTP 404). ` +
      `Attach the read-only deploy key directly with ` +
      `node provisioner/attach-key.mjs --customer-id <id> --public-key-file <key.pub> ` +
      `and retry this call after Shop redeploy.`
    );
  }
  return null;
}

async function request(method, path, body) {
  const url = `${baseUrl()}${path}`;
  const res = await fetch(url, {
    method,
    headers: authHeaders(),
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { raw: text };
  }
  if (!res.ok) {
    const live = shopNotLiveMessage(method, path, res.status);
    const err = new Error(
      live || `shop ${method} ${path} → ${res.status}: ${JSON.stringify(data)}`,
    );
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

export async function listJobs({ status = "pending", limit = 50 } = {}) {
  const q = new URLSearchParams({
    status,
    limit: String(limit),
  });
  const data = await request("GET", `/jobs?${q}`);
  return data.jobs || [];
}

export async function claimJob(id, { worker = "credentials" } = {}) {
  return request("POST", `/jobs/${id}/claim`, { worker });
}

export async function completeJob(id, { notes, result_json } = {}) {
  const body = {};
  if (notes !== undefined) body.notes = notes;
  if (result_json !== undefined) body.result_json = result_json;
  return request("POST", `/jobs/${id}/complete`, body);
}

export async function failJob(id, { notes } = {}) {
  const body = {};
  if (notes !== undefined) body.notes = notes;
  return request("POST", `/jobs/${id}/fail`, body);
}

export async function getCustomer(customerId) {
  return request("GET", `/customers/${encodeURIComponent(customerId)}`);
}

/**
 * Register / rotate Neo SSH public key on Shop.
 * Body: { public_key, gitea_deploy_key_id? }
 */
export async function registerCustomerSshKey(
  customerId,
  publicKey,
  { giteaDeployKeyId } = {},
) {
  const body = { public_key: String(publicKey).trim() };
  if (giteaDeployKeyId !== undefined) {
    body.gitea_deploy_key_id = giteaDeployKeyId;
  }
  return request(
    "POST",
    `/customers/${encodeURIComponent(customerId)}/ssh-key`,
    body,
  );
}

/** PATCH (fallback POST) gitea_deploy_key_id after Gitea attach. */
export async function patchCustomerDeployKeyId(customerId, giteaDeployKeyId) {
  const body = { gitea_deploy_key_id: giteaDeployKeyId };
  const path = `/customers/${encodeURIComponent(customerId)}`;
  try {
    return await request("PATCH", path, body);
  } catch (err) {
    if (err.status === 404 || err.status === 405) {
      return request("POST", path, body);
    }
    throw err;
  }
}

export { baseUrl, token };
