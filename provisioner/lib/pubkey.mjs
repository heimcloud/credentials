/**
 * Resolve Neo SSH public key from job payload, Shop fields, or env/test override.
 * Never accepts or stores a private key.
 */
import { readFileSync, existsSync } from "node:fs";

const PUBKEY_PREFIXES = [
  "ssh-ed25519 ",
  "ssh-rsa ",
  "ecdsa-sha2-nistp256 ",
  "ecdsa-sha2-nistp384 ",
  "ecdsa-sha2-nistp521 ",
  "sk-ssh-ed25519@",
  "sk-ecdsa-sha2-nistp256@",
];

export function isValidSshPublicKey(raw) {
  if (raw == null) return false;
  const key = String(raw).trim();
  if (!key) return false;
  if (key.includes("PRIVATE KEY") || key.includes("-----BEGIN")) return false;
  const okPrefix = PUBKEY_PREFIXES.some((p) => key.startsWith(p) || key.startsWith(p.split("@")[0]));
  if (!okPrefix) return false;
  const parts = key.split(/\s+/);
  return parts.length >= 2 && Boolean(parts[1]);
}

function firstPublicKey(candidates) {
  for (const c of candidates) {
    if (c == null) continue;
    const s = String(c).trim();
    if (isValidSshPublicKey(s)) return s;
  }
  return null;
}

/**
 * Read pubkey from (in order):
 *   NEO_SSH_PUBLIC_KEY / TEST_NEO_SSH_PUBLIC_KEY
 *   NEO_SSH_PUBLIC_KEY_FILE
 *   job.neo_ssh_public_key
 *   job.payload.neo_ssh_public_key / public_key / ssh_public_key
 *
 * job.has_ssh_key alone is not enough — we need the key body.
 */
export function extractNeoSshPublicKey(job) {
  const envKey = firstPublicKey([
    process.env.NEO_SSH_PUBLIC_KEY,
    process.env.TEST_NEO_SSH_PUBLIC_KEY,
  ]);
  if (envKey) return envKey;

  const envFile = (process.env.NEO_SSH_PUBLIC_KEY_FILE || "").trim();
  if (envFile) {
    if (!existsSync(envFile)) {
      throw new Error(`NEO_SSH_PUBLIC_KEY_FILE not found: ${envFile}`);
    }
    const fromFile = firstPublicKey([readFileSync(envFile, "utf8")]);
    if (fromFile) return fromFile;
    throw new Error("NEO_SSH_PUBLIC_KEY_FILE did not contain a valid OpenSSH public key");
  }

  if (!job || typeof job !== "object") return null;
  const payload = job.payload && typeof job.payload === "object" ? job.payload : {};
  return firstPublicKey([
    job.neo_ssh_public_key,
    payload.neo_ssh_public_key,
    payload.public_key,
    payload.ssh_public_key,
    payload.neoSshPublicKey,
  ]);
}
