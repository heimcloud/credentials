/**
 * Config-drop stubs (layout_version 2) — placeholders only, never real secrets.
 * Shop SKUs public_ip|airvpn|backups|hermes → folders rathole|vpn|backup|hermes.
 */

/** Shop entitlement id → drop folder + placeholder files */
const SERVICE_STUBS = {
  public_ip: {
    sku: "public_ip",
    folder: "rathole",
    files: [
      {
        path: "rathole/settings.env",
        content: `# Heimcloud rathole (public_ip SKU) — placeholder
# Maps → neo.services.rathole.{token,remoteAddr,port,name,certificateOnly}
TOKEN=stub-replace-me
REMOTE_ADDR=stub.heimcloud.example
PORT=2333
NAME=stub-customer
CERTIFICATE_ONLY=false
`,
      },
    ],
  },
  airvpn: {
    sku: "airvpn",
    folder: "vpn",
    files: [
      {
        path: "vpn/settings.env",
        content: `# Heimcloud vpn / AirVPN (airvpn SKU) — placeholder
# Maps → neo.services.vpn.{vpnServiceProvider,wireguard*,serverCountries,firewallVpnInputPorts}
VPN_SERVICE_PROVIDER=airvpn
WIREGUARD_PRIVATE_KEY=stub-replace-me
WIREGUARD_PRESHARED_KEY=stub-replace-me
WIREGUARD_ADDRESSES=0.0.0.0/32
SERVER_COUNTRIES=Netherlands
FIREWALL_VPN_INPUT_PORTS=
`,
      },
    ],
  },
  backups: {
    sku: "backups",
    folder: "backup",
    files: [
      {
        path: "backup/settings.env",
        content: `# Heimcloud backup / rsync.net (backups SKU) — placeholder
# Maps → neo.services.backup.{host,user,sshKey} via mkSshConnectionOptions
HOST=stub.rsync.net
USER=stub-user
SSH_KEY_PATH=/path/to/backup-ssh-key
# Or leave SSH_KEY_PATH empty and place key material out-of-band under appdata.
`,
      },
    ],
  },
  hermes: {
    sku: "hermes",
    folder: "hermes",
    files: [
      {
        path: "hermes/llm.env",
        content: `# Heimcloud Hermes LLM (hermes SKU) — placeholder for CORE neo.services.hermes.llm
# Maps → neo.services.hermes.llm.{provider,apiKey,model}
# Not a plugin entitlement service — configure existing Hermes.
PROVIDER=xai
API_KEY=stub-replace-me
MODEL=
`,
      },
    ],
  },
};

const KNOWN = new Set(Object.keys(SERVICE_STUBS));

/** Always include swag domain/email placeholders (non-SKU core drop). */
const ALWAYS_FILES = [
  {
    path: "swag/domain.txt",
    content: "example.invalid\n",
  },
  {
    path: "swag/email.txt",
    content: "ops@example.invalid\n",
  },
  {
    path: "layout_version",
    content: "2\n",
  },
];

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
  machine,
} = {}) {
  const now = new Date().toISOString();
  const svc = services.length ? services : [...KNOWN];
  const files = [];
  const name = repoName || repoSlug || `customer-${customerId}`;
  const folders = svc.map((id) => SERVICE_STUBS[id]?.folder).filter(Boolean);

  files.push({
    path: "README.md",
    content: `# Customer config drop — ${name}

Private Heimcloud **config drop** for **${email || "unknown"}** (customer id \`${customerId}\`${repoSlug ? `; repo_slug \`${repoSlug}\`` : ""}).

Access is a **read-only Gitea deploy key** from the customer Neo SSH public key. Repos stay private.

This repo feeds **existing** Neo services (\`neo.services.rathole\`, \`vpn\`, \`swag\`, \`backup\`, core \`hermes\`). It does **not** invent parallel entitlement stub services.

## Layout (layout_version 2)
- \`rathole/settings.env\` — public_ip SKU → \`neo.services.rathole\`
- \`vpn/settings.env\` — airvpn SKU → \`neo.services.vpn\`
- \`swag/domain.txt\`, \`swag/email.txt\` → \`neo.services.swag\`
- \`backup/settings.env\` — backups SKU → \`neo.services.backup\`
- \`hermes/llm.env\` — hermes SKU → core \`neo.services.hermes.llm\`
- \`ops/ingest.token\` — Heimcloud ops incident ingest bearer (HQ replaces)
- \`meta.json\` — provision metadata (\`layout_version\`, \`ops_ingest_url\`)
- \`layout_version\` — file containing \`2\`
- \`heimcloud/neo_ssh_public_key.pub\` — optional registered pubkey copy

## Rules
- Placeholders until reseller APIs are wired
- Secrets: mode 0600 under Neo appdata after plugin import (hybrid C)
- Non-secrets: apply via Neo settings.toml / UI
- Managed by \`github:heimcloud/credentials\` provisioner

Job #${job?.id ?? "?"} · ${now}
`,
  });

  for (const id of svc) {
    const stub = SERVICE_STUBS[id];
    if (stub) {
      for (const f of stub.files) files.push({ path: f.path, content: f.content });
    }
  }

  for (const f of ALWAYS_FILES) {
    files.push({ path: f.path, content: f.content });
  }

  // Ops ingest bearer placeholder — HQ replaces with the real token out-of-band.
  files.push({
    path: "ops/ingest.token",
    content: "replace-from-private-repo\n",
  });

  files.push({
    path: "heimcloud/neo_ssh_public_key.pub",
    content: `# Optional copy of Neo SSH public key (register via Shop / credentials plugin)
# ssh-ed25519 AAAA… comment
`,
  });

  const meta = {
    layout_version: 2,
    customer_id: customerId,
    repo_slug: repoSlug || null,
    repo_name: name,
    email: email || null,
    machine: machine || null,
    job_id: job?.id ?? null,
    job_type: job?.job_type ?? null,
    order_id: job?.order_id ?? null,
    services: svc,
    service_folders: folders,
    sku_map: {
      public_ip: "rathole",
      airvpn: "vpn",
      backups: "backup",
      hermes: "hermes",
    },
    ops_ingest_url: "https://ops.heimcloud.site/api/incidents",
    provisioned_at: now,
    note: "config-drop placeholders only — maps to existing neo.services.*; no stub entitlement services",
    rotation_days: 90,
  };

  files.push({
    path: "meta.json",
    content: JSON.stringify(meta, null, 2) + "\n",
  });

  return files;
}

export { SERVICE_STUBS, KNOWN as KNOWN_SERVICES };
