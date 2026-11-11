// File sync's object endpoints under /api/sync/: the account's generation and settings, bodies put and
// fetched in bundles, and images put and fetched one at a time (the list's parts and root are
// sync_list.mjs's). The account's image form decides which new images a put stores.
// Every object is named by the SHA-256 of its
// bytes and stored once per account: a put of a name the account already holds answers "exists"
// without reaching B2.
//
// A body's name is checked here (the Worker parses the body to read the images it names anyway), and a
// mismatch is 400. An image's is not: the Worker passes the image to B2 signed with its claimed name,
// and B2 refuses bytes that do not hash to it. B2 answers that refusal with the same 403 as a wrong
// key, so it is answered 502 storage_refused rather than 400.
//
// A put stores an object nothing references yet (unless the list already names it, as it may an
// image). It records the write before B2 is asked and clears the record with the object's row
// (`writing`, `putWritten` in sync_refs.mjs), and leaves the object shown for the replacement that
// references it. When another request stored the name and hid it meanwhile, the record stays: B2 may
// show what this put stored over that hide, and whoever takes the record has it hidden again. A GET
// answers only what the current root references, so until then a GET of it is 404. Every write that
// answers 200 then takes on what the account's requests left to do (`syncWrite`): among it, hiding
// what a put stored SYNC_ABANDONED_AFTER ago that nothing references.
// An object hidden past the boundary B2's lifecycle sets (`HELD` in sync_refs.mjs) is gone: the account
// no longer holds it, and a put of its name stores it anew.

import { clock, envelope, fail, json, readJson } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import { Bucket, objectKey, sha256Hex, StorageFailed } from "./b2.mjs";
import * as limits from "./limits.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { Unavailable } from "./store.mjs";
import { admit, admitGrowth, chargeRequest, countFor, MeteredD1, Refused } from "./sync_quota.mjs";
import { distinctJson, goneBy, HELD, named, namesJoined, pendingMove, putWritten, settle, STATEMENT, tidyLeftoversOf, writing, written } from "./sync_refs.mjs";

/** An object name: the SHA-256 of its bytes as 64 lowercase hex digits. */
export const NAME = /^[0-9a-f]{64}$/;

/** The fields of a body's image binding: each image's PNG and reduced JPEG. A missing field is unknown. */
const BINDING_FIELDS = ["campaign_png", "campaign_jpeg", "factor_png", "factor_jpeg", "skill_png", "skill_jpeg"];

const IMAGE_KINDS = { "image/png": "png", "image/jpeg": "jpeg" };
const CONTENT_TYPES = { png: "image/png", jpeg: "image/jpeg" };

/**
 * `vars.SYNC_ENABLED`: "true" or "false"; anything else is a configuration error. "false" answers
 * every endpoint under /api/sync/ 503 sync_paused; sharing and logins go on.
 */
export function syncEnabled(env) {
  if (env.SYNC_ENABLED === "true") return true;
  if (env.SYNC_ENABLED === "false") return false;
  throw new Error(`SYNC_ENABLED must be "true" or "false", got ${JSON.stringify(env.SYNC_ENABLED)}`);
}

export async function d1(op) {
  try {
    return await op();
  } catch (error) {
    throw new Unavailable("D1 refused the query", { cause: error });
  }
}

/**
 * Runs sync endpoint `handler(env)` behind the switch, answering what B2's failures and the daily
 * limits and capacity share. The handler gets `env` with its D1 counting the rows the request reads
 * and writes, and those are charged to the account it was admitted for (sync_quota.mjs) when it ends.
 */
export async function answerSync(env, now, handler) {
  if (!syncEnabled(env)) return fail(503, "sync_paused");
  const db = new MeteredD1(env.DB);
  try {
    return await handler({ ...env, DB: db });
  } catch (error) {
    if (error instanceof StorageFailed) return fail(502, "storage_unavailable");
    if (error instanceof Refused) return error.response;
    throw error;
  } finally {
    // A charge D1 refuses is lost: the request has its answer, and failing it now would not undo its work.
    await chargeRequest(db, clock(now)).catch(() => {});
  }
}

/** The names of `names` account `accountId` holds at clock `at`: stored, and not gone past the boundary. */
export async function heldNames(db, accountId, names, at) {
  const rows = await d1(() =>
    db
      .prepare(`SELECT o.name FROM ${namesJoined("?2")} WHERE ${HELD("?3", "o")}`)
      .bind(accountId, distinctJson(names), goneBy(at))
      .all(),
  );
  return new Set(rows.results.map((r) => r.name));
}

