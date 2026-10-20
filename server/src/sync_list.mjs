// File sync's list under /api/sync/: the parts, the root that names them, and the replacement of an
// account's root, ordered by its generation. The list is split so that a replacement which changes a
// few records stores and checks a few parts, never the whole list.
//
// A root maps slots to parts. Slots "0" to "127" hold record parts: the rows of the records whose id
// falls in that number (`partNumber`). Slots "columns" and "dismissed" hold the column titles and the
// dismissed pairs, whose content the server does not read. A part is checked once, when it is put:
// every row's id falls in the part's number, no id appears twice, and the body each row names is
// stored with the image binding the row's `image` copies. A replacement uses only parts stored that
// way, so it reads no row: it moves the reference counts (sync_refs.mjs) by what the parts it swaps
// in and out reference, shows what it starts to reference and hides what it stops referencing, the
// replaced root included. A part, body or root hidden past the boundary B2's lifecycle sets is gone
// (sync_refs.mjs): a replacement does not take it, and one that showed what it references commits
// only while the Worker's clock, read after B2 answered, is still inside the boundary. The wire format
// is docs/sync-protocol.md.

import { clock, fail, json, envelope, readJson } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import { Bucket, objectKey, sha256Hex } from "./b2.mjs";
import * as limits from "./limits.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { Unavailable } from "./store.mjs";
import { canonicalBinding, d1, heldNames, insertObjects, NAME, putAll, storeObjects, syncWrite } from "./sync.mjs";
import { admit, admitDatabase, countFor, recordsRefusal } from "./sync_quota.mjs";
import {
  claimHidden,
  clearUnreferenced,
  deleteBatches,
  distinctJson,
  goneBy,
  goneNow,
  HELD,
  hideRequests,
  markersOf,
  mayStillMark,
  namesJoined,
  owned,
  putWritten,
  ReferenceChange,
  referencesOf,
  releaseClaim,
  settle,
  show,
  showReferenced,
} from "./sync_refs.mjs";

/** The list's format: the `format` of every root and part. */
export const SYNC_FORMAT = 1;

/** Record parts: a record's part is the SHA-256 of its id modulo this. */
export const RECORD_PARTS = 128;

/** The slots of the parts whose content the server does not read. */
const OPAQUE_SLOTS = ["columns", "dismissed"];

const SLOTS = new Set([...Array.from({ length: RECORD_PARTS }, (_, n) => String(n)), ...OPAQUE_SLOTS]);

/** A row's archive state: images kept as PNG ("normal"), as reduced JPEG, or none. */
const ARCHIVE_STATES = ["normal", "jpeg", "none"];

/** Characters of a record id at most. */
const MAX_RECORD_ID = 128;

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

/** Throws InvalidPayload(`field`) unless `value` holds exactly the keys `keys`. */
function exactKeys(value, keys, field) {
  const own = Object.keys(value);
  if (own.length !== keys.length || !keys.every((k) => Object.hasOwn(value, k))) throw new InvalidPayload(field);
}

/** The record part of record id `id`: the first two bytes of the SHA-256 of its UTF-8 bytes, big-endian, modulo RECORD_PARTS. */
export async function partNumber(id) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id)));
  return ((digest[0] << 8) | digest[1]) % RECORD_PARTS;
}

/**
 * Part text `text` checked for everything that needs no stored state: `{slot, rows, refs}`, rows
 * `{field, body, image}` (the body's name and the canonical binding the row copies) and refs the
 * names the rows reference (every body, and the images of rows whose archive state is not "none").
 */
async function readPart(text) {
  let part;
  try {
    part = JSON.parse(text);
  } catch {
    throw new InvalidPayload("part");
  }
  if (!isObject(part)) throw new InvalidPayload("part");
  if (part.format !== SYNC_FORMAT) throw new InvalidPayload("part.format");
  if (OPAQUE_SLOTS.includes(part.part)) {
    exactKeys(part, ["format", "part", "content"], "part");
    return { slot: part.part, rows: [], refs: referencesOf([]) };
  }
  exactKeys(part, ["format", "part", "records"], "part");
  if (!Number.isInteger(part.part) || part.part < 0 || part.part >= RECORD_PARTS) throw new InvalidPayload("part.part");
  if (!Array.isArray(part.records) || part.records.length === 0) throw new InvalidPayload("part.records");
  const ids = new Set();
  const rows = [];
  for (const [i, row] of part.records.entries()) {
    const field = `part.records[${i}]`;
    if (!isObject(row)) throw new InvalidPayload(field);
    const { id, body, archive, image } = row;
    if (typeof id !== "string" || id === "" || id.length > MAX_RECORD_ID) throw new InvalidPayload(`${field}.id`);
    if (ids.has(id) || (await partNumber(id)) !== part.part) throw new InvalidPayload(`${field}.id`);
    ids.add(id);
    if (!isObject(body) || typeof body.name !== "string" || !NAME.test(body.name)) throw new InvalidPayload(`${field}.body`);
    if (!isObject(archive) || !ARCHIVE_STATES.includes(archive.state)) throw new InvalidPayload(`${field}.archive`);
    const binding = canonicalBinding(image);
    if (binding === null) throw new InvalidPayload(`${field}.image`);
    rows.push({ field, body: body.name, image: binding, state: archive.state });
  }
  const refs = referencesOf(rows.map((r) => ({ body: r.body, state: r.state, binding: JSON.parse(r.image) })));
  return { slot: String(part.part), rows, refs };
}

