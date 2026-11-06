// Sharing records under an account: POST /api/shares, PATCH and DELETE /api/shares/<id>, and GET
// /api/me/shares.
// The session says whose records they are. A share's client key, made by the app, is what makes a
// resend find the record the first send created; the server keeps only its SHA-256.

import {
  AccountDeleting,
  clock,
  envelope,
  fail,
  json,
  noContent,
  readJson,
  SessionRequired,
  sharingEnabled,
  TooLarge,
  untilTomorrow,
} from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { canonicalPostedForm, InvalidPayload, parseVersion, SidOutOfRange } from "./posted_form.mjs";
import { dayToIso, recordSummary } from "./public_record.mjs";
import { isClientKey, sha256, toHex } from "./secrets.mjs";
import { findIdByClientKey, listOwnShares, setShareFocus, shareRecord, unshareRecord, Unavailable } from "./store.mjs";
import { TableLookupError, withTables } from "./tables.mjs";

async function gzip(text) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/**
 * Whether the client's module set is newer than the server's tables, so a sid past the end of a
 * table means "the server has not caught up" (D1 holds no load of the client's module set yet, even
 * after reading it again) rather than a bad value.
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

/** The focuses a sharer can choose for a share's pages; null leaves it to the record's type. */
const FOCUSES = ["training", "inheritance"];

/**
 * The focus of a share's optional `view` `{focus}`: one of FOCUSES, or null (the record's type decides)
 * when `nullable` and it is null, or when `view` is absent. Anything else is InvalidPayload.
 */
function focusOf(view, nullable) {
  if (view === undefined) return null;
  let focus;
  try {
    ({ focus } = envelope(view, ["focus"]));
  } catch (error) {
    if (error instanceof InvalidPayload) throw new InvalidPayload(error.field === "body" ? "view" : `view.${error.field}`);
    throw error;
  }
  if (FOCUSES.includes(focus) || (nullable && focus === null)) return focus;
  throw new InvalidPayload("view.focus");
}

const refused = (error, extra = {}) => ({ status: "refused", error, ...extra });

/**
 * A refusal that ends the request: the limit is the whole server's, so the shares after it would be
 * refused the same way and are not attempted.
 */
class Stop {
  constructor(result) {
    this.result = result;
  }
}

/**
 * The canonical posted form of `record`, checked against the request's tables (a RequestTables),
 * and checked once more against newer ones when a sid lies past their end and D1 has caught up
 * since they were read.
 */
async function checkedForm(record, copy) {
  try {
    return canonicalPostedForm(record, copy.tables);
  } catch (error) {
    const missing = error instanceof SidOutOfRange || error instanceof TableLookupError;
    if (missing && (await copy.renew())) return canonicalPostedForm(record, copy.tables);
    throw error;
  }
}

/** The posted form of `record` as stored (gzip of its canonical JSON), or a refusal result. */
async function storedForm(record, copy) {
  let form;
  try {
    form = await checkedForm(record, copy);
  } catch (error) {
    if (error instanceof SidOutOfRange && clientTablesNewer(record.module_version, copy.tables)) {
      return { refusal: refused("server_tables_older", { field: error.field }) };
    }
    if (error instanceof InvalidPayload) return { refusal: refused("invalid_payload", { field: error.field }) };
    throw error;
  }
  const canonical = JSON.stringify(form);
  if (new TextEncoder().encode(canonical).byteLength > limits.MAX_CANONICAL) return { refusal: refused("payload_too_large") };
  return { payload: await gzip(canonical) };
}

/**
 * One share of a POST /api/shares, judged on its own: its result, or a Stop carrying its result
 * when the whole server refused it.
 */
async function shareOne(item, env, copy, newId, owner, at) {
  let share;
  let focus;
  try {
    share = envelope(item, ["client_key", "record"], ["view"]);
    focus = focusOf(share.view, false);
  } catch (error) {
    if (error instanceof InvalidPayload) return refused("invalid_payload", { field: error.field });
    throw error;
  }
  if (!isClientKey(share.client_key)) return refused("invalid_payload", { field: "client_key" });
  const clientKey = await sha256(share.client_key);

  // A resend of a share that already committed: same id, nothing is charged again, and its view is
  // the first send's (a resend is the same share, not a change of it).
  const existing = await findIdByClientKey(env.DB, clientKey);
  if (existing !== null) return { status: "existing", ...located(env, existing) };

  const { payload, refusal } = await storedForm(share.record, copy);
  if (refusal !== undefined) return refusal;
  const row = {
    owner,
    clientKey,
    payload,
    focus,
    charge: payload.byteLength + limits.ROW_CHARGE,
    day: at.day,
    budget: limits.STORAGE_BUDGET,
    dailyLimit: limits.DAILY_LIMIT,
    accountCap: limits.ACCOUNT_SHARE_CAP,
    accountDailyLimit: limits.ACCOUNT_DAILY_LIMIT,
  };
  // A colliding public id rolls the batch back; one fresh id is tried before giving up.
  for (let attempt = 0; attempt < 2; attempt++) {
    const id = newId();
    const outcome = await shareRecord(env.DB, { ...row, id });
    switch (outcome.status) {
      case "created":
        return { status: "created", ...located(env, id) };
      case "existing":
        return { status: "existing", ...located(env, outcome.id) };
      case "refused":
        // The account itself refused the whole request, whatever the shares before this one did: a
        // deletion removes them, and one that completed took the session with it.
        if (outcome.reason === "gone") throw new SessionRequired();
        if (outcome.reason === "deleting") throw new AccountDeleting();
        if (outcome.reason === "account") return refused("account_limit");
        if (outcome.reason === "storage") return new Stop(refused("storage_full"));
        if (outcome.reason === "daily") return new Stop(refused("daily_limit"));
        return refused("temporarily_unavailable");
      case "idCollision":
        continue;
    }
  }
  return refused("temporarily_unavailable");
}

