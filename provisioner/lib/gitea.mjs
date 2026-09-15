/**
 * Gitea API helpers — private customer credential repos, stubs, deploy keys.
 * Repos are ALWAYS private. Never flip visibility to public.
 */
import { readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import {
  assertSafeCustomerId,
  resolveRepoName,
  deployKeyTitle,
  isManagedDeployKeyTitle,
} from "./slug.mjs";

function giteaBase() {
  return (process.env.GITEA_BASE_URL || "https://git.heimcloud.site").replace(
    /\/$/,
    "",
  );
}

function orgCustomers() {
  return process.env.GITEA_ORG_CUSTOMERS || "customers";
}

/** GITEA_TOKEN env, else contents of GITEA_TOKEN_FILE. Never log the value. */
function token() {
  const env = (process.env.GITEA_TOKEN || "").trim();
  if (env) return env;
  const file = (process.env.GITEA_TOKEN_FILE || "").trim();
  if (file) {
    if (!existsSync(file)) {
      throw new Error("GITEA_TOKEN_FILE path does not exist");
    }
    return readFileSync(file, "utf8").trim();
  }
  return "";
}

export function repoUrlFor({ customerId, repoSlug, repoName } = {}) {
  const name = repoName || resolveRepoName({ customerId, repoSlug });
  return `${giteaBase()}/${orgCustomers()}/${name}.git`;
}

/** OpenSSH SHA256 fingerprint of the public key blob (not the private key). */
export function sshPublicKeyFingerprintSha256(publicKey) {
  const parts = String(publicKey).trim().split(/\s+/);
  if (parts.length < 2) {
    throw new Error("invalid OpenSSH public key");
  }
  const blob = Buffer.from(parts[1], "base64");
  const digest = createHash("sha256").update(blob).digest();
  return `SHA256:${digest.toString("base64").replace(/=+$/, "")}`;
}

async function api(method, path, body) {
  const t = token();
  if (!t) throw new Error("GITEA_TOKEN (or GITEA_TOKEN_FILE) is required");
  const url = `${giteaBase()}/api/v1${path}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `token ${t}`,
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { raw: text };
  }
  return { ok: res.ok, status: res.status, data };
}

/**
 * Ensure a private repo exists. Never sends private:false.
 * New customers use Crockford repo_slug; customer id 1 stays customer-1.
 */
export async function ensurePrivateRepo({
  customerId,
  repoSlug,
  repoName,
  description,
}) {
  const org = orgCustomers();
  const name = repoName || resolveRepoName({ customerId, repoSlug });
  const get = await api("GET", `/repos/${org}/${name}`);
  if (get.ok) {
    return {
      created: false,
      repo: get.data,
      html_url: get.data.html_url,
      clone_url: get.data.clone_url,
      ssh_url: get.data.ssh_url,
      repo_name: name,
    };
  }
  if (get.status !== 404) {
    throw new Error(
      `gitea get repo ${org}/${name}: ${get.status} ${JSON.stringify(get.data)}`,
    );
  }
  const created = await api("POST", `/orgs/${org}/repos`, {
    name,
    description:
      description || `Heimcloud stub credentials for customer ${customerId}`,
    private: true,
    auto_init: false,
    default_branch: "main",
  });
  if (!created.ok) {
    throw new Error(
      `gitea create repo ${org}/${name}: ${created.status} ${JSON.stringify(created.data)}`,
    );
  }
  return {
    created: true,
    repo: created.data,
    html_url: created.data.html_url,
    clone_url: created.data.clone_url,
    ssh_url: created.data.ssh_url,
    repo_name: name,
  };
}

/** Create or update a single file via contents API. */
export async function putFile({ repoName, path, content, message }) {
  const org = orgCustomers();
  const name = repoName;
  if (!name) throw new Error("putFile requires repoName");
  const encPath = path
    .split("/")
    .map(encodeURIComponent)
    .join("/");
  const b64 = Buffer.from(content, "utf8").toString("base64");

  const existing = await api("GET", `/repos/${org}/${name}/contents/${encPath}`);
  const body = {
    content: b64,
    message: message || `chore: stub ${path}`,
    branch: "main",
  };
  if (existing.ok && existing.data?.sha) {
    body.sha = existing.data.sha;
    const upd = await api(
      "PUT",
      `/repos/${org}/${name}/contents/${encPath}`,
      body,
    );
    if (!upd.ok) {
      throw new Error(
        `gitea update ${path}: ${upd.status} ${JSON.stringify(upd.data)}`,
      );
    }
    return upd.data;
  }
  const cre = await api(
    "POST",
    `/repos/${org}/${name}/contents/${encPath}`,
    body,
  );
  if (!cre.ok) {
    throw new Error(
      `gitea create ${path}: ${cre.status} ${JSON.stringify(cre.data)}`,
    );
  }
  return cre.data;
}

export async function writeStubFiles(repoName, files) {
  const results = [];
  for (const f of files) {
    await putFile({
      repoName,
      path: f.path,
      content: f.content,
      message: `chore: provision stub ${f.path}`,
    });
    results.push({ path: f.path, ok: true });
  }
  return results;
}

export async function listDeployKeys(owner, repo) {
  const res = await api("GET", `/repos/${owner}/${repo}/keys`);
  if (res.status === 404) return [];
  if (!res.ok) {
    throw new Error(
      `gitea list deploy keys ${owner}/${repo}: ${res.status} ${JSON.stringify(res.data)}`,
    );
  }
  return Array.isArray(res.data) ? res.data : [];
}

/**
 * Add a read-only deploy key. read_only is always true regardless of caller.
 */
export async function addDeployKey(owner, repo, { title, key, read_only = true } = {}) {
  const res = await api("POST", `/repos/${owner}/${repo}/keys`, {
    title,
    key: String(key).trim(),
    read_only: true,
  });
  if (!res.ok) {
    throw new Error(
      `gitea add deploy key ${owner}/${repo}: ${res.status} ${JSON.stringify(res.data)}`,
    );
  }
  return res.data;
}

export async function deleteDeployKey(owner, repo, id) {
  const res = await api("DELETE", `/repos/${owner}/${repo}/keys/${id}`);
  if (!res.ok && res.status !== 404) {
    throw new Error(
      `gitea delete deploy key ${owner}/${repo}#${id}: ${res.status} ${JSON.stringify(res.data)}`,
    );
  }
  return true;
}

/**
 * Rotate Heimcloud-managed deploy keys (title prefix neo-customer-<id> or neo-)
 * then add a new read-only key titled neo-customer-<id>.
 */
export async function attachOrRotateDeployKey({
  customerId,
  repoName,
  repoSlug,
  publicKey,
}) {
  const id = assertSafeCustomerId(customerId);
  const org = orgCustomers();
  const name = repoName || resolveRepoName({ customerId: id, repoSlug });
  const title = deployKeyTitle(id);
  const existing = await listDeployKeys(org, name);
  let removed = 0;
  for (const k of existing) {
    if (isManagedDeployKeyTitle(k.title, id)) {
      await deleteDeployKey(org, name, k.id);
      removed += 1;
    }
  }
  const created = await addDeployKey(org, name, {
    title,
    key: publicKey,
    read_only: true,
  });
  return {
    ...created,
    title,
    read_only: true,
    removed,
    repo_name: name,
    fingerprint: sshPublicKeyFingerprintSha256(publicKey),
  };
}

export {
  giteaBase,
  orgCustomers,
  assertSafeCustomerId,
  resolveRepoName,
  deployKeyTitle,
};
