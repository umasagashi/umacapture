// What the JSON endpoints under /api/ share: answers, the request clock, body reading and the
// sharing switch. They send no CORS headers: the web app calls them from its own origin and the
// Windows app is not a browser. Error bodies are `{error, field?}`.

import { InvalidPayload } from "./posted_form.mjs";
import { Unavailable } from "./store.mjs";

const DAY_SECONDS = 86_400;
// Turnstile documents tokens of up to 2048 characters.
const MAX_TOKEN = 2_048;

const API_HEADERS = { "Cache-Control": "no-store", "X-Robots-Tag": "noindex" };

export function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...API_HEADERS, ...headers },
  });
}

export const fail = (status, error, extra = {}, headers = {}) => json(status, { error, ...extra }, headers);
export const noContent = () => new Response(null, { status: 204, headers: API_HEADERS });

/**
 * The request clock read from `now` (milliseconds since the epoch, the Worker's injected clock):
 * seconds since the epoch, and the UTC day they fall on.
 */
export function clock(now) {
  const seconds = Math.floor(now() / 1000);
  return { now: seconds, day: Math.floor(seconds / DAY_SECONDS) };
}

/** Seconds from `clockNow` to the end of its UTC day, the Retry-After of a daily limit. */
export const untilTomorrow = (clockNow) => (clockNow.day + 1) * DAY_SECONDS - clockNow.now;

/**
 * `vars.SHARING_ENABLED`: "true" or "false"; anything else is a configuration error. "false" stops
 * new shares and new logins (503 sharing_paused); reading, unsharing and logging out go on.
 */
export function sharingEnabled(env) {
  if (env.SHARING_ENABLED === "true") return true;
  if (env.SHARING_ENABLED === "false") return false;
  throw new Error(`SHARING_ENABLED must be "true" or "false", got ${JSON.stringify(env.SHARING_ENABLED)}`);
}

/**
 * `vars.SHARE_IMAGES_ENABLED`: "true" or "false"; anything else is a configuration error. "false" stops
 * shared images from coming in and going out: a share declaring images is refused image_sharing_paused,
 * a bundle's PUT is 503 image_sharing_paused, the import endpoint answers `{state: "unavailable"}` for a
 * share that declares images, and the bundle's GET is 404. Unsharing, account deletion and the hourly
 * run's removal of images go on.
 */
export function shareImagesEnabled(env) {
  if (env.SHARE_IMAGES_ENABLED === "true") return true;
  if (env.SHARE_IMAGES_ENABLED === "false") return false;
  throw new Error(`SHARE_IMAGES_ENABLED must be "true" or "false", got ${JSON.stringify(env.SHARE_IMAGES_ENABLED)}`);
}

export class TooLarge extends Error {}

/** No valid session: the request carried no bearer token, or one that is unknown or expired. */
export class SessionRequired extends Error {}

/**
 * The account is being deleted: a write to it, or any use of a session that may only continue the
 * deletion, other than continuing it and logging out.
 */
export class AccountDeleting extends Error {}

/**
 * The request body decoded as UTF-8 text, refused past `max` bytes whether or not Content-Length
 * says so. Malformed UTF-8 is InvalidPayload("body").
 */
export async function readText(request, max) {
  const declared = request.headers.get("Content-Length");
  if (declared !== null && Number(declared) > max) throw new TooLarge();
  const chunks = [];
  let total = 0;
  if (request.body !== null) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > max) {
        await reader.cancel();
        throw new TooLarge();
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new InvalidPayload("body");
  }
}

/** The request body parsed as JSON, refused past `max` bytes as `readText` refuses it. */
export async function readJson(request, max) {
  const text = await readText(request, max);
  try {
    return JSON.parse(text);
  } catch {
    throw new InvalidPayload("body");
  }
}

/** `value` as an object holding exactly the `required` keys and any of the `optional` ones. */
export function envelope(value, required, optional = []) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new InvalidPayload("body");
  for (const key of Object.keys(value)) {
    if (!required.includes(key) && !optional.includes(key)) throw new InvalidPayload(key);
  }
  for (const key of required) if (!Object.hasOwn(value, key)) throw new InvalidPayload(key);
  return value;
}

/** Whether `value` has the shape of a Turnstile token. */
export const isTurnstileToken = (value) => typeof value === "string" && value !== "" && value.length <= MAX_TOKEN;

/** An Authorization header carrying a bearer value; the endpoint checks the value's shape. */
export const BEARER = /^Bearer ([A-Za-z0-9_-]+)$/;

/** Runs one endpoint, answering the refusals every endpoint shares. */
export async function answerApi(handler) {
  try {
    return await handler();
  } catch (error) {
    if (error instanceof TooLarge) return fail(400, "invalid_payload", { field: "body" });
    if (error instanceof SessionRequired) return fail(401, "session_required");
    if (error instanceof AccountDeleting) return fail(409, "account_deleting");
    if (error instanceof InvalidPayload) return fail(400, "invalid_payload", { field: error.field });
    if (error instanceof Unavailable) return fail(503, "temporarily_unavailable");
    throw error;
  }
}