/** Root text `text` checked: its slot-to-part map. */
function readRoot(text) {
  let root;
  try {
    root = JSON.parse(text);
  } catch {
    throw new InvalidPayload("root");
  }
  if (!isObject(root)) throw new InvalidPayload("root");
  exactKeys(root, ["format", "parts"], "root");
  if (root.format !== SYNC_FORMAT) throw new InvalidPayload("root.format");
  if (!isObject(root.parts)) throw new InvalidPayload("root.parts");
  for (const [slot, name] of Object.entries(root.parts)) {
    if (!SLOTS.has(slot) || typeof name !== "string" || !NAME.test(name)) throw new InvalidPayload(`root.parts.${slot}`);
  }
  return root.parts;
}

/**
 * POST /api/sync/parts `{name, part}`: stores part text `part` under `name`, the SHA-256 of its UTF-8
 * bytes. 200 `{name, status}`, status "stored" or "exists". A part that fails a check is 400
 * invalid_payload naming the field; one naming a body the account does not hold is 409
 * missing_objects with `{names}`, and one put when the D1 database has no room left is 507 database_full
 * (`admitDatabase`). None of them stores anything.
 */
export const putPart = (request, env, now) =>
  syncWrite(request, env, now, async (session, bucket, clk) => {
    const at = clk.now;
    const { name, part } = envelope(await readJson(request, limits.MAX_SYNC_PART_REQUEST), ["name", "part"]);
    if (typeof name !== "string" || !NAME.test(name)) throw new InvalidPayload("name");
    if (typeof part !== "string") throw new InvalidPayload("part");
    const bytes = new TextEncoder().encode(part);
    if (bytes.length > limits.MAX_SYNC_PART) throw new InvalidPayload("part");
    if ((await sha256Hex(bytes)) !== name) throw new InvalidPayload("name");
    const { slot, rows, refs } = await readPart(part);
    countFor(env.DB, session.accountId);
    if ((await heldNames(env.DB, session.accountId, [name], at)).has(name)) return json(200, { name, status: "exists" });
    // A part put may use the reserve the daily limits and the database keep for one replacement (sync_quota.mjs).
    await admit(env.DB, session.accountId, clk, "reserve");
    await admitDatabase(env.DB, "reserve");

    const bodies = [...new Set(rows.map((r) => r.body))];
    const stored = await d1(() =>
      env.DB.prepare(
        `SELECT o.name, o.binding FROM ${namesJoined("?2")} WHERE o.kind = 'body' AND ${HELD("?3", "o")}`,
      )
        .bind(session.accountId, distinctJson(bodies), goneBy(at))
        .all(),
    );
    const bindings = new Map(stored.results.map((r) => [r.name, r.binding]));
    for (const row of rows) {
      if (bindings.has(row.body) && bindings.get(row.body) !== row.image) throw new InvalidPayload(`${row.field}.image`);
    }
    const missing = bodies.filter((b) => !bindings.has(b));
    if (missing.length > 0) return fail(409, "missing_objects", { names: missing });

    const by = crypto.randomUUID();
    if (!(await putAll(env.DB, bucket, session.accountId, by, [{ name, body: bytes, length: bytes.length }], at))) {
      return fail(502, "storage_refused");
    }
    const row = { name, kind: "part", size: bytes.length, slot, record_count: rows.length, refs: JSON.stringify(refs) };
    await storeObjects(env.DB, session.accountId, by, [row], at);
    return json(200, { name, status: "stored" });
  });

/** The generation of account `accountId`, 0 before its first replacement. */
async function generationOf(db, accountId) {
  const row = await d1(() => db.prepare("SELECT generation FROM sync_accounts WHERE account_id = ?1").bind(accountId).first());
  return row?.generation ?? 0;
}

