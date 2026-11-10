// Sharing records under an account: POST /api/shares, DELETE /api/shares/<id>, and GET /api/me/shares.
// The session says whose records they are. A share's client key, made by the app, is what makes a
// resend find the record the first send created; the server keeps only its SHA-256. A share may
// declare its record's images, which share_images.mjs takes from there.

import {
  AccountDeleting,
  clock,
  envelope,
  fail,
  json,
  noContent,
  readJson,
  SessionRequired,
  shareImagesEnabled,
  sharingEnabled,
  TooLarge,
} from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { canonicalPostedForm, InvalidPayload, parseVersion, SidOutOfRange } from "./posted_form.mjs";
import { dayToIso, recordSummary } from "./public_record.mjs";
import { isClientKey, sha256, toHex } from "./secrets.mjs";
import { declaration, importedImages, removeBundle } from "./share_images.mjs";
import { findByClientKey, listOwnShares, readRecord, shareRecord, unshareRecord, Unavailable } from "./store.mjs";
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

/**
 * Checks a share's optional `view`, which nothing reads: a web app tab opened before sharers stopped
 * choosing how a share is presented still sends `{focus: "training" | "inheritance"}` with each share,
 * and that share goes through. No Windows release ever sent it. Any other `view` is InvalidPayload.
 */
