// The client-held values (client keys, login secrets) and the public ids the server issues.
//
// Contract with the app: a client key is 128 random bits and a login secret 256 random bits, each
// sent as unpadded base64url (22 and 43 characters). The server stores only SHA-256 of their UTF-8
// text, and the start page receives that hash of the login secret as 64 lowercase hex digits. The
// values are long and random, so neither a salt nor a slow hash is needed.

import { ID_ALPHABET } from "./routes.mjs";

const CLIENT_KEY = /^[A-Za-z0-9_-]{22}$/;
const LOGIN_SECRET = /^[A-Za-z0-9_-]{43}$/;
const SECRET_HASH = /^[0-9a-f]{64}$/;

/** A share's client key: what makes a resend of the same share find the record it created. */
export const isClientKey = (value) => typeof value === "string" && CLIENT_KEY.test(value);
/** A 256-bit secret: a login's `s`, and the state, proof and session token the server hands out. */
export const isLoginSecret = (value) => typeof value === "string" && LOGIN_SECRET.test(value);
/** SHA-256 of a login's `s` as 64 lowercase hex digits. */
export const isSecretHash = (value) => typeof value === "string" && SECRET_HASH.test(value);

/** `bytes` as unpadded base64url. */
export function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

/** 256 random bits as unpadded base64url (43 characters). */
export const randomSecret = () => base64url(crypto.getRandomValues(new Uint8Array(32)));

/** SHA-256 of `text`'s UTF-8 bytes, as the 32-byte value stored in D1. */
export async function sha256(text) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/** 64 hex digits as the 32-byte value stored in D1. */
export function hexBytes(hex) {
  return Uint8Array.from(hex.match(/../g), (pair) => Number.parseInt(pair, 16));
}

/** `length` random Crockford base32 characters, 5 random bits each. */
function randomBase32(length) {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  // 256 is a multiple of 32, so taking each byte modulo 32 keeps every character equally likely.
  return Array.from(bytes, (b) => ID_ALPHABET[b % 32]).join("");
}

/** A new public id: 10 Crockford base32 characters, 50 random bits. */
export const newPublicId = () => randomBase32(10);

/**
 * A new account id: 16 Crockford base32 characters, 80 random bits. The length tells an account's
 * /u/<id> from a record's /r/<id> by shape alone.
 */
export const newAccountId = () => randomBase32(16);

/** `bytes` (a D1 BLOB or a Uint8Array) as lowercase hex digits. */
export const toHex = (bytes) => Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