/**
 * The statement that records objects now stored in B2 (`{name, kind, size}` and, by kind, `binding`
 * (a body's `canonicalImages`),
 * `slot`, `record_count` and `refs`): a new row, the stored state of a row the list made for an
 * image before it was stored, or a row gone past the boundary at `at` stored anew, shown, its old
 * versions left to B2's lifecycle. A row another request stored first is kept. Its rows are the names
 * this request stored.
 */
export function insertObjects(db, accountId, rows, at) {
  return db
    .prepare(
      `${named(STATEMENT.PUT_RECORD)} INSERT INTO sync_objects (account_id, name, kind, size, binding, slot, record_count, refs, stored_at)
       SELECT ?1, json_extract(value, '$.name'), json_extract(value, '$.kind'), json_extract(value, '$.size'),
              json_extract(value, '$.binding'), json_extract(value, '$.slot'), json_extract(value, '$.record_count'),
              json_extract(value, '$.refs'), ?3
       FROM json_each(?2) WHERE 1
       ON CONFLICT (account_id, name) DO UPDATE SET kind = excluded.kind, size = excluded.size, stored_at = excluded.stored_at,
           hidden_at = NULL, hidden_since = NULL, hide_by = NULL, marker = NULL
         WHERE sync_objects.stored_at IS NULL OR sync_objects.hidden_since <= ?4
       RETURNING name`,
    )
    .bind(accountId, JSON.stringify(rows), at, goneBy(at));
}

/**
 * Records objects request `by` stored (see insertObjects) and, in the same batch, clears its records
 * of writing them (`putWritten`). What of them nothing references stays shown, a hide to do once
 * SYNC_ABANDONED_AFTER old.
 */
export async function storeObjects(db, accountId, by, rows, at) {
  await d1(() => db.batch([insertObjects(db, accountId, rows, at), putWritten(db, accountId, by)]));
}

/**
 * Puts `objects` (`{name, bytes}`) of account `accountId` for
 * request `by`, after recording that it is about to (`writing`). Returns whether B2 stored every one.
 * When it stored none, the records are cleared; when it stored some, they stay, for whoever takes them
 * to delete what it stored. A put that throws leaves them too: B2 may have stored it.
 */
export async function putAll(db, bucket, accountId, by, objects, at) {
  await d1(() => writing(db, accountId, by, objects.map((x) => x.name), at).run());
  const stored = await Promise.all(objects.map((x) => bucket.put(objectKey(accountId, x.name), x.bytes, x.name)));
  if (stored.every((s) => !s)) await d1(() => written(db, accountId, by).run());
  return !stored.includes(false);
}

/**
 * Runs sync write `handler(session, bucket, at)` on the session's account, `at` the request clock and
 * `bucket` the one bucket of the request, and when it answers 200, spends the B2 requests it left on
 * the hides and shows cut-off requests of the account left (`tidyLeftoversOf`).
 */
export async function syncWrite(request, env, now, handler) {
  const at = clock(now);
  const session = await requireSession(request, env, at.now);
  const bucket = new Bucket(env, now);
  const res = await handler(session, bucket, at);
  if (res.status === 200) await tidyLeftoversOf(env.DB, bucket, session.accountId, at.now);
  return res;
}

/**
 * GET /api/sync/generation: `{generation, root}` of the session's account; 0 and null before its first
 * sync. It is admitted against no daily limit and charged to none: it reads one row, and counting it
 * would write two.
 */
export async function getGeneration(request, env, now) {
  const session = await requireSession(request, env, clock(now).now);
  const row = await d1(() =>
    env.DB.prepare("SELECT generation, root_name FROM sync_accounts WHERE account_id = ?1").bind(session.accountId).first(),
  );
  return json(200, { generation: row?.generation ?? 0, root: row?.root_name ?? null });
}

/**
 * The images body text `text` names (its `metadata.binding` and `metadata.icon`) as canonical JSON,
 * or null when the text is not a body.
 */
function imagesOf(text) {
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return null;
  }
  return canonicalImages(body?.metadata?.binding, body?.metadata?.icon);
}

/**
 * The images a record names, image binding `binding` (a body's `metadata.binding`, or a list row's
 * `image`) and icon `icon` (a body's `metadata.icon`, or a list row's `icon`), as canonical JSON:
 * every binding field in a fixed order, a missing one as null, then `icon` when there is one. Null
 * when `binding` is not a binding or `icon` is neither missing, null nor an image name.
 */