function checkLegacyView(view) {
  if (view === undefined) return;
  let focus;
  try {
    ({ focus } = envelope(view, ["focus"]));
  } catch (error) {
    if (error instanceof InvalidPayload) throw new InvalidPayload(error.field === "body" ? "view" : `view.${error.field}`);
    throw error;
  }
  if (focus !== "training" && focus !== "inheritance") throw new InvalidPayload("view.focus");
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

/** The bytes a share's declared images (`declaration`) add to its row's charge: none without images. */
const imagesCharge = (images) =>
  images === null ? 0 : new TextEncoder().encode(images.parts).byteLength + limits.SHARE_IMAGE_ROW_CHARGE;

/**
 * One share of a POST /api/shares, judged on its own: its result, or a Stop carrying its result
 * when the whole server refused it. `imagesOn` is the image switch (`shareImagesEnabled`).
 */
async function shareOne(item, env, copy, newId, owner, at, imagesOn) {
  let share;
  try {
    share = envelope(item, ["client_key", "record"], ["view", "images"]);
    checkLegacyView(share.view);
  } catch (error) {
    if (error instanceof InvalidPayload) return refused("invalid_payload", { field: error.field });
    throw error;
  }
  if (!isClientKey(share.client_key)) return refused("invalid_payload", { field: "client_key" });
  const clientKey = await sha256(share.client_key);

  // A resend of a share that already committed: same id, its images as the first send declared them,
  // and nothing is charged again.
  const existing = await findByClientKey(env.DB, clientKey);
  if (existing !== null) return { status: "existing", ...located(env, existing.id), images: existing.images };

  let images;
  try {
    images = declaration(share.images);
  } catch (error) {
    if (error instanceof InvalidPayload) return refused("invalid_payload", { field: error.field });
    throw error;
  }
  // The sharer chose the images: the share is not made without them.
  if (images !== null && !imagesOn) return refused("image_sharing_paused");
  const { payload, refusal } = await storedForm(share.record, copy);
  if (refusal !== undefined) return refusal;
  const row = {
    owner,
    clientKey,
    payload,
    charge: payload.byteLength + limits.ROW_CHARGE + imagesCharge(images),
    day: at.day,
    budget: limits.STORAGE_BUDGET,
    dailyLimit: limits.DAILY_LIMIT,
    accountCap: limits.ACCOUNT_SHARE_CAP,
    accountDailyLimit: limits.ACCOUNT_DAILY_LIMIT,
    images,
    imageBudget: limits.SHARE_IMAGE_BUDGET,
    imageDailyLimit: limits.SHARE_IMAGE_DAILY_LIMIT,
    accountImageDailyLimit: limits.ACCOUNT_SHARE_IMAGE_DAILY_LIMIT,
  };
  // A colliding public id rolls the batch back; one fresh id is tried before giving up.
  for (let attempt = 0; attempt < 2; attempt++) {
    const id = newId();
    const outcome = await shareRecord(env.DB, { ...row, id });
    switch (outcome.status) {
      case "created":
        return { status: "created", ...located(env, id), images: images === null ? "none" : "pending" };
      case "existing":
        return { status: "existing", ...located(env, outcome.id), images: outcome.images };
      case "refused":
        // The account itself refused the whole request, whatever the shares before this one did: a
        // deletion removes them, and one that completed took the session with it.
        if (outcome.reason === "gone") throw new SessionRequired();
        if (outcome.reason === "deleting") throw new AccountDeleting();
        if (outcome.reason === "account") return refused("account_limit");
        if (outcome.reason === "storage") return new Stop(refused("storage_full"));
        if (outcome.reason === "daily") return new Stop(refused("daily_limit"));
        // An image limit refuses the shares that declare images, and leaves the rest of the request to go
        // on: a share without images is never judged by one.
        if (outcome.reason === "imageStorage") return refused("image_storage_full");
        if (outcome.reason === "imageDaily") return refused("image_daily_limit");
        if (outcome.reason === "imageAccount") return refused("image_account_limit");
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
 * POST /api/shares `{shares: [{client_key, record, view?, images?}, ...]}`: shares each record in order,
 * judging each on its own, and answers 200 `{results}` with one result per share. A share made, or found
 * by its client key, answers `images`: "none" (it declares none), "pending" (declared, its bundle not
 * stored yet) or "stored". A share declaring images (`declaration` in share_images.mjs) is refused
 * image_sharing_paused while the image switch is off, and image_storage_full, image_daily_limit or
 * image_account_limit by the image limits. A refusal of the server's
 * storage or daily limit ends the request: the shares after it are "skipped" without being tried.
 * Every share is checked against one copy of `tables`' tables (a TableSource), renewed at most once.
 * `newId` draws each attempt's public id and `now` is the Worker's clock.
 */
export async function postShares(request, env, tables, newId, now) {
  if (!sharingEnabled(env)) return fail(503, "sharing_paused");
  const imagesOn = shareImagesEnabled(env);
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
      result = await shareOne(item, env, copy, newId, session.accountId, at, imagesOn);
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

/**
 * DELETE /api/shares/<id>: unshares a record the session's account holds, and deletes its bundle when
 * it declared images (`removeBundle`): the share's import endpoint and bundle answer 404 from the
 * unshare's commit, and what B2 fails to delete is left to the hourly run.
 */
export async function deleteShare(request, env, id, now) {
  const at = clock(now);
  const session = await requireSession(request, env, at.now);
  const by = crypto.randomUUID();
  const outcome = await unshareRecord(env.DB, id, session.accountId, by, at.now);
  if (outcome.status === "unshared") {
    if (outcome.images !== null) await removeBundle(env, now, session.accountId, id, by);
    return noContent();
  }
  if (outcome.status === "deleting") throw new AccountDeleting();
  return outcome.status === "forbidden" ? fail(403, "forbidden") : fail(404, "not_found");
}

/**
 * GET /api/shares/<id>: a shared record as the app imports it, with no session. `record` is the
 * stored posted form, sids and all, without `module_version`; a share posted before the app sent
 * icons, parents' ranks and record types is returned as stored, without them, and the app tells it
 * by their absence. `images` is what the share's images are now (`importedImages`): null for a share
 * that declares none, else their state, with the bundle's parts once it is stored.
 *
 * This endpoint is the app's own. Its shape is not promised to stay stable; outside tools read
 * /r/<id>.json, which publishes no sids.
 */
export async function getShare(env, id) {
  const stored = await readRecord(env.DB, id);
  if (stored === null) return fail(404, "not_found");
  const { module_version: _, ...record } = stored.form;
  return json(200, { schema: 1, id, shared_on: dayToIso(stored.sharedDay), record, images: importedImages(env, stored.images) });
}

/**
 * GET /api/me/shares: the session's account's records, newest share day first, each with
 * `client_key_hash`, the stored SHA-256 of its client key as 64 lowercase hex digits, which the app
 * matches against the key it kept, and `images`, the share's images as POST /api/shares answers them.
 * The client key itself is never stored, so it cannot be returned.
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
      summary: recordSummary(share.form, t),
      images: share.images,
    })),
  );
  return json(200, mine);
}