/** The `shares` of a POST /api/shares body: 1 to MAX_SHARES_PER_REQUEST of them. */
function sharesOf(body) {
  const { shares } = envelope(body, ["shares"]);
  if (!Array.isArray(shares) || shares.length === 0 || shares.length > limits.MAX_SHARES_PER_REQUEST) {
    throw new InvalidPayload("shares");
  }
  return shares;
}

/**
 * POST /api/shares `{shares: [{client_key, record, view?: {focus}}, ...]}`: shares each record in order,
 * judging each on its own, and answers 200 `{results}` with one result per share. A refusal of the server's
 * storage or daily limit ends the request: the shares after it are "skipped" without being tried.
 * Every share is checked against one copy of `tables`' tables (a TableSource), renewed at most once.
 * `newId` draws each attempt's public id and `now` is the Worker's clock.
 */
export async function postShares(request, env, tables, newId, now) {
  if (!sharingEnabled(env)) return fail(503, "sharing_paused");
  const at = clock(now);
  const session = await requireSession(request, env, at.now);
  let shares;
  try {
    shares = sharesOf(await readJson(request, limits.MAX_SHARE_BODY));
  } catch (error) {
    if (error instanceof TooLarge) return fail(413, "payload_too_large");
    throw error;
  }
  const copy = await tables.forRequest(env.DB);
  const results = [];
  let stopped = false;
  for (const item of shares) {
    if (stopped) {
      results.push({ status: "skipped", error: "not_attempted" });
      continue;
    }
    let result;
    try {
      result = await shareOne(item, env, copy, newId, session.accountId, at);
    } catch (error) {
      // D1 failed: this share committed nothing, and the ones after it are not tried against a
      // database that is failing.
      if (!(error instanceof Unavailable)) throw error;
      result = new Stop(refused("temporarily_unavailable"));
    }
    if (result instanceof Stop) {
      stopped = true;
      result = result.result;
    }
    results.push(result);
  }
  return json(200, { results });
}

/** DELETE /api/shares/<id>: unshares a record the session's account holds. */
export async function deleteShare(request, env, id, now) {
  const session = await requireSession(request, env, clock(now).now);
  const outcome = await unshareRecord(env.DB, id, session.accountId);
  if (outcome === "unshared") return noContent();
  if (outcome === "deleting") throw new AccountDeleting();
  return outcome === "forbidden" ? fail(403, "forbidden") : fail(404, "not_found");
}

/**
 * PATCH /api/shares/<id> `{view: {focus}}`: sets how the pages of a record the session's account holds
 * present it (a focus of FOCUSES, or null for the one its type gives), answering 204. Authorised and
 * refused as an unshare is, and like one it goes on while sharing is switched off. A change that
 * writes the row counts as one ROW_CHARGE against the daily limits a share counts against, the
 * account's and the server's, and is refused with 429 daily_limit `{scope}` ("account" or "service",
 * as sync names them) once either is used up; setting the focus the share
 * already has writes nothing and counts nothing.
 */
export async function patchShare(request, env, id, now) {
  const at = clock(now);
  const session = await requireSession(request, env, at.now);
  const { view } = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["view"]);
  const focus = focusOf(view, true);
  const outcome = await setShareFocus(env.DB, {
    id,
    owner: session.accountId,
    focus,
    day: at.day,
    charge: limits.ROW_CHARGE,
    dailyLimit: limits.DAILY_LIMIT,
    accountDailyLimit: limits.ACCOUNT_DAILY_LIMIT,
  });
  if (outcome === "changed" || outcome === "unchanged") return noContent();
  if (outcome === "deleting") throw new AccountDeleting();
  if (outcome === "account" || outcome === "daily") {
    const scope = outcome === "account" ? "account" : "service";
    return fail(429, "daily_limit", { scope }, { "Retry-After": String(untilTomorrow(at)) });
  }
  return outcome === "forbidden" ? fail(403, "forbidden") : fail(404, "not_found");
}

/**
 * GET /api/me/shares: the session's account's records, newest share day first, each with
 * `client_key_hash`, the stored SHA-256 of its client key as 64 lowercase hex digits, which the app
 * matches against the key it kept, and `view` `{focus}`, the focus its sharer chose (null when the
 * record's type decides, which the public record resolves). The client key itself is never stored, so it cannot be returned.
 */
export async function getMyShares(request, env, tables, now) {
  const session = await requireSession(request, env, clock(now).now);
  const shares = await listOwnShares(env.DB, session.accountId);
  const mine = await withTables(tables, env.DB, (t) =>
    shares.map((share) => ({
      id: share.id,
      url: located(env, share.id).url,
      shared_on: dayToIso(share.sharedDay),
      client_key_hash: toHex(share.clientKey),
      view: { focus: share.focus },
      summary: recordSummary(share.form, t),
    })),
  );
  return json(200, mine);
}
