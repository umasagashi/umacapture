// The write endpoints under /api/. They send no CORS headers: the web app calls them from its own
// origin and the Windows app is not a browser. Error bodies are `{error, field?}`.

import * as limits from "./limits.mjs";
import { canonicalPostedForm, InvalidPayload, parseVersion, SidOutOfRange } from "./posted_form.mjs";
import { hexBytes, isDeleteKey, isTicket, isTicketHash, sha256 } from "./secrets.mjs";
import {
  findIdByKeyHash,
  issueTicket,
  publishRecord,
  sweepTickets,
  Unavailable,
  withdrawRecord,
} from "./store.mjs";
import { verifyTurnstile } from "./turnstile.mjs";
import { verifyPageResponse } from "./verify_page.mjs";

const DAY_SECONDS = 86_400;
// Turnstile documents tokens of up to 2048 characters.
const MAX_TOKEN = 2_048;

const API_HEADERS = { "Cache-Control": "no-store", "X-Robots-Tag": "noindex" };

function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...API_HEADERS, ...headers },
  });
}

const fail = (status, error, extra = {}, headers = {}) => json(status, { error, ...extra }, headers);
const noContent = () => new Response(null, { status: 204, headers: API_HEADERS });

/** The request clock: seconds since the epoch, and the UTC day they fall on. */
function clock() {
  const now = Math.floor(Date.now() / 1000);
  return { now, day: Math.floor(now / DAY_SECONDS) };
}

/** 429 daily_limit, telling the client when the UTC day ends. */
function dailyLimit(clockNow) {
  const retryAfter = (clockNow.day + 1) * DAY_SECONDS - clockNow.now;
  return fail(429, "daily_limit", {}, { "Retry-After": String(retryAfter) });
}

/** `vars.PUBLISH_ENABLED`: "true" or "false"; anything else is a configuration error. */
function publishingEnabled(env) {
  if (env.PUBLISH_ENABLED === "true") return true;
  if (env.PUBLISH_ENABLED === "false") return false;
  throw new Error(`PUBLISH_ENABLED must be "true" or "false", got ${JSON.stringify(env.PUBLISH_ENABLED)}`);
}

class TooLarge extends Error {}

/** The request body parsed as JSON, refused past `max` bytes whether or not Content-Length says so. */
async function readJson(request, max) {
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
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new InvalidPayload("body");
  }
}

/** `value` as an object holding exactly the `required` keys and any of the `optional` ones. */
function envelope(value, required, optional = []) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new InvalidPayload("body");
  for (const key of Object.keys(value)) {
    if (!required.includes(key) && !optional.includes(key)) throw new InvalidPayload(key);
  }
  for (const key of required) if (!Object.hasOwn(value, key)) throw new InvalidPayload(key);
  return value;
}

async function gzip(text) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/**
 * Whether the client's module set is newer than the server's tables, so a sid past the end of a
 * table means "the server has not caught up" rather than a bad value.
 */
function clientTablesNewer(moduleVersion, tables) {
  const client = parseVersion(moduleVersion);
  const server = parseVersion(tables.version);
  return client !== null && server !== null && client > server;
}

const located = (env, id) => {
  const url = `${env.PUBLIC_ORIGIN}/r/${id}`;
  return { id, url, json_url: `${url}.json` };
};

/** GET /api/verify?h=<ticket hash> */
export function verifyPage(request, env) {
  const hash = new URL(request.url).searchParams.get("h");
  if (!isTicketHash(hash)) return fail(400, "invalid_payload", { field: "h" });
  return verifyPageResponse(hash, env);
}

/** POST /api/tickets `{h, token}` */
export async function postTicket(request, env, ctx) {
  if (!publishingEnabled(env)) return fail(503, "publishing_paused");
  const body = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["h", "token"]);
  if (!isTicketHash(body.h)) throw new InvalidPayload("h");
  if (typeof body.token !== "string" || body.token === "" || body.token.length > MAX_TOKEN) {
    throw new InvalidPayload("token");
  }
  if (!(await verifyTurnstile(body.token, env))) return fail(403, "verification_failed");

  const at = clock();
  const outcome = await issueTicket(env.DB, {
    hash: hexBytes(body.h),
    uses: limits.TICKET_USES,
    expiresAt: at.now + limits.TICKET_TTL_SECONDS,
    day: at.day,
    limit: limits.TICKET_LIMIT,
  });
  if (outcome === "limit") return dailyLimit(at);
  if (outcome === "issued") {
    // Only after an issue committed, and outside the response: a failed sweep is picked up by the
    // next issue.
    ctx.waitUntil(sweepTickets(env.DB, at.now, limits.SWEEP_LIMIT).catch(() => {}));
  }
  return noContent();
}

