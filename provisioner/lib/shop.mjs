/**
 * Shop internal provisioning API client.
 * Base: SHOP_BASE_URL + /api/internal/provisioning
 * Auth: Bearer PROVISIONING_API_TOKEN or X-Provisioning-Token
 */

function baseUrl() {
  const raw = (process.env.SHOP_BASE_URL || "https://shop.heimcloud.site").replace(
    /\/$/,
    "",
  );
  return `${raw}/api/internal/provisioning`;
}

function token() {
  return (
    process.env.PROVISIONING_API_TOKEN ||
    process.env.SHOP_INTERNAL_SECRET ||
    ""
  );
}

function authHeaders() {
  const t = token();
  if (!t) {
    throw new Error(
      "PROVISIONING_API_TOKEN (or SHOP_INTERNAL_SECRET) is required",
    );
  }
  return {
    Authorization: `Bearer ${t}`,
    "X-Provisioning-Token": t,
    Accept: "application/json",
    "Content-Type": "application/json",
  };
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
    const err = new Error(
      `shop ${method} ${path} → ${res.status}: ${JSON.stringify(data)}`,
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

export { baseUrl, token };
