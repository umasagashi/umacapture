// The client-held secrets (delete keys, tickets) and the public ids the server issues.
//
// Contract with the app: a delete key is 128 random bits and a ticket 256 random bits, each sent as
// unpadded base64url (22 and 43 characters). The server stores only SHA-256 of the key's or
// ticket's UTF-8 text, and the confirmation page receives that hash of the ticket as 64 lowercase
// hex digits. The secrets are long random values, so neither a salt nor a slow hash is needed.

import { ID_ALPHABET } from "./routes.mjs";

const DELETE_KEY = /^[A-Za-z0-9_-]{22}$/;
const TICKET = /^[A-Za-z0-9_-]{43}$/;
const TICKET_HASH = /^[0-9a-f]{64}$/;

export const isDeleteKey = (value) => typeof value === "string" && DELETE_KEY.test(value);
export const isTicket = (value) => typeof value === "string" && TICKET.test(value);
export const isTicketHash = (value) => typeof value === "string" && TICKET_HASH.test(value);

/** SHA-256 of `text`'s UTF-8 bytes, as the 32-byte value stored in D1. */
export async function sha256(text) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/** 64 hex digits as the 32-byte value stored in D1. */
export function hexBytes(hex) {
  return Uint8Array.from(hex.match(/../g), (pair) => Number.parseInt(pair, 16));
}

/** A new public id: 10 Crockford base32 characters, 50 random bits. */
export function newPublicId() {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  // 256 is a multiple of 32, so taking each byte modulo 32 keeps every character equally likely.
  return Array.from(bytes, (b) => ID_ALPHABET[b % 32]).join("");
}