/**
 * POST /api/sync/root `{generation, name, root}`: makes root text `root`, stored under `name` (the
 * SHA-256 of its UTF-8 bytes), the account's root, when the account is still at `generation`, and
 * advances the generation by one. 200 `{generation, root}` with the new generation and root name.
 *
 * Refusals change nothing: 409 stale_generation `{generation}` (the account's current one) when
 * another replacement came first, 409 missing_objects `{names}` when the root names a part the
 * account does not hold, 400 too_many_parts `{limit}` when it changes more than
 * SYNC_PARTS_PER_REPLACE slots of the current root, 409 too_many_objects when showing and hiding what
 * it changes would take more B2 requests than one request may make (`replaceRequests`, and the pages
 * that list the markers no hide recorded, `markersOf`), 400
 * too_many_pngs_per_jpeg `{limit}` when a reduced JPEG would stand in for more than
 * SYNC_PNGS_PER_JPEG PNGs, 400 invalid_payload for a malformed root or a part named in a slot that is
 * not its own, 507 database_full when the D1 database has no room left (`admitDatabase`).
 */
export const replaceRoot = (request, env, now) =>
  syncWrite(request, env, now, async (session, bucket, clk) => {
    const { now: at, day } = clk;
    const accountId = session.accountId;
    const { generation, name, root } = envelope(await readJson(request, limits.MAX_SYNC_ROOT_REQUEST), ["generation", "name", "root"]);
    if (!Number.isSafeInteger(generation) || generation < 0) throw new InvalidPayload("generation");
    if (typeof name !== "string" || !NAME.test(name)) throw new InvalidPayload("name");
    if (typeof root !== "string") throw new InvalidPayload("root");
    const bytes = new TextEncoder().encode(root);
    if (bytes.length > limits.MAX_SYNC_ROOT) throw new InvalidPayload("root");
    if ((await sha256Hex(bytes)) !== name) throw new InvalidPayload("name");
    const slots = readRoot(root);
    await admit(env.DB, accountId, clk, "reserve");
    await admitDatabase(env.DB, "reserve");

    const current = await d1(() =>
      env.DB.prepare(
        `SELECT a.generation, a.record_count, a.root_name, o.refs FROM sync_accounts a
         LEFT JOIN sync_objects o ON o.account_id = a.account_id AND o.name = a.root_name
         WHERE a.account_id = ?1`,
      )
        .bind(accountId)
        .first(),
    );
    const currentGeneration = current?.generation ?? 0;
    if (generation !== currentGeneration) return fail(409, "stale_generation", { generation: currentGeneration });
    const old = current?.refs ? JSON.parse(current.refs) : {};
    const changed = [...new Set([...Object.keys(old), ...Object.keys(slots)])].filter((s) => old[s] !== slots[s]);
    if (changed.length > limits.SYNC_PARTS_PER_REPLACE) {
      return fail(400, "too_many_parts", { limit: limits.SYNC_PARTS_PER_REPLACE });
    }

    const touched = changed.flatMap((s) => [old[s], slots[s]]).filter((n) => n !== undefined);
    // The parts it swaps out are the current root's, read whatever their state; the ones it swaps in
    // have to be held.
    const parts = await d1(() =>
      env.DB.prepare(
        `SELECT o.name, o.slot, o.record_count, o.refs, ${HELD("?3", "o")} AS held FROM ${namesJoined("?2")}
         WHERE o.kind = 'part' AND o.stored_at IS NOT NULL`,
      )
        .bind(accountId, distinctJson(touched), goneBy(at))
        .all(),
    );
    const byName = new Map(parts.results.map((r) => [r.name, r]));
    const missing = [];
    let recordCount = current?.record_count ?? 0;
    for (const s of changed) {
      if (old[s] !== undefined) recordCount -= byName.get(old[s])?.record_count ?? 0;
      if (slots[s] === undefined) continue;
      const part = byName.get(slots[s]);
      if (part === undefined || !part.held) missing.push(slots[s]);
      else if (part.slot !== s) throw new InvalidPayload(`root.parts.${s}`);
      else recordCount += part.record_count;
    }
    if (missing.length > 0) return fail(409, "missing_objects", { names: missing });
    const tooMany = recordsRefusal(recordCount, current?.record_count ?? 0);
    if (tooMany !== null) return tooMany;

    const change = new ReferenceChange();
    change.add(name, 1);
    if (current?.root_name) change.add(current.root_name, -1);
    for (const s of changed) {
      if (old[s] !== undefined && byName.has(old[s])) change.part(byName.get(old[s]), -1);
      if (slots[s] !== undefined) change.part(byName.get(slots[s]), 1);
    }
    const db = env.DB;
    const looked = await d1(() =>
      db
        .prepare(
          `SELECT o.name, ${HELD("?3", "o")} AS held, o.hidden_at, o.hide_by, o.marker, o.pending FROM ${namesJoined("?2")}`,
        )
        .bind(accountId, distinctJson([name, ...change.rising(), ...change.risingJpegs()]), goneBy(at))
        .all(),
    );
    const rows = new Map(looked.results.map((r) => [r.name, r]));
    // Held: stored, and not gone past the boundary. What is gone counts as never stored from here on.
    const stored = new Set(looked.results.filter((r) => r.held).map((r) => r.name));
    // A part's bodies were stored when it was put; look again, since a body may have gone since.
    const gone = change.risingBodies().filter((n) => !stored.has(n));
    if (gone.length > 0) return fail(409, "missing_objects", { names: gone });
    // The pending pairs it looked at are all its commit adds to: a commit follows no other replacement
    // since this one read the generation, and a JPEG's put only takes them away.
    for (const [jpeg, pngs] of change.risingPairsByJpeg()) {
      if (stored.has(jpeg)) continue;
      const pending = Object.entries(JSON.parse(rows.get(jpeg)?.pending ?? "{}")).filter(([, count]) => count > 0);
      if (new Set([...pending.map(([png]) => png), ...pngs]).size > limits.SYNC_PNGS_PER_JPEG) {
        return fail(400, "too_many_pngs_per_jpeg", { limit: limits.SYNC_PNGS_PER_JPEG });
      }
    }

    // What it shows before the commit: the hidden names it starts to reference and holds. Of those, only
    // the PNGs of the pairs it adds can end up unreferenced, when their JPEG is stored before the commit.
    const hidden = change
      .referencing(stored)
      .filter((n) => stored.has(n))
      .map((n) => rows.get(n))
      .filter((r) => r.hidden_at !== null);
    const pairPngs = change.risingPairPngs();
    const rehide = hidden.filter((r) => pairPngs.has(r.name)).map((r) => r.name);
    const rest = (targets) =>
      replaceRequests({
        put: stored.has(name) ? 0 : 1,
        targets,
        rising: change.rising().length,
        falling: change.falling().length + rehide.length,
        shown: hidden.length,
      });
    // Names whose hide recorded no marker take a page of listing at least.
    const listing = hidden.some((r) => r.marker === null) ? 1 : 0;
    if (listing + rest(hidden.length) > limits.B2_REQUESTS_PER_INVOCATION) return fail(409, "too_many_objects");
    // Take over the hides of what it shows before it reads their markers, so that cut off from here to
    // the commit it leaves them recorded (claimHidden), and give them back when it refuses before showing.
    const by = crypto.randomUUID();
    const undone = await claimHidden(db, accountId, hidden.map((r) => r.name), by, at);
    // Taken from a request that may still add a marker, after this one listed: such rows stay
    // recorded as referenced and hidden after the commit, and as a hide to do after a rollback.
    const live = undone.filter((r) => mayStillMark(r, at)).map((r) => r.name);
    const settled = undone.map((r) => r.name).filter((n) => !live.includes(n));
    // Not committed: hide again what it showed and nothing references. What a request took over from it
    // is that request's to hide, and what is gone at `bound` stays HIDING by this request, for a hide
    // once abandoned. The root it stored is recorded as any put is, shown and unreferenced, a hide to do.
    const undo = async (bound) => {
      await clearUnreferenced(db, accountId, by, settled, bound);
      await d1(() =>
        db.batch([insertObjects(db, accountId, [{ name, kind: "root", size: bytes.length, refs: JSON.stringify(slots) }], at), putWritten(db, accountId, by)]),
      );
      await settle(db, bucket, accountId, undone.map((r) => r.name), at);
    };
    // Listed the way the hourly run lists them, by the account's pages. Every marker over what it shows
    // has to be listed before it shows anything: refuse when they do not fit, and keep no listing for later.
    const { targets, listed } = await markersOf(bucket, accountId, undone, rest);
    const unlisted = undone.some((r) => r.marker === null && !listed.has(r.name));
    if (unlisted || bucket.sent + rest(targets.length) > limits.B2_REQUESTS_PER_INVOCATION) {
      await releaseClaim(db, accountId, by, undone);
      return fail(409, "too_many_objects");
    }

    if (!stored.has(name) && !(await putAll(db, bucket, accountId, by, [{ name, body: bytes, length: bytes.length }], at))) {
      await releaseClaim(db, accountId, by, undone);
      return fail(502, "storage_refused");
    }
    // Show what it starts to reference before the commit says it is referenced.
    await show(bucket, targets);
    // Commit only while what it showed is still inside the boundary at the Worker's clock read now,
    // after B2 answered the show: B2's lifecycle may have picked a version past it before the show
    // reached B2, and delete it after. Past it, what it showed is gone: hide it again and refuse.
    const bound = goneNow(bucket);
    const lapsed = undone.filter((r) => r.hidden_since <= bound).map((r) => r.name);
    if (lapsed.length > 0) {
      await undo(bound);
      return fail(409, "missing_objects", { names: lapsed });
    }
    try {
      await db.batch([
        // The condition: the account is still at `generation`. A first replacement inserts the row;
        // one that finds a row from a replacement that came first updates nothing.
        db
          .prepare(
            `INSERT INTO sync_accounts (account_id, generation, root_name, record_count, last_synced_day)
             VALUES (?1, ?2 + 1, ?3, ?4, ?5)
             ON CONFLICT (account_id) DO UPDATE SET generation = generation + 1, root_name = excluded.root_name,
               record_count = excluded.record_count, last_synced_day = excluded.last_synced_day
             WHERE generation = ?2`,
          )
          .bind(accountId, generation, name, recordCount, day),
        // The gate: when the condition changed nothing, json() fails on 'stale' and D1 rolls the
        // whole batch back, so nothing after it can commit for a stale replacement.
        db.prepare("SELECT json(CASE WHEN changes() = 1 THEN '1' ELSE 'stale' END)"),
        db
          .prepare(
            `INSERT INTO sync_objects (account_id, name, kind, size, refs, stored_at) VALUES (?1, ?2, 'root', ?3, ?4, ?5)
             ON CONFLICT (account_id, name) DO UPDATE SET stored_at = excluded.stored_at, hidden_at = NULL, hidden_since = NULL,
               hide_by = NULL, marker = NULL
             WHERE sync_objects.hidden_since <= ?6`,
          )
          .bind(accountId, name, bytes.length, JSON.stringify(slots), at, bound),
        ...change.statements(db, accountId, bound),
        ...owned(db, accountId, by, undone.map((r) => r.name), live),
        putWritten(db, accountId, by),
      ]);
    } catch (error) {
      await undo(bound);
      // A replacement that came first moved the generation; anything else is D1's failure.
      const latest = await generationOf(db, accountId);
      if (latest !== generation) return fail(409, "stale_generation", { generation: latest });
      throw new Unavailable("D1 refused the replacement", { cause: error });
    }
    // A hide that began before the commit may have hidden what it now references.
    await showReferenced(db, bucket, accountId, change.rising());
    await settle(db, bucket, accountId, [...change.falling(), ...rehide], at);
    return json(200, { generation: generation + 1, root: name });
  });

