/**
 * Gitea API helpers — create private customer credential repos with stubs.
 */

function giteaBase() {
  return (process.env.GITEA_BASE_URL || "https://git.heimcloud.site").replace(
    /\/$/,
    "",
  );
}

function orgCustomers() {
  return process.env.GITEA_ORG_CUSTOMERS || "customers";
}

function token() {
  return process.env.GITEA_TOKEN || "";
}

/** Never create repos for production customer slug agwanti. */
export function assertSafeCustomerId(customerId) {
  const id = String(customerId);
  const lower = id.toLowerCase();
  if (lower === "agwanti" || lower.includes("agwanti")) {
    throw new Error("refusing to provision for production customer agwanti");
  }
  return id;
}

export function repoNameForCustomer(customerId) {
  return `customer-${assertSafeCustomerId(customerId)}`;
}

export function repoUrlFor(customerId) {
  return `${giteaBase()}/${orgCustomers()}/${repoNameForCustomer(customerId)}.git`;
}

async function api(method, path, body) {
  const t = token();
  if (!t) throw new Error("GITEA_TOKEN is required");
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

export async function ensurePrivateRepo({ customerId, description }) {
  const org = orgCustomers();
  const name = repoNameForCustomer(customerId);
  const get = await api("GET", `/repos/${org}/${name}`);
  if (get.ok) {
    return {
      created: false,
      repo: get.data,
      html_url: get.data.html_url,
      clone_url: get.data.clone_url,
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
  };
}

/** Create or update a single file via contents API. */
export async function putFile({ customerId, path, content, message }) {
  const org = orgCustomers();
  const name = repoNameForCustomer(customerId);
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

export async function writeStubFiles(customerId, files) {
  const results = [];
  for (const f of files) {
    const r = await putFile({
      customerId,
      path: f.path,
      content: f.content,
      message: `chore: provision stub ${f.path}`,
    });
    results.push({ path: f.path, ok: true });
  }
  return results;
}

export { giteaBase, orgCustomers };