export function canonicalImages(binding, icon) {
  if (binding === null || typeof binding !== "object" || Array.isArray(binding)) return null;
  for (const [key, value] of Object.entries(binding)) {
    if (!BINDING_FIELDS.includes(key)) return null;
    if (value !== null && (typeof value !== "string" || !NAME.test(value))) return null;
  }
  if (icon !== undefined && icon !== null && (typeof icon !== "string" || !NAME.test(icon))) return null;
  const images = Object.fromEntries(BINDING_FIELDS.map((f) => [f, binding[f] ?? null]));
  return JSON.stringify(icon == null ? images : { ...images, icon });
}

/**
 * POST /api/sync/bodies `{bodies: [{name, body}]}`, 1 to MAX_SYNC_BODIES_PER_REQUEST of them: stores
 * each body text under its name. Answers `{results: [{name, status}]}`, status "stored" or "exists"
 * (the account held it already). A body whose name is not the SHA-256 of its UTF-8 bytes, or that
 * carries no image binding or an icon that is not an image name, refuses the whole request with 400
 * and stores nothing.
 */
export const putBodies = (request, env, now) =>
  syncWrite(request, env, now, async (session, bucket, clk) => {
    const at = clk.now;
    const { bodies } = envelope(await readJson(request, limits.MAX_SYNC_BODIES_REQUEST), ["bodies"]);
    if (!Array.isArray(bodies) || bodies.length === 0 || bodies.length > limits.MAX_SYNC_BODIES_PER_REQUEST) {
      throw new InvalidPayload("bodies");
    }
    const items = [];
    for (const [i, item] of bodies.entries()) {
      const { name, body } = envelope(item, ["name", "body"]);
      if (typeof name !== "string" || !NAME.test(name) || typeof body !== "string") throw new InvalidPayload(`bodies[${i}]`);
      const bytes = new TextEncoder().encode(body);
      if (bytes.length > limits.MAX_SYNC_BODY) throw new InvalidPayload(`bodies[${i}].body`);
      if ((await sha256Hex(bytes)) !== name) throw new InvalidPayload(`bodies[${i}].name`);
      const images = imagesOf(body);
      if (images === null) throw new InvalidPayload(`bodies[${i}].body`);
      if (!items.some((other) => other.name === name)) items.push({ name, bytes, images });
    }
    const held = await heldNames(env.DB, session.accountId, items.map((x) => x.name), at);
    const fresh = items.filter((x) => !held.has(x.name));
    // A body the account holds is answered "exists" whatever the limits: nothing new is stored.
    countFor(env.DB, session.accountId);
    if (fresh.length > 0) {
      await admit(env.DB, session.accountId, clk, "normal");
      await admitGrowth(env.DB, session.accountId, at, fresh.reduce((sum, x) => sum + x.bytes.length, 0));
    }
    if (fresh.length > 0) {
      const by = crypto.randomUUID();
      const objects = fresh.map((x) => ({ name: x.name, bytes: x.bytes }));
      // The Worker hashed every body itself, so a refusal here is B2 refusing the key, not the bytes.
      if (!(await putAll(env.DB, bucket, session.accountId, by, objects, at))) return fail(502, "storage_refused");
      const rows = fresh.map((x) => ({ name: x.name, kind: "body", size: x.bytes.length, binding: x.images }));
      await storeObjects(env.DB, session.accountId, by, rows, at);
    }
    return json(200, { results: items.map((x) => ({ name: x.name, status: held.has(x.name) ? "exists" : "stored" })) });
  });

/**
 * POST /api/sync/bodies/get `{names}`, 1 to MAX_SYNC_BODIES_PER_REQUEST of them: `{bodies: [{name,
 * body}]}` in the order asked. When any of them is one the account does not hold or its current root
 * does not reference, 404 not_found with `{names}` listing those, and no body.
 */
export async function getBodies(request, env, now) {
  const clk = clock(now);
  const at = clk.now;
  const session = await requireSession(request, env, at);
  await admit(env.DB, session.accountId, clk, "normal");
  const { names } = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["names"]);
  if (!Array.isArray(names) || names.length === 0 || names.length > limits.MAX_SYNC_BODIES_PER_REQUEST) {
    throw new InvalidPayload("names");
  }
  for (const [i, name] of names.entries()) if (typeof name !== "string" || !NAME.test(name)) throw new InvalidPayload(`names[${i}]`);
  const held = await d1(() =>
    env.DB.prepare(`SELECT o.name FROM ${namesJoined("?2")} WHERE o.kind = 'body' AND o.ref_count > 0 AND ${HELD("?3", "o")}`)
      .bind(session.accountId, distinctJson(names), goneBy(at))
      .all(),
  );
  const heldSet = new Set(held.results.map((r) => r.name));
  const bucket = new Bucket(env, now);
  const texts = await Promise.all(
    names.map(async (name) => {
      if (!heldSet.has(name)) return null;
      const res = await bucket.get(objectKey(session.accountId, name));
      return res === null ? null : res.text();
    }),
  );
  const missing = names.filter((_, i) => texts[i] === null);
  if (missing.length > 0) return fail(404, "not_found", { names: missing });
  return json(200, { bodies: names.map((name, i) => ({ name, body: texts[i] })) });
}