/**
 * The B2 requests a replacement takes after it has listed the markers no hide recorded: `put` (1 when
 * it stores its root), the DeleteObjects that show the `targets` markers before the commit, and then
 * the larger of what follows a commit — showing what a hide recorded among the `rising` names after
 * the look, and hiding among the `falling` names — and what follows a rollback: hiding the `shown`
 * names again. One slot of parts within MAX_SYNC_PART names at most 7,943 objects (64 hex
 * digits and two quotes each), which takes at most 1 + 8 + 8 + 2 × 12 = 41.
 */
function replaceRequests({ put, targets, rising, falling, shown }) {
  return put + deleteBatches(targets) + Math.max(deleteBatches(rising) + hideRequests(falling), hideRequests(shown));
}

/** GET of a list object of `kind` the account holds and its current root references, as stored; 404 not_found otherwise. */
async function getListObject(request, env, name, kind, now) {
  const clk = clock(now);
  const at = clk.now;
  const session = await requireSession(request, env, at);
  await admit(env.DB, session.accountId, clk, "normal");
  const row = await d1(() =>
    env.DB.prepare(`SELECT 1 FROM sync_objects WHERE account_id = ?1 AND name = ?2 AND kind = ?3 AND ref_count > 0 AND ${HELD("?4")}`)
      .bind(session.accountId, name, kind, goneBy(at))
      .first(),
  );
  if (row === null) return fail(404, "not_found");
  const res = await new Bucket(env, now).get(objectKey(session.accountId, name));
  if (res === null) return fail(404, "not_found");
  return new Response(res.body, {
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Robots-Tag": "noindex" },
  });
}

/** GET /api/sync/parts/<name>: the part's text. */
export const getPart = (request, env, name, now) => getListObject(request, env, name, "part", now);

/** GET /api/sync/roots/<name>: the root's text. */
export const getRoot = (request, env, name, now) => getListObject(request, env, name, "root", now);
