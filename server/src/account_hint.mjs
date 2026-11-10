// A login's account hint: the email address of the account a login came back as, in a masked form
// (`ke****@gmail.com`), which the claim hands to the app so it can show which account it last logged
// in with. The full address never leaves `accountHint`, which reads it from the ID token's claims.
//
// The masked form is sealed before it leaves the Worker and travels with the login's proof — the
// handover cookie's sibling on the web, the loopback redirect for the Windows app — so the browser,
// its history and the Cookie header carry only ciphertext. Only the claim of the same completed
// login opens it. Neither form is written to D1 or logged. The contract with the app is
// docs/login-protocol.md.

import { hintKey } from "./providers.mjs";
import { base64url } from "./secrets.mjs";

// RFC 5321 bounds a path at 256 octets; anything longer is not an address.
const MAX_EMAIL = 320;
const UNPRINTABLE = /[\s\u0000-\u001f\u007f]/u;
const MASK = "****";

/**
 * `email` with its local part masked: the first two characters kept when it has five or more, the
 * first one when it has three or four, none when it has one or two, and always followed by four
 * asterisks whatever the length, so the mask does not tell the exact length (only which band it falls
 * in, through how many characters are kept). The domain is kept whole: it is
 * what tells a personal account from a work one. Null when `email` is not an address.
 */
export function maskEmail(email) {
  if (typeof email !== "string" || email.length > MAX_EMAIL || UNPRINTABLE.test(email)) return null;
  const at = email.lastIndexOf("@");
  if (at <= 0 || at === email.length - 1) return null;
  // Code points, so a character outside the BMP is kept or masked whole.
  const local = Array.from(email.slice(0, at));
  const kept = local.length >= 5 ? 2 : local.length >= 3 ? 1 : 0;
  return `${local.slice(0, kept).join("")}${MASK}@${email.slice(at + 1)}`;
}

/** The masked hint of an ID token's `claims`, or null when they carry no address. */
export const accountHint = (claims) => maskEmail(claims.email);

const IV_BYTES = 12;
const TAG_BYTES = 16;
const SEALED = /^[A-Za-z0-9_-]+$/;
// The longest masked hint is MAX_EMAIL plus the mask; sealed, it is at most this many base64url characters.
const MAX_SEALED = Math.ceil(((IV_BYTES + TAG_BYTES + 4 * (MAX_EMAIL + MASK.length)) * 4) / 3);

/** Whether `value` has the shape of a sealed hint (the claim's `hint` field). Its content is not checked. */
export const isSealedHint = (value) => typeof value === "string" && value.length <= MAX_SEALED && SEALED.test(value);

/**
 * `hint` sealed under the hint key, bound to `proofHash` (the SHA-256 of the proof the same callback
 * issues), as unpadded base64url: only the claim that presents that proof opens it.
 */
export async function sealHint(env, proofHash, hint) {
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const sealed = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: proofHash },
    await hintKey(env),
    new TextEncoder().encode(hint),
  );
  return base64url(new Uint8Array([...iv, ...new Uint8Array(sealed)]));
}

/**
 * The hint `sealed` holds, or null when it was not sealed by this Worker for the proof `proofHash`.
 * A hint that does not open costs the claim nothing but the hint.
 */
export async function openHint(env, proofHash, sealed) {
  if (!isSealedHint(sealed)) return null;
  let bytes;
  try {
    bytes = Uint8Array.from(atob(sealed.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
  if (bytes.length < IV_BYTES + TAG_BYTES) return null;
  try {
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.slice(0, IV_BYTES), additionalData: proofHash },
      await hintKey(env),
      bytes.slice(IV_BYTES),
    );
    return new TextDecoder().decode(plain);
  } catch (error) {
    // A wrong key, proof or tampered bytes fail authentication; anything else is not ours to swallow.
    if (error?.name === "OperationError") return null;
    throw error;
  }
}