/** The image forms an account may choose: which images it syncs. */
const IMAGE_FORMS = ["png", "jpeg", "none"];

/**
 * The image form of an account that has no sync_accounts row yet: the default of the row's image_form
 * column (migrations/0011_sync_image_form_default.sql), which is what every row is made with unless a
 * PUT /api/sync/settings makes it. The two must agree, or a new account's first answer would differ
 * from the form its row then holds.
 */
const NEW_ACCOUNT_IMAGE_FORM = "jpeg";

/** The image form of account `accountId`: NEW_ACCOUNT_IMAGE_FORM until its row holds one. */
async function imageForm(db, accountId) {
  const row = await d1(() => db.prepare("SELECT image_form FROM sync_accounts WHERE account_id = ?1").bind(accountId).first());
  return row?.image_form ?? NEW_ACCOUNT_IMAGE_FORM;
}

/**
 * Whether account `accountId` takes a new image `name` of `kind` at clock `at`. Any, when its form
 * is "png" or "jpeg". Under "none", only a reduced JPEG an archive put in place of its PNG: one whose
 * row the current root left `pending` (a replacement writes `pending`, so a part put and not yet in
 * the root makes none) with a PNG it references in the JPEG's place that the account holds.
 */
async function imageAccepted(db, accountId, name, kind, at) {
  if ((await imageForm(db, accountId)) !== "none") return true;
  if (kind !== "jpeg") return false;
  // The PNGs are looked up by name (IN): joined to the pending entries instead, the plan reads every
  // row of the account.
  const row = await d1(() =>
    db
      .prepare(
        `SELECT 1 FROM sync_objects j, sync_objects p
         WHERE j.account_id = ?1 AND j.name = ?2 AND j.kind = 'jpeg'
           AND p.account_id = ?1 AND p.name IN (SELECT key FROM json_each(j.pending) WHERE value > 0) AND p.kind = 'png' AND ${HELD("?3", "p")}
         LIMIT 1`,
      )
      .bind(accountId, name, goneBy(at))
      .first(),
  );
  return row !== null;
}

/** GET /api/sync/settings: `{image_form}` of the session's account. */
export async function getSettings(request, env, now) {
  const clk = clock(now);
  const session = await requireSession(request, env, clk.now);
  await admit(env.DB, session.accountId, clk, "normal");
  return json(200, { image_form: await imageForm(env.DB, session.accountId) });
}

/**
 * PUT /api/sync/settings `{image_form}`: sets the account's image form, "png", "jpeg" or "none". The
 * requests that follow it read the new form. Answers `{image_form}`.
 */
export async function putSettings(request, env, now) {
  const clk = clock(now);
  const session = await requireSession(request, env, clk.now);
  await admit(env.DB, session.accountId, clk, "normal");
  const { image_form: form } = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["image_form"]);
  if (!IMAGE_FORMS.includes(form)) throw new InvalidPayload("image_form");
  await d1(() =>
    env.DB.prepare(
      `INSERT INTO sync_accounts (account_id, image_form) VALUES (?1, ?2)
       ON CONFLICT (account_id) DO UPDATE SET image_form = excluded.image_form`,
    )
      .bind(session.accountId, form)
      .run(),
  );
  return json(200, { image_form: form });
}

/**
 * PUT /api/sync/images/<name> with the image's bytes as the body, Content-Type image/png or
 * image/jpeg and a Content-Length of at most MAX_SYNC_IMAGE: puts the bytes to B2 unhashed, signed
 * with `name`. 200 `{name, status}`, status "stored" or "exists". B2's refusal (the bytes do not hash
 * to the name, or B2 refused the key) is 502 storage_refused, and nothing is stored. A new image the
 * account's form does not take (`imageAccepted`) is 409 images_not_synced, before anything reaches B2.
 */