/** POST /api/records `{ticket, delete_key, record}`; `newId` draws each attempt's public id. */
export async function postRecord(request, env, tables, newId) {
  if (!publishingEnabled(env)) return fail(503, "publishing_paused");
  let body;
  try {
    body = envelope(await readJson(request, limits.MAX_PUBLISH_BODY), ["delete_key", "record"], ["ticket"]);
  } catch (error) {
    if (error instanceof TooLarge) return fail(413, "payload_too_large");
    throw error;
  }
  if (!isDeleteKey(body.delete_key)) throw new InvalidPayload("delete_key");
  const keyHash = await sha256(body.delete_key);

  // A resend of a publish that already committed: same id, and the ticket is not consumed again.
  const existing = await findIdByKeyHash(env.DB, keyHash);
  if (existing !== null) return json(200, located(env, existing));

  let form;
  try {
    form = canonicalPostedForm(body.record, tables);
  } catch (error) {
    if (error instanceof SidOutOfRange && clientTablesNewer(body.record.module_version, tables)) {
      return fail(409, "server_tables_older", { field: error.field });
    }
    throw error;
  }
  const canonical = JSON.stringify(form);
  if (new TextEncoder().encode(canonical).byteLength > limits.MAX_CANONICAL) return fail(413, "payload_too_large");
  if (!isTicket(body.ticket)) return fail(401, "ticket_required");

  const payload = await gzip(canonical);
  const at = clock();
  const row = {
    keyHash,
    payload,
    charge: payload.byteLength + limits.ROW_CHARGE,
    ticketHash: await sha256(body.ticket),
    day: at.day,
    now: at.now,
    budget: limits.STORAGE_BUDGET,
    dailyLimit: limits.DAILY_LIMIT,
  };
  // A colliding public id rolls the batch back; one fresh id is tried before giving up.
  for (let attempt = 0; attempt < 2; attempt++) {
    const id = newId();
    const outcome = await publishRecord(env.DB, { ...row, id });
    switch (outcome.status) {
      case "created":
        return json(201, located(env, id));
      case "existing":
        return json(200, located(env, outcome.id));
      case "refused":
        if (outcome.reason === "ticket") return fail(401, "ticket_required");
        if (outcome.reason === "storage") return fail(503, "storage_full");
        if (outcome.reason === "daily") return dailyLimit(at);
        return fail(503, "temporarily_unavailable");
      case "idCollision":
        continue;
    }
  }
  return fail(503, "temporarily_unavailable");
}

/** POST /api/records/lookup `{delete_key}` */
export async function postLookup(request, env) {
  const body = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["delete_key"]);
  if (!isDeleteKey(body.delete_key)) throw new InvalidPayload("delete_key");
  const id = await findIdByKeyHash(env.DB, await sha256(body.delete_key));
  return id === null ? fail(404, "not_found") : json(200, located(env, id));
}

const BEARER = /^Bearer ([A-Za-z0-9_-]+)$/;

/** DELETE /api/records/<id> with `Authorization: Bearer <delete key>` */
export async function deleteRecord(request, env, id) {
  const key = BEARER.exec(request.headers.get("Authorization") ?? "")?.[1];
  if (!isDeleteKey(key)) throw new InvalidPayload("authorization");
  const outcome = await withdrawRecord(env.DB, id, await sha256(key));
  if (outcome === "withdrawn") return noContent();
  return outcome === "forbidden" ? fail(403, "forbidden") : fail(404, "not_found");
}

/** Runs one endpoint, answering the refusals every endpoint shares. */
export async function answerApi(handler) {
  try {
    return await handler();
  } catch (error) {
    if (error instanceof TooLarge) return fail(400, "invalid_payload", { field: "body" });
    if (error instanceof InvalidPayload) return fail(400, "invalid_payload", { field: error.field });
    if (error instanceof Unavailable) return fail(503, "temporarily_unavailable");
    throw error;
  }
}
