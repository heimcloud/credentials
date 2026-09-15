/**
 * Stub credential file contents — never real secrets.
 */

const SERVICE_STUBS = {
  hermes: {
    path: "hermes/token.stub",
    content: `# Heimcloud Hermes token stub
# Real xAI / Hermes keys are provisioned later — never commit them here.
HERMES_API_KEY=stub-replace-me
HERMES_STATUS=pending_reseller
`,
  },
  backups: {
    path: "backups/rsync.stub",
    content: `# Heimcloud backups / rsync.net stub
RSYNC_HOST=stub.rsync.net
RSYNC_USER=stub-user
RSYNC_MODULE=stub-module
RSYNC_STATUS=pending_reseller
`,
  },
  airvpn: {
    path: "airvpn/config.stub",
    content: `# Heimcloud AirVPN config stub
# Replace with real .ovpn / WireGuard profile when provisioned.
AIRVPN_STATUS=pending_reseller
`,
  },
  public_ip: {
    path: "public_ip/hostkey.stub",
    content: `# Heimcloud public IP / Hostkey stub
HOSTKEY_SERVER_ID=stub
PUBLIC_IPV4=0.0.0.0
PUBLIC_IP_STATUS=pending_reseller
`,
  },
};

const KNOWN = new Set(Object.keys(SERVICE_STUBS));

export function normalizeServices(payload) {
  const raw = payload?.services;
  let list = [];
  if (Array.isArray(raw)) list = raw;
  else if (typeof raw === "string") {
    list = raw.split(",").map((s) => s.trim());
  }
  return [...new Set(list.map(String).filter((id) => KNOWN.has(id)))];
}

export function buildRepoFiles({
  customerId,
  email,
  job,
  services,
  repoSlug,
  repoName,
} = {}) {
  const now = new Date().toISOString();
  const svc = services.length ? services : [...KNOWN];
  const files = [];
  const name = repoName || repoSlug || `customer-${customerId}`;

  files.push({
    path: "README.md",
    content: `# Customer credentials — ${name}

Private Heimcloud credentials repo for **${email || "unknown"}** (customer id \`${customerId}\`${repoSlug ? `; repo_slug \`${repoSlug}\`` : ""}).

Access is a **read-only Gitea deploy key** from the customer Neo SSH public key. Repos stay private.

## Layout
- \`hermes/token.stub\` — Hermes / xAI (later)
- \`backups/rsync.stub\` — rsync.net (later)
- \`airvpn/config.stub\` — AirVPN (later)
- \`public_ip/hostkey.stub\` — Hostkey public IP (later)
- \`meta.json\` — provision metadata

## Rules
- Stubs only until reseller APIs are wired
- Rotate secrets out-of-band; do not commit live keys to public repos
- Managed by \`github:heimcloud/credentials\` provisioner

Job #${job?.id ?? "?"} · ${now}
`,
  });

  for (const id of svc) {
    const stub = SERVICE_STUBS[id];
    if (stub) files.push({ path: stub.path, content: stub.content });
  }

  files.push({
    path: "meta.json",
    content:
      JSON.stringify(
        {
          customer_id: customerId,
          repo_slug: repoSlug || null,
          repo_name: name,
          email: email || null,
          job_id: job?.id ?? null,
          job_type: job?.job_type ?? null,
          order_id: job?.order_id ?? null,
          services: svc,
          provisioned_at: now,
          note: "stub credentials only — no real reseller API calls",
          rotation_days: 90,
        },
        null,
        2,
      ) + "\n",
  });

  return files;
}

export { SERVICE_STUBS, KNOWN as KNOWN_SERVICES };