export const putImage = (request, env, name, now) =>
  syncWrite(request, env, now, async (session, bucket, clk) => {
    const at = clk.now;
    const kind = IMAGE_KINDS[request.headers.get("Content-Type")];
    if (kind === undefined) throw new InvalidPayload("content-type");
    const length = Number(request.headers.get("Content-Length"));
    if (request.headers.get("Content-Length") === null || !Number.isSafeInteger(length) || length < 0) {
      throw new InvalidPayload("content-length");
    }
    if (length > limits.MAX_SYNC_IMAGE) throw new InvalidPayload("body");
    const held = await heldNames(env.DB, session.accountId, [name], at);
    countFor(env.DB, session.accountId);
    if (held.has(name)) {
      await request.body?.cancel();
      return json(200, { name, status: "exists" });
    }
    if (!(await imageAccepted(env.DB, session.accountId, name, kind, at))) {
      await request.body?.cancel();
      return fail(409, "images_not_synced");
    }
    try {
      await admit(env.DB, session.accountId, clk, "normal");
      await admitGrowth(env.DB, session.accountId, at, length);
    } catch (error) {
      await request.body?.cancel();
      throw error;
    }
    // Read whole, so that a PUT B2 fails for a moment can send the bytes again (`Bucket.put`).
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.length !== length) throw new InvalidPayload("content-length");
    const db = env.DB;
    const by = crypto.randomUUID();
    if (!(await putAll(db, bucket, session.accountId, by, [{ name, bytes }], at))) return fail(502, "storage_refused");
    // Stored, and in the same batch, when it is a reduced JPEG the list references in place of a PNG,
    // those references taken off the PNG: from now on the list references the JPEG alone.
    const [, pending] = await d1(() =>
      db.batch([
        insertObjects(db, session.accountId, [{ name, kind, size: length, binding: null }], at),
        ...pendingMove(db, session.accountId, name),
        putWritten(db, session.accountId, by),
      ]),
    );
    // The PNGs whose references it took, at most SYNC_PNGS_PER_JPEG (replaceRoot keeps a root within
    // it), so they fit in one DeleteObjects: B2_ATTEMPTS + hideRequests(999) = 5 B2 requests. The image
    // itself stays shown: a JPEG that took them is referenced, and any other is a put's hide to do.
    const pngs = Object.entries(JSON.parse(pending.results[0]?.pending ?? "{}"))
      .filter(([, count]) => count > 0)
      .map(([png]) => png);
    await settle(db, bucket, session.accountId, pngs, at);
    return json(200, { name, status: "stored" });
  });

/** GET /api/sync/images/<name>: the image's bytes, or 404 not_found when the account holds no such image or its current root does not reference it. */
export async function getImage(request, env, name, now) {
  const clk = clock(now);
  const at = clk.now;
  const session = await requireSession(request, env, at);
  await admit(env.DB, session.accountId, clk, "normal");
  const row = await d1(() =>
    env.DB.prepare(`SELECT kind FROM sync_objects WHERE account_id = ?1 AND name = ?2 AND kind IN ('png', 'jpeg') AND ref_count > 0 AND ${HELD("?3")}`)
      .bind(session.accountId, name, goneBy(at))
      .first(),
  );
  if (row === null) return fail(404, "not_found");
  const res = await new Bucket(env, now).get(objectKey(session.accountId, name));
  if (res === null) return fail(404, "not_found");
  return new Response(res.body, {
    headers: { "Content-Type": CONTENT_TYPES[row.kind], "Cache-Control": "no-store", "X-Robots-Tag": "noindex" },
  });
}

/**
 * POST /api/sync/held `{names}`, 1 to MAX_SYNC_HELD_NAMES of them: `{held}`, the names of `names`
 * the account holds, in the order asked. It reads D1 alone, and answers what a put of each would: a
 * name held answers "exists", hidden or not, and one gone past the boundary is not held.
 */
export async function getHeld(request, env, now) {
  const clk = clock(now);
  const at = clk.now;
  const session = await requireSession(request, env, at);
  await admit(env.DB, session.accountId, clk, "normal");
  const { names } = envelope(await readJson(request, limits.MAX_SYNC_HELD_REQUEST), ["names"]);
  if (!Array.isArray(names) || names.length === 0 || names.length > limits.MAX_SYNC_HELD_NAMES) throw new InvalidPayload("names");
  for (const [i, name] of names.entries()) if (typeof name !== "string" || !NAME.test(name)) throw new InvalidPayload(`names[${i}]`);
  const held = await heldNames(env.DB, session.accountId, names, at);
  return json(200, { held: names.filter((name) => held.has(name)) });
}
