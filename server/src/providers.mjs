// The identity providers a login can go through. A provider is a row here: adding one is one more
// entry and its name in the begin's allow list (which is this table's keys); the tables, the
// endpoints and the app do not change.

import { hexBytes } from "./secrets.mjs";

export const PROVIDERS = Object.freeze({
  google: Object.freeze({
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    scope: "openid email",
    /** The `iss` values an ID token from this provider carries. */
    issuers: Object.freeze(["https://accounts.google.com", "accounts.google.com"]),
  }),
});

/** Whether `name` is a provider a login may use. */
export const isProvider = (name) => typeof name === "string" && Object.hasOwn(PROVIDERS, name);

/**
 * The redirect URI registered with `provider` for this environment. The authorisation request and
 * the token exchange both build it here, from `AUTH_REDIRECT_ORIGIN`, so staging cannot send a user
 * back to production's callback (where staging's login row does not exist).
 */
export function redirectUri(env, provider) {
  return `${requiredVar(env, "AUTH_REDIRECT_ORIGIN")}/api/auth/callback/${provider}`;
}

/** The OAuth client id of `provider` on this environment. */
export function clientId(env, provider) {
  if (provider === "google") return requiredVar(env, "GOOGLE_CLIENT_ID");
  throw new Error(`no client id for provider ${provider}`);
}

/** The OAuth client secret of `provider` on this environment (a Worker secret). */
export function clientSecret(env, provider) {
  if (provider === "google") return requiredVar(env, "GOOGLE_CLIENT_SECRET");
  throw new Error(`no client secret for provider ${provider}`);
}

/**
 * The key identities are hashed under (a Worker secret, 32 bytes as 64 hex digits), imported for
 * HMAC-SHA256. Losing it makes every account unreachable by its login.
 */
export async function identityKey(env) {
  return crypto.subtle.importKey("raw", identitySecret(env), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

/**
 * The AES-GCM key a login's account hint is sealed under while it travels through the browser,
 * derived from IDENTITY_HMAC_KEY by HKDF under a label of its own, so it is never the identity key
 * itself and no further secret has to be put.
 */
export async function hintKey(env) {
  const material = await crypto.subtle.importKey("raw", identitySecret(env), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode("umacapture account hint v1") },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/** IDENTITY_HMAC_KEY's 32 bytes. */
function identitySecret(env) {
  const hex = requiredVar(env, "IDENTITY_HMAC_KEY");
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error("IDENTITY_HMAC_KEY must be 64 lowercase hex digits");
  return hexBytes(hex);
}

/** `env[name]`, which must be a non-empty string; anything else is a configuration error. */
function requiredVar(env, name) {
  const value = env[name];
  if (typeof value !== "string" || value === "") throw new Error(`${name} must be set, got ${JSON.stringify(value)}`);
  return value;
}
