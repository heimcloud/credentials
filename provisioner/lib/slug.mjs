/**
 * Customer Gitea repo slugs — match Shop main 2e35d7b exactly.
 *
 * Shop columns: repo_slug (UNIQUE Crockford 10), neo_ssh_public_key,
 * gitea_deploy_key_id.
 *
 * Alphabet: Crockford base32 `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
 * (no I, L, O, U). Default length 10 (clamped 8–10).
 *
 * Prefer Shop-provided repo_slug from list/claim/GET customer.
 * Mint with the same generator only as fallback.
 * New Gitea repos: customers/<repo_slug> only.
 * Legacy customer id 1 keeps customers/customer-1 (deploy-key proof).
 * Never create new numeric repos. Never touch agwanti.
 */

import { randomBytes } from "node:crypto";

/** Same alphabet as shop app/lib/db.js generateRepoSlug. */
export const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const CROCKFORD_SLUG_ALPHABET = CROCKFORD;
export const SLUG_MIN_LEN = 8;
export const SLUG_MAX_LEN = 10;
export const SLUG_DEFAULT_LEN = 10;

export const LEGACY_CUSTOMER_ID = "1";
export const LEGACY_GITEA_REPO = "customer-1";

export function assertSafeCustomerId(customerId) {
  const id = String(customerId);
  const lower = id.toLowerCase();
  if (lower === "agwanti" || lower.includes("agwanti")) {
    throw new Error("refusing to provision for production customer agwanti");
  }
  return id;
}

export function assertSafeName(name, label = "name") {
  const s = String(name || "");
  const lower = s.toLowerCase();
  if (lower === "agwanti" || lower.includes("agwanti")) {
    throw new Error(`refusing ${label} matching production customer agwanti`);
  }
  return s;
}

export function isLegacyNumericCustomer(customerId) {
  return String(customerId) === LEGACY_CUSTOMER_ID;
}

export function normalizeRepoSlug(raw) {
  return String(raw).trim().toUpperCase();
}

export function isValidRepoSlug(raw) {
  if (raw == null) return false;
  const s = String(raw).trim();
  if (s.length < SLUG_MIN_LEN || s.length > SLUG_MAX_LEN) return false;
  const upper = s.toUpperCase();
  for (const ch of upper) {
    if (!CROCKFORD.includes(ch)) return false;
  }
  return true;
}

/**
 * Opaque Crockford base32 slug — identical algorithm to Shop
 * generateRepoSlug (crypto random bytes, index = byte % 32).
 */
export function generateRepoSlug(length = SLUG_DEFAULT_LEN) {
  const len = Math.min(Math.max(Number(length) || 10, 8), 10);
  const bytes = randomBytes(len);
  let out = "";
  for (let i = 0; i < len; i++) {
    out += CROCKFORD[bytes[i] % 32];
  }
  return assertSafeName(out, "repo slug");
}

export const mintRepoSlug = generateRepoSlug;

/** Shop job/list/claim/customer may put slug at several field paths. */
export function extractShopRepoSlug(jobOrCustomer) {
  if (!jobOrCustomer || typeof jobOrCustomer !== "object") return null;
  const payload =
    jobOrCustomer.payload && typeof jobOrCustomer.payload === "object"
      ? jobOrCustomer.payload
      : {};
  const customer =
    jobOrCustomer.customer && typeof jobOrCustomer.customer === "object"
      ? jobOrCustomer.customer
      : {};
  const candidates = [
    jobOrCustomer.repo_slug,
    payload.repo_slug,
    customer.repo_slug,
    jobOrCustomer.repoSlug,
    payload.repoSlug,
  ];
  for (const c of candidates) {
    if (c == null || String(c).trim() === "") continue;
    if (isValidRepoSlug(c)) {
      return assertSafeName(normalizeRepoSlug(c), "repo slug");
    }
  }
  return null;
}

/**
 * Gitea repo name:
 * - customer id 1 → customer-1 (legacy; never rename)
 * - everyone else → Shop repo_slug (Crockford 10)
 * Never returns customer-<numeric> except the legacy id 1 path.
 */
export function resolveRepoName({ customerId, repoSlug } = {}) {
  const id = assertSafeCustomerId(customerId);
  if (isLegacyNumericCustomer(id)) {
    return LEGACY_GITEA_REPO;
  }
  if (!repoSlug || !isValidRepoSlug(repoSlug)) {
    throw new Error(
      `repo_slug required for customer ${id} (Crockford 10; no new numeric repos)`,
    );
  }
  return assertSafeName(normalizeRepoSlug(repoSlug), "repo slug");
}

export function deployKeyTitle(customerId) {
  return `neo-customer-${assertSafeCustomerId(customerId)}`;
}

export function isManagedDeployKeyTitle(title, customerId) {
  const t = String(title || "");
  if (!t) return false;
  const id = String(customerId);
  if (t === `neo-customer-${id}` || t.startsWith(`neo-customer-${id}`)) return true;
  if (t.startsWith("neo-")) return true;
  return false;
}
