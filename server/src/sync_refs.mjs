// File sync's references and the visibility that follows them. Every sync_objects row counts the
// references to its name from the account's current root (ref_count): the root itself, each part it
// names, and what each part's rows reference. B2 shows an object exactly while its count is positive:
//
//   "After a replacement commits and every request has finished, every name the current root
//    references has a latest version in B2 that is not a delete marker."
//
// Hiding records its intent in D1 first and the markers after, and gives a marker back when its name
// was referenced meanwhile. Showing takes the row over in D1 first, deletes the marker in B2, and
// clears the row in the same batch that commits the replacement, then reads the rows again for a
// marker recorded in between.
//
// The request that makes a name unreferenced hides it before it answers, and the one that references
// a hidden name shows it before it commits. A put is the exception: what it stores is referenced by
// nothing until its sync's replacement takes it, so it leaves it shown, recorded as a hide to do once
// SYNC_ABANDONED_AFTER old, and the replacement that references it first has nothing to show. Hides
// and shows go to B2 a thousand names to a DeleteObjects, so the B2 requests they take follow from the
// number of names, and each endpoint bounds them before it changes anything (`hideRequests`).
//
// What a request owes and does not finish is left as data, and the data is the record of it. A row
// stored, shown and unreferenced (sync_objects_to_hide) is a hide to do: a put's, or a replacement's
// cut off after it made the name unreferenced and before its hide began. Cut off inside a hide or a
// show, or failed by B2 there, the row is hidden with no marker recorded and still names the request
// (sync_objects_hiding), whatever B2 holds. The account's next sync write and the hourly run hide both
// (`tidyLeftoversOf`, `hideLeftovers`), each once its row is SYNC_ABANDONED_AFTER old (by stored_at,
// and by hidden_at), and a replacement that references the name takes it out of either state first.
//
// Before a request writes anything under an account's prefix in B2 (an object it puts, or a marker it
// adds to hide one), it records the write in sync_writes (`writing`), and the statement that records
// what B2 then holds clears it (`written`). A request cut off in between, or writing to an account
// being deleted, leaves the record, and B2 may hold under that name a version no row accounts for. The
// same two take those too (`writeLeftovers`): once the record is old enough that its request is
// abandoned, they delete the versions it may have written unless the account holds the name and is
// not being deleted.
//
// A request cut off where the name it leaves hidden is referenced leaves the row referenced and
// hidden (sync_objects_to_show): a replacement after its commit and before it showed what a hide
// recorded after its look, and a hide after it found its row referenced or taken over and before it
// gave its marker back. A replacement that took a row over from a request that may still add a
// marker (`mayStillMark`) leaves it in this state too, since that request's marker may land after
// the replacement listed the name's. The account's next sync write and the hourly run show these
// once SYNC_ABANDONED_AFTER old (`tidyLeftoversOf`, `showLeftovers`), listing every marker in B2.
//
// B2's lifecycle deletes a hidden version from B2_DAYS_FROM_HIDING_TO_DELETING days after it was
// hidden, and may pick it for deletion while it is hidden and delete it after it was shown again. So a
// row hidden since (`hidden_since`, the first hide since the row was last shown, which re-hiding and
// taking the row over leave as it is) that long less RESTORE_MARGIN_SECONDS is gone (`goneBy`): it is
// not held (`HELD`), nothing shows it again, and a put of its name stores it anew. A show counts only
// when the Worker's clock read after B2 answered it is inside the boundary (`goneNow`): a replacement
// past it refuses and hides again what it showed, and the other shows leave the row hidden, gone.
//
// A gone row answers as no row does, and so does the row of an image never stored that nothing
// references. The hourly run deletes a gone row once nothing references it and no request is hiding
// it (`forgetLeftovers`), and the statement that leaves an unstored row unreferenced deletes it
// (`forgetUnstored`), so the rows follow what the account references and what it hid lately.

import { clock } from "./api.mjs";
import { accountPrefix, DELETE_OBJECTS_MAX, objectKey, StorageFailed } from "./b2.mjs";
import * as limits from "./limits.mjs";
import { d1 } from "./sync.mjs";
import { Unavailable } from "./store.mjs";

const IMAGES = ["campaign", "factor", "skill"];

/**
 * What the rows of a record part reference (rows `{body, state, images}`, the images an object of
 * image names: the binding's fields and, when the record has one, `icon`): `{always: {name: kind},
 * pending: [[png, jpeg]]}`. Every row references its body. A row archived without images references
 * no image and no icon. A row archived as reduced JPEG references each image's JPEG, and its PNG only
 * while that JPEG is not stored (`pending`). Any other row references every image its binding names.
 * Both reference the icon, a JPEG.
 */
export function referencesOf(rows) {
  const always = {};
  const pending = new Map();
  for (const { body, state, images } of rows) {
    always[body] = "body";
    if (state === "none") continue;
    if (images.icon != null) always[images.icon] = "jpeg";
    for (const image of IMAGES) {
      const png = images[`${image}_png`];
      const jpeg = images[`${image}_jpeg`];
      if (jpeg !== null) always[jpeg] = "jpeg";
      if (png === null) continue;
      if (state === "jpeg" && jpeg !== null) pending.set(`${png} ${jpeg}`, [png, jpeg]);
      else always[png] = "png";
    }
  }
  return { always, pending: [...pending.values()] };
}

/** How one replacement changes the references, by name. */
export class ReferenceChange {
  /** name → change of its count from the root, its parts and their rows' `always`. */
  #counts = new Map();
  /** name → kind, for the images a row names, which may not be stored yet. */
  #images = new Map();
  /** The bodies the rows name. */
  #bodies = new Set();
  /** "png jpeg" → change in the number of parts referencing that PNG in that JPEG's place. */
  #pairs = new Map();

  add(name, delta) {
    this.#counts.set(name, (this.#counts.get(name) ?? 0) + delta);
  }

  /** Adds (`delta` 1) or takes away (-1) part row `part` (`{name, refs}`) and what it references. */
  part(part, delta) {
    this.add(part.name, delta);
    const { always, pending } = JSON.parse(part.refs);
    for (const [name, kind] of Object.entries(always)) {
      this.add(name, delta);
      if (kind === "body") this.#bodies.add(name);
      else this.#images.set(name, kind);
    }
    for (const [png, jpeg] of pending) {
      const key = `${png} ${jpeg}`;
      this.#pairs.set(key, (this.#pairs.get(key) ?? 0) + delta);
      this.#images.set(png, "png");
    }
  }

  /** The pending pairs whose count changes, `[png, jpeg, delta]`. */
  #changedPairs() {
    return [...this.#pairs].filter(([, d]) => d !== 0).map(([key, d]) => [...key.split(" "), d]);
  }

  /** Names whose count may rise: those it adds to, and the PNGs of the pending pairs it adds. */
  rising() {
    const names = [...this.#counts].filter(([, d]) => d > 0).map(([n]) => n);
    for (const [png, , d] of this.#changedPairs()) if (d > 0) names.push(png);
    return [...new Set(names)];
  }

  /** Names whose count may fall to zero. */
  falling() {
    const names = [...this.#counts].filter(([, d]) => d < 0).map(([n]) => n);
    for (const [png, , d] of this.#changedPairs()) if (d < 0) names.push(png);
    return [...new Set(names)];
  }

  /**
   * The names among `rising()` it does reference after it commits, given `stored` the set of names
   * stored: all but the PNGs it adds only in place of JPEGs that are stored.
   */
  referencing(stored) {
    const out = new Set([...this.#counts].filter(([, d]) => d > 0).map(([n]) => n));
    for (const [png, jpeg, d] of this.#changedPairs()) if (d > 0 && !stored.has(jpeg)) out.add(png);
    return [...out];
  }

  /** The JPEGs of the pending pairs it adds. */
  risingJpegs() {
    return this.#changedPairs().filter(([, , d]) => d > 0).map(([, jpeg]) => jpeg);
  }

  /** JPEG → the PNGs it adds pending pairs of. */
  risingPairsByJpeg() {
    const out = new Map();
    for (const [png, jpeg, d] of this.#changedPairs()) if (d > 0) out.set(jpeg, [...(out.get(jpeg) ?? []), png]);
    return out;
  }

  /**
   * The PNGs of the pending pairs it adds: the only names it may show and still leave unreferenced,
   * when their JPEG is stored between its look and its commit.
   */
  risingPairPngs() {
    return new Set(this.#changedPairs().filter(([, , d]) => d > 0).map(([png]) => png));
  }

  /** The bodies it adds references to. */
  risingBodies() {
    return [...this.#counts].filter(([n, d]) => d > 0 && this.#bodies.has(n)).map(([n]) => n);
  }

  /**
   * The statements that apply the change, for the batch that commits the replacement: a row for each
   * image named and not held yet, the row of each image named and gone at `bound` (`goneBy`) made one
   * not stored, as if never put, one UPDATE per distinct change of count, per pending pair the
   * PNG's count and the JPEG's `pending`, both only while the JPEG is not stored (a JPEG put moves
   * what `pending` holds off the PNGs in the same batch that marks it stored), and last the deletion of
   * the rows of images it leaves not stored and referenced by nothing (`forgetUnstored`).
   */
  statements(db, accountId, bound) {
    const out = [];
    const rising = new Set(this.rising());
    const images = [...this.#images].filter(([n]) => rising.has(n));
    if (images.length > 0) {
      // A row in conflict that is gone at `bound` is made not stored; a row inserted has no
      // hidden_since, so the condition leaves it as inserted.
      out.push(
        db
          .prepare(
            `INSERT INTO sync_objects (account_id, name, kind)
             SELECT ?1, json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?2) WHERE 1
             ON CONFLICT (account_id, name) DO UPDATE SET stored_at = NULL, size = NULL, hidden_at = NULL, hidden_since = NULL,
               hide_by = NULL, marker = NULL
             WHERE sync_objects.hidden_since <= ?3`,
          )
          .bind(accountId, JSON.stringify(images), bound),
      );
    }
    const byDelta = new Map();
    for (const [name, d] of this.#counts) if (d !== 0) byDelta.set(d, [...(byDelta.get(d) ?? []), name]);
    for (const [d, names] of byDelta) {
      for (const { list, names: chunk } of namesBound(names, 3)) {
        out.push(db.prepare(`UPDATE sync_objects SET ref_count = ref_count + ?2 WHERE account_id = ?1 AND name IN ${list}`).bind(accountId, d, ...chunk));
      }
    }
    for (const [png, jpeg, d] of this.#changedPairs()) {
      out.push(
        db
          .prepare(
            `UPDATE sync_objects SET ref_count = ref_count + ?4 WHERE account_id = ?1 AND name = ?2
               AND (SELECT stored_at FROM sync_objects WHERE account_id = ?1 AND name = ?3) IS NULL`,
          )
          .bind(accountId, png, jpeg, d),
        db
          .prepare(
            `UPDATE sync_objects SET pending = json_set(coalesce(pending, '{}'), '$."' || ?2 || '"',
               coalesce(json_extract(pending, '$."' || ?2 || '"'), 0) + ?4)
             WHERE account_id = ?1 AND name = ?3 AND stored_at IS NULL`,
          )
          .bind(accountId, png, jpeg, d),
      );
    }
    // The images whose count it lowers, and the PNGs of the pairs it adds, which it names and does not
    // count when their JPEG is stored: the only rows of images it can leave not stored and unreferenced.
    const unreferenced = [...new Set([...this.falling(), ...this.risingPairPngs()])].filter((n) => this.#images.has(n));
    out.push(...forgetUnstored(db, accountId, unreferenced));
    return out;
  }
}

/**
 * The statements that delete, among `names` of account `accountId`, the rows not stored and referenced
 * by nothing: the rows of images a list named and nobody put. Such a row stands for nothing in B2 and
 * answers as no row does (a put of its name stores it, a replacement that names it writes it anew), so
 * the statement that leaves it unreferenced deletes it, in the same batch.
 */
function forgetUnstored(db, accountId, names) {
  return namesBound(names, 2).map(({ list, names: chunk }) =>
    db
      .prepare(`DELETE FROM sync_objects WHERE account_id = ?1 AND name IN ${list} AND stored_at IS NULL AND ref_count = 0`)
      .bind(accountId, ...chunk),
  );
}

/**
 * The statements that move JPEG `jpeg`'s `pending` off its PNGs, for the batch that marks it stored:
 * the PNG names (a SELECT whose one row holds `pending`), the decrement, the deletion of the rows of
 * those PNGs it leaves not stored and referenced by nothing (as `forgetUnstored`), and the clear.
 */
export function pendingMove(db, accountId, jpeg) {
  return [
    db.prepare("SELECT pending FROM sync_objects WHERE account_id = ?1 AND name = ?2").bind(accountId, jpeg),
    db
      .prepare(
        `UPDATE sync_objects SET ref_count = ref_count -
           (SELECT w.value FROM sync_objects j, json_each(j.pending) w WHERE j.account_id = ?1 AND j.name = ?2 AND w.key = sync_objects.name)
         WHERE account_id = ?1 AND name IN (SELECT w.key FROM sync_objects j, json_each(j.pending) w WHERE j.account_id = ?1 AND j.name = ?2)`,
      )
      .bind(accountId, jpeg),
    db
      .prepare(
        `DELETE FROM sync_objects WHERE account_id = ?1 AND stored_at IS NULL AND ref_count = 0
           AND name IN (SELECT w.key FROM sync_objects j, json_each(j.pending) w WHERE j.account_id = ?1 AND j.name = ?2)`,
      )
      .bind(accountId, jpeg),
    db.prepare("UPDATE sync_objects SET pending = NULL WHERE account_id = ?1 AND name = ?2 AND pending IS NOT NULL").bind(accountId, jpeg),
  ];
}

/** DeleteObjects requests that `n` targets take. */
export const deleteBatches = (n) => Math.ceil(n / DELETE_OBJECTS_MAX);

/**
 * B2 requests `settle` over `n` names takes at most: a DeleteObjects per thousand names it hides, and
 * as many again to give back the markers of names referenced meanwhile.
 */
export const hideRequests = (n) => 2 * deleteBatches(n);

// The leftover queries name the partial index of the state they look for (INDEXED BY). Left to the
// planner, which has no statistics, the index ties with the primary key's account_id prefix and loses,
// so the query reads every row of the account on every sync write. Named, it reads the rows in that
// state alone, and a WHERE that stops implying the index's fails the statement instead of scanning.

/** The condition of a row whose hide is still to do and not begun: what sync_objects_to_hide indexes. */
const TO_HIDE = "ref_count = 0 AND hidden_at IS NULL AND stored_at IS NOT NULL";

/**
 * The condition of a row a request began to hide or show and recorded no marker for: what
 * sync_objects_hiding indexes. B2 may show or hide it, and may hold markers over it no row names.
 * It is abandoned once its `hidden_at` is SYNC_ABANDONED_AFTER old.
 */
const HIDING = "ref_count = 0 AND hidden_at IS NOT NULL AND marker IS NULL AND hide_by IS NOT NULL";

/**
 * The condition of a row the current root references and a request left hidden, or may have: what
 * sync_objects_to_show indexes. Its request is abandoned once its `hidden_at` is SYNC_ABANDONED_AFTER old.
 */
const TO_SHOW = "ref_count > 0 AND hidden_at IS NOT NULL";

/** The `hidden_at` at or before which a HIDING or TO_SHOW row counts as abandoned at clock `at`. */
const abandonedBy = (at) => at - limits.SYNC_ABANDONED_AFTER;

/** The `hidden_since` at or before which a hidden row counts as gone at clock `at`: B2's lifecycle may have deleted it. */
export const goneBy = (at) => at - (limits.B2_DAYS_FROM_HIDING_TO_DELETING * 86_400 - limits.RESTORE_MARGIN_SECONDS);

/** `goneBy` at the Worker's clock read now, after what B2 answered: the boundary a show just made has to be inside. */
export const goneNow = (bucket) => goneBy(clock(bucket.now).now);

/**
 * The condition of a row the account holds, with SQL parameter `bound` bound to `goneBy` of the
 * clock: stored, and not hidden past the boundary. A row outside it is gone, whatever B2 still holds.
 * `table` qualifies the columns when the query names more than one row.
 */
export const HELD = (bound, table = null) => {
  const col = (c) => (table === null ? c : `${table}.${c}`);
  return `${col("stored_at")} IS NOT NULL AND (${col("hidden_since")} IS NULL OR ${col("hidden_since")} > ${bound})`;
};

/** The condition of account `?1` that clears a record of a write: it exists and is not being deleted. */
const LIVE = "EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND deleting_since IS NULL)";

/**
 * The statement that records, before request `by` asks B2 to write `names` under the prefix of account
 * `accountId` at clock `at`, that it is about to (sync_writes): one row, whatever the number of names.
 * It references no account, so it is written for an account deleted meanwhile too.
 */
export const writing = (db, accountId, by, names, at) =>
  db.prepare("INSERT INTO sync_writes (account_id, write_by, names, written_at) VALUES (?1, ?2, ?3, ?4)").bind(accountId, by, distinctJson(names), at);

/**
 * The statement that clears the records `writing` made for request `by`, for the statement or batch
 * that records what B2 holds after its writes. It clears nothing while the account is being deleted or
 * is gone: what the request wrote may be under a prefix the deletion has already emptied.
 */
export const written = (db, accountId, by) =>
  db.prepare(`DELETE FROM sync_writes WHERE account_id = ?1 AND write_by = ?2 AND ${LIVE}`).bind(accountId, by);

/**
 * `written` for the batch that records what request `by` put (`insertObjects`), after that statement:
 * it clears nothing while a name the request put has a row hidden and referenced by nothing. Such a row
 * is one another request stored and hid while this one was putting, and B2 may show what this one put
 * over the marker; the record stays, for `writeLeft` to have the row hidden again.
 */
export const putWritten = (db, accountId, by) =>
  db
    .prepare(
      `DELETE FROM sync_writes WHERE account_id = ?1 AND write_by = ?2 AND ${LIVE}
         AND NOT EXISTS (SELECT 1 FROM json_each(sync_writes.names) j CROSS JOIN sync_objects o ON o.account_id = ?1 AND o.name = j.value
           WHERE o.ref_count = 0 AND o.hidden_at IS NOT NULL)`,
    )
    .bind(accountId, by);

/**
 * The `written_at` at or before which a record of a write is taken at clock `at`: its request is
 * abandoned, and every version it may have written (`writtenBy`) is older than any a request beginning
 * now writes, the Worker's clock and B2's apart by RESTORE_MARGIN_SECONDS at most.
 */
const unwrittenBy = (at) => at - limits.SYNC_ABANDONED_AFTER - 2 * limits.RESTORE_MARGIN_SECONDS;

/** B2's LastModified at or before which a version may have been written by a request whose record says `writtenAt`. */
const writtenBy = (writtenAt) => writtenAt + limits.SYNC_ABANDONED_AFTER + limits.RESTORE_MARGIN_SECONDS;

// A list of names reaches a statement in one of two forms, each reading about two rows per name where
// `name IN (SELECT value FROM json_each(?))` reads three (a SELECT) or four (an UPDATE):
// - a SELECT puts the list outside and looks each name up by the primary key (`namesJoined`);
// - an UPDATE binds each name as a parameter (`namesBound`), since an UPDATE cannot drive its rows
//   from a join without reading every row of the account for each name. D1 binds 100 parameters per
//   statement at most, so the list is split over as many statements as it takes, run in one batch,
//   which D1 runs as one transaction: the statements together change what the one statement did.

/** Names one statement binds at most: D1's 100 parameters per statement, less room for its own. */
const NAMES_PER_STATEMENT = 90;

/**
 * The distinct `names` in lists of NAMES_PER_STATEMENT at most, each `{list, names}`: `list` the SQL
 * `(?first, ?first+1, …)` its names bind to, from parameter `first` on.
 */
export function namesBound(names, first) {
  const all = [...new Set(names)];
  const out = [];
  for (let i = 0; i < all.length; i += NAMES_PER_STATEMENT) {
    const chunk = all.slice(i, i + NAMES_PER_STATEMENT);
    out.push({ list: `(${chunk.map((_, j) => `?${first + j}`).join(", ")})`, names: chunk });
  }
  return out;
}

/**
 * The FROM of a SELECT over the rows of account `?1` among names `?<param>` (a JSON array of distinct
 * names, `JSON.stringify([...new Set(names)])`), the rows as `o`: the list drives, each name found by
 * the primary key. A name listed twice would return its row twice.
 */
export const namesJoined = (param) => `json_each(${param}) j CROSS JOIN sync_objects o ON o.account_id = ?1 AND o.name = j.value`;

/** `names` as the JSON array `namesJoined` reads: each name once. */
export const distinctJson = (names) => JSON.stringify([...new Set(names)]);

/**
 * The results of statements `statements`, as one array of their rows: one runs alone, more run in one
 * batch, so that together they commit or fail as the one statement they split would.
 */
export async function allOf(db, statements) {
  if (statements.length === 0) return [];
  if (statements.length === 1) return (await d1(() => statements[0].all())).results;
  return (await d1(() => db.batch(statements))).flatMap((r) => r.results);
}

/**
 * Names of the statements a request can be cut off at, which tests find a statement by (`named`): the
 * name says which step of a put, a hide or a show it is, whatever form the SQL takes.
 */
export const STATEMENT = Object.freeze({
  /** A hide's (a), recording its intent (`settle`). */
  HIDE_INTENT: "hide_intent",
  /** A hide's (c), recording its markers (`settle`). */
  HIDE_RECORD: "hide_record",
  /** A replacement's first statement after its commit (`showReferenced`). */
  SHOW_REFERENCED: "show_referenced",
  /** A put's record of what B2 stored (`insertObjects`), after which it clears the record of its write. */
  PUT_RECORD: "put_record",
});

/** The SQL comment that names a statement `name` (one of STATEMENT), put first in its SQL. */
export const named = (name) => `/* ${name} */`;

/**
 * Whether row `row` (`{hidden_at, hide_by, marker}`, as `claimHidden` read it) names a request that
 * may still add a marker over it in B2 at clock `at`: one that began a hide or a show, recorded no
 * marker, and is not abandoned.
 */
export const mayStillMark = (row, at) => row.hide_by !== null && row.marker === null && row.hidden_at > abandonedBy(at);

/**
 * Hides, among `names` of account `accountId`, every one that is stored, shown and referenced by
 * nothing, in at most `hideRequests(names.length)` B2 requests: (a) records the intent on those rows,
 * (b) adds a marker over each in B2, (c) records each marker on its row while the row is still this
 * hide's and unreferenced, and gives back the markers of the rest. A row B2 failed for, or reported no
 * marker for, stays HIDING, the state a request cut off between (a) and (c) leaves. (a) starts the
 * rows' `hidden_since`, which nothing here moves after. Between (a) and (b) it records the markers it
 * is about to add (`writing`), and clears the record once (c) and the giving back are done (`written`).
 *
 * With `abandoned`, it also takes over the abandoned HIDING rows among `names` and hides them again
 * the same way, except that (c) records no marker for them: B2 may hold others over the name that no
 * row names, so a show lists them all (`markersOf`). It marks them hidden by no request instead.
 */
export async function settle(db, bucket, accountId, names, at, { abandoned = false } = {}) {
  if (names.length === 0) return;
  const by = crypto.randomUUID();
  const fresh = await allOf(
    db,
    namesBound(names, 4).map(({ list, names: chunk }) =>
      db
        .prepare(
          `${named(STATEMENT.HIDE_INTENT)} UPDATE sync_objects SET hidden_at = ?2, hide_by = ?3, marker = NULL, hidden_since = ?2
           WHERE account_id = ?1 AND name IN ${list} AND ${TO_HIDE}
           RETURNING name`,
        )
        .bind(accountId, at, by, ...chunk),
    ),
  );
  const retaken = abandoned
    ? await allOf(
        db,
        namesBound(names, 5).map(({ list, names: chunk }) =>
          db
            .prepare(
              `UPDATE sync_objects SET hidden_at = ?2, hide_by = ?3
               WHERE account_id = ?1 AND name IN ${list} AND ${HIDING} AND hidden_at <= ?4
               RETURNING name`,
            )
            .bind(accountId, at, by, abandonedBy(at), ...chunk),
        ),
      )
    : [];
  const recorded = new Set(fresh.map((r) => r.name));
  const hidden = [...recorded, ...retaken.map((r) => r.name)];
  if (hidden.length === 0) return;
  await d1(() => writing(db, accountId, by, hidden, at).run());
  await hide(db, bucket, accountId, by, hidden, recorded);
  await d1(() => written(db, accountId, by).run());
}

/** `settle`'s (b), (c) and the giving back, for the rows `hidden` it took for request `by`, `recorded` those (a) took. */
async function hide(db, bucket, accountId, by, hidden, recorded) {
  const markers = new Map();
  try {
    for (let i = 0; i < hidden.length; i += DELETE_OBJECTS_MAX) {
      const chunk = hidden.slice(i, i + DELETE_OBJECTS_MAX);
      const got = await bucket.hideObjects(chunk.map((n) => objectKey(accountId, n)));
      for (const name of chunk) if (got.has(objectKey(accountId, name))) markers.set(name, got.get(objectKey(accountId, name)));
    }
  } catch (error) {
    if (!(error instanceof StorageFailed)) throw error;
  }
  if (markers.size === 0) return;
  const toRecord = [...markers].filter(([name]) => recorded.has(name));
  const toRelease = [...markers.keys()].filter((name) => !recorded.has(name));
  const kept = new Set();
  if (toRecord.length > 0) {
    // Name to marker as one JSON object, each row's marker read by its name's path: a row looks up its
    // own entry rather than going through every entry, so the rows read follow the names, not their square.
    const marks = JSON.stringify(Object.fromEntries(toRecord));
    const rows = await allOf(
      db,
      namesBound(toRecord.map(([name]) => name), 4).map(({ list, names: chunk }) =>
        db
          .prepare(
            `${named(STATEMENT.HIDE_RECORD)} UPDATE sync_objects SET marker = json_extract(?3, '$."' || name || '"')
             WHERE account_id = ?1 AND hide_by = ?2 AND ref_count = 0 AND name IN ${list}
             RETURNING name`,
          )
          .bind(accountId, by, marks, ...chunk),
      ),
    );
    for (const r of rows) kept.add(r.name);
  }
  if (toRelease.length > 0) {
    const rows = await allOf(
      db,
      namesBound(toRelease, 3).map(({ list, names: chunk }) =>
        db
          .prepare(
            `UPDATE sync_objects SET hide_by = NULL
             WHERE account_id = ?1 AND hide_by = ?2 AND ref_count = 0 AND name IN ${list}
             RETURNING name`,
          )
          .bind(accountId, by, ...chunk),
      ),
    );
    for (const r of rows) kept.add(r.name);
  }
  // Referenced meanwhile, by a replacement that may have looked before these markers existed.
  const back = [...markers].filter(([name]) => !kept.has(name));
  let failed;
  try {
    failed = await deleteVersions(bucket, back.map(([name, versionId]) => ({ key: objectKey(accountId, name), versionId })));
  } catch (error) {
    if (error instanceof StorageFailed) return;
    throw error;
  }
  const shown = back.map(([name]) => name).filter((name) => !failed.has(objectKey(accountId, name)));
  if (shown.length === 0) return;
  // A row given back past the boundary stays hidden, gone: B2 may delete what it shows.
  const bound = goneNow(bucket);
  await allOf(
    db,
    namesBound(shown, 4).map(({ list, names: chunk }) =>
      db
        .prepare(
          `UPDATE sync_objects SET hidden_at = NULL, hide_by = NULL, marker = NULL, hidden_since = NULL
           WHERE account_id = ?1 AND hide_by = ?2 AND name IN ${list} AND hidden_since > ?3`,
        )
        .bind(accountId, by, bound, ...chunk),
    ),
  );
}

/**
 * Deletes `targets` (`{key, versionId}`) for good, a DeleteObjects per thousand. Returns the keys B2
 * reported as errors.
 */
async function deleteVersions(bucket, targets) {
  const failed = new Set();
  for (let i = 0; i < targets.length; i += DELETE_OBJECTS_MAX) {
    for (const e of await bucket.deleteObjects(targets.slice(i, i + DELETE_OBJECTS_MAX))) failed.add(e.key);
  }
  return failed;
}

/**
 * The markers that hide rows `rows` (`{name, marker}`) of `accountId`, as DeleteObjects targets: each
 * recorded marker, and every marker B2 lists over the names that record none (`listVersionsOf`), read
 * while `bucket` has room for a page and for `after(n)` B2 requests more, n the targets it would hold
 * after that page at most. Returns `{targets, listed}`, listed the names recording no marker whose
 * every version it read: the targets are every marker over the rows only when `listed` holds them all.
 */
export async function markersOf(bucket, accountId, rows, after) {
  const recorded = rows.filter((r) => r.marker !== null).map((r) => ({ key: objectKey(accountId, r.name), versionId: r.marker }));
  const names = rows.filter((r) => r.marker === null).map((r) => r.name).sort();
  const { targets, listed } = await listVersionsOf(bucket, accountId, names, (e) => e.marker, (n) => after(recorded.length + n));
  return { targets: [...recorded, ...targets], listed };
}

/** Deletes markers `targets` (from `markersOf`) to show what they hide; B2 failing any of them fails. */
export async function show(bucket, targets) {
  const failed = await deleteVersions(bucket, targets);
  if (failed.size > 0) throw new StorageFailed("DeleteObjects", "an error for some objects");
}

/**
 * Takes the hidden rows among `names` for request `by` before it shows them: in one batch, reads each
 * one's `{name, hidden_at, hide_by, marker, hidden_since}` and makes it HIDING by `by`, its
 * `hidden_since` kept. Returns the rows as they were.
 *
 * From then on a hide's (c) finds the row not its own and gives its marker back, and a request cut off
 * before its commit leaves the row HIDING, for the account's next write or the hourly run to hide again
 * once abandoned. A request that takes over an abandoned row takes it from `by` too, which `owned`
 * lets the commit find. With `abandoned`, it takes only the rows whose request is abandoned.
 */
export async function claimHidden(db, accountId, names, by, at, { abandoned = false } = {}) {
  if (names.length === 0) return [];
  const before = abandoned ? abandonedBy(at) : null;
  const [rows] = await d1(() =>
    db.batch([
      db
        .prepare(
          `SELECT o.name, o.hidden_at, o.hide_by, o.marker, o.hidden_since FROM ${namesJoined("?2")}
           WHERE o.hidden_at IS NOT NULL AND (?3 IS NULL OR o.hidden_at <= ?3)`,
        )
        .bind(accountId, distinctJson(names), before),
      ...namesBound(names, 5).map(({ list, names: chunk }) =>
        db
          .prepare(
            `UPDATE sync_objects SET hidden_at = ?2, hide_by = ?3, marker = NULL
             WHERE account_id = ?1 AND name IN ${list} AND hidden_at IS NOT NULL AND (?4 IS NULL OR hidden_at <= ?4)`,
          )
          .bind(accountId, at, by, before, ...chunk),
      ),
    ]),
  );
  return rows.results;
}

/**
 * Gives the rows `claimed` (from `claimHidden`) that `by` still holds back as they were, for a request
 * that took them and refuses before it showed anything.
 */
export async function releaseClaim(db, accountId, by, claimed) {
  if (claimed.length === 0) return;
  // Name to the row as it was, each row reading its own entry by its name's path, so that the rows are
  // found by name: joined to the list instead, the account's rows are read once per entry.
  const before = Object.fromEntries(claimed.map((r) => [r.name, { hidden_at: r.hidden_at, hide_by: r.hide_by, marker: r.marker }]));
  const rows = JSON.stringify(before);
  await allOf(
    db,
    namesBound(Object.keys(before), 4).map(({ list, names: chunk }) =>
      db
        .prepare(
          `UPDATE sync_objects SET hidden_at = json_extract(?3, '$."' || name || '".hidden_at'),
             hide_by = json_extract(?3, '$."' || name || '".hide_by'), marker = json_extract(?3, '$."' || name || '".marker')
           WHERE account_id = ?1 AND hide_by = ?2 AND name IN ${list}`,
        )
        .bind(accountId, by, rows, ...chunk),
    ),
  );
}

/**
 * The statements, for the batch that commits a replacement, that check `by` still holds every row of
 * `names` it claimed (failing the batch on 'taken' otherwise, so a row another request took over is
 * never marked shown under it) and mark them shown, apart from `live`, those it took from a request
 * that may still add a marker (`mayStillMark`): they stay hidden by `by`, for a later show to list.
 */
export function owned(db, accountId, by, names, live) {
  const kept = JSON.stringify(live);
  return namesBound(names, 4).flatMap(({ list, names: chunk }) => [
    db
      .prepare(
        `SELECT json(CASE WHEN (SELECT count(*) FROM sync_objects
           WHERE account_id = ?1 AND name IN ${list} AND hide_by = ?2) = ${chunk.length} THEN '1' ELSE 'taken' END)`,
      )
      .bind(accountId, by, kept, ...chunk),
    db
      .prepare(
        `UPDATE sync_objects SET hidden_at = NULL, hide_by = NULL, marker = NULL, hidden_since = NULL
         WHERE account_id = ?1 AND name IN ${list} AND hide_by = ?2 AND name NOT IN (SELECT value FROM json_each(?3))`,
      )
      .bind(accountId, by, kept, ...chunk),
  ]);
}

/**
 * After a replacement's commit rolled back, or it refused past the boundary: marks shown the rows of
 * `names` that `by` claimed, still holds and nothing references, for the caller to hide again. A row
 * gone at `bound` (`goneBy`) stays HIDING by `by`, its `hidden_since` kept, so a hide once it is
 * abandoned does not make it look freshly hidden.
 */
export async function clearUnreferenced(db, accountId, by, names, bound) {
  await allOf(
    db,
    namesBound(names, 4).map(({ list, names: chunk }) =>
      db
        .prepare(
          `UPDATE sync_objects SET hidden_at = NULL, hide_by = NULL, marker = NULL, hidden_since = NULL
           WHERE account_id = ?1 AND name IN ${list} AND hide_by = ?2 AND ref_count = 0 AND hidden_since > ?3`,
        )
        .bind(accountId, by, bound, ...chunk),
    ),
  );
}

/**
 * The statements that mark shown the rows `rows` (`{name, marker}`) whose marker a show deleted, each
 * only while the row still holds that marker and is inside `bound` (`goneBy`). A marker's version id
 * names one version in the bucket, so matching names and markers apart matches each pair.
 */
function markShown(db, accountId, rows, bound) {
  const markers = JSON.stringify(rows.map((r) => r.marker));
  return namesBound(rows.map((r) => r.name), 4).map(({ list, names: chunk }) =>
    db
      .prepare(
        `UPDATE sync_objects SET hidden_at = NULL, hide_by = NULL, marker = NULL, hidden_since = NULL
         WHERE account_id = ?1 AND name IN ${list} AND marker IN (SELECT value FROM json_each(?2)) AND hidden_since > ?3`,
      )
      .bind(accountId, markers, bound, ...chunk),
  );
}

/**
 * After a replacement commits: shows the names among `names` it references whose marker a hide
 * recorded after the replacement's look, in at most `deleteBatches(names.length)` B2 requests. A hide
 * that has not recorded its marker by the commit records none: its (c) finds the name referenced and
 * gives the marker back itself.
 *
 * It reads the account's rows referenced and hidden (TO_SHOW) through their index alone and keeps those
 * among `names`: the replacement's names reach no statement, and the rows read follow what is hidden and
 * referenced, none at all in a sync no request was cut off from.
 */
export async function showReferenced(db, bucket, accountId, names) {
  const rows = await d1(() =>
    db
      .prepare(
        `${named(STATEMENT.SHOW_REFERENCED)} SELECT name, marker FROM sync_objects INDEXED BY sync_objects_to_show
         WHERE account_id = ?1 AND ${TO_SHOW} AND marker IS NOT NULL`,
      )
      .bind(accountId)
      .all(),
  );
  const wanted = new Set(names);
  const undone = rows.results.filter((r) => wanted.has(r.name));
  if (undone.length === 0) return;
  await show(bucket, undone.map((r) => ({ key: objectKey(accountId, r.name), versionId: r.marker })));
  // Each only if the row still holds that marker: a newer hide keeps it hidden for the next look. One
  // past the boundary stays hidden, gone.
  await allOf(db, markShown(db, accountId, undone, goneNow(bucket)));
}

/**
 * The names of account `accountId` (every account when null) whose hide is still to do: those stored
 * and unreferenced SYNC_ABANDONED_AFTER ago or before, whose hide no request began (a put's, or a
 * cut-off replacement's), and the abandoned HIDING ones. At most SYNC_LEFTOVER_HIDES, by account.
 */
async function leftovers(db, accountId, at) {
  const account = accountId === null ? "" : "account_id = ?1 AND ";
  const rows = await d1(() =>
    db
      .prepare(
        `SELECT account_id, name FROM (
           SELECT account_id, name FROM sync_objects INDEXED BY sync_objects_to_hide WHERE ${account}${TO_HIDE} AND stored_at <= ?2
           UNION ALL
           SELECT account_id, name FROM sync_objects INDEXED BY sync_objects_hiding WHERE ${account}${HIDING} AND hidden_at <= ?2
         ) ORDER BY account_id LIMIT ?3`,
      )
      .bind(accountId, abandonedBy(at), limits.SYNC_LEFTOVER_HIDES)
      .all(),
  );
  return byAccount(rows.results);
}

/** Rows `{account_id, name}` as account id → names, in their order. */
function byAccount(rows) {
  const out = new Map();
  for (const { account_id: id, name } of rows) out.set(id, [...(out.get(id) ?? []), name]);
  return out;
}

/** Settles leftovers `names` of `accountId`, if `bucket` has the B2 requests left for them. */
async function hideLeft(db, bucket, accountId, names, at) {
  if (bucket.sent + hideRequests(names.length) > limits.B2_REQUESTS_PER_INVOCATION) return false;
  await settle(db, bucket, accountId, names, at, { abandoned: true });
  return true;
}

/**
 * The rows `{account_id, name, marker}` of account `accountId` (every account when null) referenced
 * and left hidden by a request now abandoned (TO_SHOW), apart from the gone ones, which nothing shows.
 * At most SYNC_LEFTOVER_SHOWS, by account, and by name within an account.
 */
async function unshown(db, accountId, at) {
  const account = accountId === null ? "" : "account_id = ?1 AND ";
  const rows = await d1(() =>
    db
      .prepare(
        `SELECT account_id, name, marker FROM sync_objects INDEXED BY sync_objects_to_show
         WHERE ${account}${TO_SHOW} AND hidden_at <= ?2 AND hidden_since > ?4
         ORDER BY account_id, name LIMIT ?3`,
      )
      .bind(accountId, abandonedBy(at), limits.SYNC_LEFTOVER_SHOWS, goneBy(at))
      .all(),
  );
  const out = new Map();
  for (const row of rows.results) out.set(row.account_id, [...(out.get(row.account_id) ?? []), row]);
  return out;
}

/**
 * The versions B2 lists over `names` of `accountId` (sorted) that `keep(entry, name)` keeps (an entry of
 * `Bucket.listVersions`), read from the account's ListObjectVersions pages rather than a listing per
 * name: each page begins at the first name not yet listed, or goes on inside it when the page before
 * ended in it, and one page lists every name it passes. So a page lists one name at least, unless that
 * name alone holds more versions than a page. It reads pages while `bucket` keeps room for one more and
 * for `after(n)` B2 requests, n the versions kept, a page's worth more included. Returns `{targets,
 * listed}`: the versions kept as DeleteObjects targets, and the names whose every version it read.
 */
async function listVersionsOf(bucket, accountId, names, keep, after) {
  const prefix = accountPrefix(accountId);
  const wanted = new Set(names);
  const targets = [];
  const listed = new Set();
  let i = 0;
  let from = null;
  const room = () => bucket.sent + 1 + after(targets.length + DELETE_OBJECTS_MAX) <= limits.B2_REQUESTS_PER_INVOCATION;
  while (i < names.length && room()) {
    // A key-marker of the name less its last digit sorts before the name and after every shorter key.
    const page = await bucket.listVersions(prefix, from ?? { keyMarker: prefix + names[i].slice(0, -1), versionIdMarker: null });
    for (const e of page.entries) {
      const name = e.key.slice(prefix.length);
      if (wanted.has(name) && !listed.has(name) && keep(e, name)) targets.push({ key: e.key, versionId: e.versionId });
    }
    // Every key before the page's last has all its versions on the page; the last one may go on, and
    // only a name not listed yet is worth going on in: past any other key, the next page jumps.
    const end = page.next?.keyMarker ?? null;
    while (i < names.length && (end === null || prefix + names[i] < end)) listed.add(names[i++]);
    from = i < names.length && end === prefix + names[i] ? page.next : null;
  }
  return { targets, listed };
}

/**
 * Shows, of leftovers `rows` (`{name, marker}`, by name) of `accountId`, as many as `bucket` has the B2
 * requests left for, and returns whether it took on all of them. A row past the boundary by the time
 * B2 answered stays hidden, gone.
 *
 * A row with a recorded marker is shown the way `showReferenced` shows it, unclaimed: no request adds
 * a marker over a name whose row records one, and a request that takes the row over clears the
 * marker, so the row is marked shown only while it still records the deleted one. A row whose marker
 * B2 failed to delete has its marker cleared instead, for a listing to find what hides it, and so does
 * one past the boundary, for a hide to take over once nothing references it.
 *
 * A row with none is taken over (`claimHidden`): B2 may hold markers over it that no row names, from
 * a hide or a show cut off, so it lists them all (`markersOf`), deletes them, and marks shown the
 * rows it still holds. A row it did not list is given back; one whose markers B2 failed to delete
 * stays held, for a later show once abandoned.
 */
async function showLeft(db, bucket, accountId, rows, at) {
  if (bucket.sent >= limits.B2_REQUESTS_PER_INVOCATION) return false;
  const recorded = rows.filter((r) => r.marker !== null);
  if (bucket.sent + deleteBatches(recorded.length) > limits.B2_REQUESTS_PER_INVOCATION) return false;
  const by = crypto.randomUUID();
  const undone = await claimHidden(db, accountId, rows.filter((r) => r.marker === null).map((r) => r.name), by, at, { abandoned: true });
  // A row taken over has every marker over it listed, whatever it records by then.
  const { targets, listed } = await markersOf(bucket, accountId, [...recorded, ...undone.map((r) => ({ name: r.name, marker: null }))], deleteBatches);
  const unlisted = undone.filter((r) => !listed.has(r.name));
  await releaseClaim(db, accountId, by, unlisted);
  const failed = await deleteVersions(bucket, targets);
  const ok = (name) => !failed.has(objectKey(accountId, name));
  const shown = recorded.filter((r) => ok(r.name));
  const bound = goneNow(bucket);
  const recordedMarkers = JSON.stringify(recorded.map((r) => r.marker));
  await allOf(db, [
    ...markShown(db, accountId, shown, bound),
    // The rows the statements before left: B2 failed them, or they are gone.
    ...namesBound(recorded.map((r) => r.name), 3).map(({ list, names: chunk }) =>
      db
        .prepare(`UPDATE sync_objects SET marker = NULL WHERE account_id = ?1 AND name IN ${list} AND marker IN (SELECT value FROM json_each(?2))`)
        .bind(accountId, recordedMarkers, ...chunk),
    ),
    ...namesBound([...listed].filter(ok), 4).map(({ list, names: chunk }) =>
      db
        .prepare(
          `UPDATE sync_objects SET hidden_at = NULL, hide_by = NULL, marker = NULL, hidden_since = NULL
           WHERE account_id = ?1 AND hide_by = ?2 AND name IN ${list} AND hidden_since > ?3`,
        )
        .bind(accountId, by, bound, ...chunk),
    ),
  ]);
  return unlisted.length === 0;
}

/**
 * After a sync write of account `accountId` did its own work: shows up to SYNC_LEFTOVER_SHOWS of what
 * cut-off requests of the account left referenced and hidden, then hides up to SYNC_LEFTOVER_HIDES of
 * the hides still to do, then takes up to SYNC_LEFTOVER_WRITES of the writes requests left unrecorded,
 * with the B2 requests `bucket` has left. A failure here leaves them for the next write or the hourly
 * run, and fails nothing the write did.
 */
export async function tidyLeftoversOf(db, bucket, accountId, at) {
  try {
    const shows = (await unshown(db, accountId, at)).get(accountId);
    if (shows !== undefined) await showLeft(db, bucket, accountId, shows, at);
    if (bucket.sent + hideRequests(1) <= limits.B2_REQUESTS_PER_INVOCATION) {
      const names = (await leftovers(db, accountId, at)).get(accountId);
      if (names !== undefined) await hideLeft(db, bucket, accountId, names, at);
    }
    const writes = (await unwritten(db, accountId, at)).get(accountId);
    if (writes !== undefined) await writeLeft(db, bucket, accountId, writes, at);
  } catch (error) {
    if (!(error instanceof Unavailable || error instanceof StorageFailed)) throw error;
  }
}

/**
 * The hourly run's shows: up to SYNC_LEFTOVER_SHOWS of what cut-off requests left referenced and
 * hidden, of every account, account by account while `bucket` has the B2 requests left. What it does
 * not reach stays recorded for the next run.
 */
export async function showLeftovers(db, bucket, at) {
  for (const [accountId, names] of await unshown(db, null, at)) {
    if (!(await showLeft(db, bucket, accountId, names, at))) break;
  }
}

/**
 * The hourly run's hides: up to SYNC_LEFTOVER_HIDES hides cut-off requests left, of every account,
 * account by account while `bucket` has the B2 requests left for the next one. What it does not reach
 * stays recorded for the next run.
 */
export async function hideLeftovers(db, bucket, at) {
  for (const [accountId, names] of await leftovers(db, null, at)) {
    if (!(await hideLeft(db, bucket, accountId, names, at))) break;
  }
}

/**
 * The names of account `accountId` (every account when null) whose writes requests left unrecorded and
 * are taken at clock `at` (`unwrittenBy`), as `{name, written_at, held}`: `written_at` the latest
 * record's, `held` whether the account holds the name and is not being deleted. A name a record newer
 * than that also names is left for later: its request may still be writing. At most
 * SYNC_LEFTOVER_WRITES, by account, and by name within an account.
 */
async function unwritten(db, accountId, at) {
  const account = accountId === null ? "" : "WHERE w.account_id = ?1";
  const rows = await d1(() =>
    db
      .prepare(
        `SELECT w.account_id, j.value AS name, max(w.written_at) AS written_at,
           EXISTS (SELECT 1 FROM accounts a WHERE a.id = w.account_id AND a.deleting_since IS NULL)
             AND EXISTS (SELECT 1 FROM sync_objects o WHERE o.account_id = w.account_id AND o.name = j.value AND ${HELD("?4", "o")}) AS held
         FROM sync_writes w CROSS JOIN json_each(w.names) j ${account}
         GROUP BY w.account_id, j.value HAVING max(w.written_at) <= ?2
         ORDER BY w.account_id, j.value LIMIT ?3`,
      )
      .bind(accountId, unwrittenBy(at), limits.SYNC_LEFTOVER_WRITES, goneBy(at))
      .all(),
  );
  const out = new Map();
  for (const row of rows.results) out.set(row.account_id, [...(out.get(row.account_id) ?? []), row]);
  return out;
}

/**
 * The statements that make HIDING, by a request id of their own and with no marker recorded, the rows
 * of `names` of `accountId` an abandoned write may have put a version over that are hidden and
 * referenced by nothing, unless a request may still add a marker over them (`mayStillMark` at `at`):
 * B2 may show that version over their marker. Their `hidden_at` and `hidden_since` stay, so the account's next
 * write or the hourly run hides them again once abandoned (`leftovers`), and the boundary does not move.
 * A request that may still mark adds its marker after the abandoned write's version.
 */
function rehidden(db, accountId, names, at) {
  const by = crypto.randomUUID();
  return namesBound(names, 4).map(({ list, names: chunk }) =>
    db
      .prepare(
        `UPDATE sync_objects SET hide_by = ?2, marker = NULL
         WHERE account_id = ?1 AND name IN ${list} AND ref_count = 0 AND hidden_at IS NOT NULL
           AND (hide_by IS NULL OR marker IS NOT NULL OR hidden_at <= ?3)`,
      )
      .bind(accountId, by, abandonedBy(at), ...chunk),
  );
}

/**
 * Takes the writes `rows` (from `unwritten`) of `accountId` left unrecorded, as far as `bucket` has the
 * B2 requests left, and returns whether it took on all of them. A name the account holds is accounted
 * for by its row, once the row says what B2 may show (`rehidden`): its records are cleared in the same
 * batch. Of any other name, it deletes the versions its requests may have written (`writtenBy`, by B2's
 * LastModified), listed by the account's pages (`listVersionsOf`), and clears the records of each name
 * whose every version it listed and B2 failed none of. A version written later is a request's still
 * running, which records its own write.
 */
async function writeLeft(db, bucket, accountId, rows, at) {
  const held = rows.filter((r) => r.held).map((r) => r.name);
  const unheld = rows.filter((r) => !r.held);
  const bound = new Map(unheld.map((r) => [r.name, writtenBy(r.written_at)]));
  const names = unheld.map((r) => r.name).sort();
  const { targets, listed } = await listVersionsOf(bucket, accountId, names, (e, name) => e.modified <= bound.get(name), deleteBatches);
  const failed = await deleteVersions(bucket, targets);
  const done = [...held, ...[...listed].filter((n) => !failed.has(objectKey(accountId, n)))];
  if (done.length > 0) {
    // Takes the names off the rows it read them from, and deletes a row left naming none.
    await d1(() =>
      db.batch([
        ...rehidden(db, accountId, held, at),
        db
          .prepare(
            `UPDATE sync_writes SET names = (SELECT json_group_array(value) FROM json_each(sync_writes.names)
               WHERE value NOT IN (SELECT value FROM json_each(?3)))
             WHERE account_id = ?1 AND written_at <= ?2`,
          )
          .bind(accountId, unwrittenBy(at), distinctJson(done)),
        db.prepare("DELETE FROM sync_writes WHERE account_id = ?1 AND written_at <= ?2 AND names = '[]'").bind(accountId, unwrittenBy(at)),
      ]),
    );
  }
  return listed.size === names.length;
}

/**
 * The hourly run's writes: up to SYNC_LEFTOVER_WRITES names whose writes requests left unrecorded, of
 * every account, existing or not, account by account while `bucket` has the B2 requests left. What it
 * does not reach stays recorded for the next run.
 */
export async function writeLeftovers(db, bucket, at) {
  for (const [accountId, rows] of await unwritten(db, null, at)) {
    if (!(await writeLeft(db, bucket, accountId, rows, at))) break;
  }
}

/**
 * The condition of a row hidden, referenced by nothing and hidden by no request still adding a marker
 * over it: what sync_objects_gone indexes, less the HIDING rows, which a hide has yet to take again.
 */
const HIDDEN_DONE = "ref_count = 0 AND hidden_since IS NOT NULL AND (marker IS NOT NULL OR hide_by IS NULL)";

/**
 * The `hidden_since` before which a HIDDEN_DONE row is deleted at clock `at`: the start of the UTC day
 * of the boundary (`goneBy`) at `at` less SYNC_ABANDONED_AFTER. Every request not abandoned began after
 * that, so it read the row as gone, as it reads no row (none of them can have read it as held), and
 * `usage` (sync_quota.mjs) reads hidden bytes from that day on, so taking the row's bytes off an
 * earlier day changes no count it reads.
 */
export const forgetBy = (at) => Math.floor((goneBy(at) - limits.SYNC_ABANDONED_AFTER) / 86_400) * 86_400;

/**
 * The hourly run's deletion of the rows of names gone and referenced by nothing (HIDDEN_DONE, before
 * `forgetBy`), of every account, up to SYNC_FORGETS_PER_RUN, SYNC_FORGETS_PER_STATEMENT a statement.
 * B2's lifecycle deletes their versions, and a gone name answers as one never put, so nothing reads
 * them. The usage triggers take their bytes off the days they were counted on. What it does not reach
 * waits for the next run.
 */
export async function forgetLeftovers(db, at) {
  for (let left = limits.SYNC_FORGETS_PER_RUN; left > 0; left -= limits.SYNC_FORGETS_PER_STATEMENT) {
    const limit = Math.min(left, limits.SYNC_FORGETS_PER_STATEMENT);
    const result = await d1(() =>
      db
        .prepare(
          `DELETE FROM sync_objects WHERE (account_id, name) IN (
             SELECT account_id, name FROM sync_objects INDEXED BY sync_objects_gone WHERE ${HIDDEN_DONE} AND hidden_since < ?1 LIMIT ?2)`,
        )
        .bind(forgetBy(at), limit)
        .run(),
    );
    if (result.meta.changes < limit) return;
  }
}
