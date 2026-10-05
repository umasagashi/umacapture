// Every D1 query the Worker makes. Payloads are stored gzip-compressed (D1 does not compress).
//
// Each write that commits anything is one `batch()`, which D1 runs as one transaction: an error in
// any statement rolls the whole batch back. A conditional statement whose condition fails changes
// 0 rows without an error, so the first statement of a batch carries every condition and the later
// statements apply only if the row the first one inserted exists. "That row exists" has to mean
// "this batch inserted it": each batch says below how a row from before cannot pass for its own.
// The outcome is then read from the first statement's `meta.changes` (the deciding statement's, for
// a withdrawal), never inferred from how far the code got.

/** D1 answered with an error (overload, daily quota): nothing was committed and a retry is safe. */
export class Unavailable extends Error {}

const CONSTRAINTS = [
  ["duplicateKey", /UNIQUE constraint failed: records\.delete_key_hash\b/],
  ["idCollision", /UNIQUE constraint failed: records\.id\b/],
  ["duplicateTicket", /UNIQUE constraint failed: tickets\.hash\b/],
];

/** The constraint a failed batch broke, or throws Unavailable for any other error. */
function brokenConstraint(error) {
  const message = String(error?.message ?? "");
  for (const [name, pattern] of CONSTRAINTS) if (pattern.test(message)) return name;
  throw new Unavailable("D1 refused the query", { cause: error });
}

async function query(op) {
  try {
    return await op();
  } catch (error) {
    throw new Unavailable("D1 refused the query", { cause: error });
  }
}

/** The posted form and publish day of record `id`, or null when no such row exists. */
export async function readRecord(db, id) {
  const row = await db
    .prepare("SELECT schema, payload, published_day FROM records WHERE id = ?")
    .bind(id)
    .first();
  if (row === null) return null;
  if (row.schema !== 1) throw new Error(`record ${id} has posted-form schema ${row.schema}`);
  const stream = new Blob([new Uint8Array(row.payload)]).stream().pipeThrough(new DecompressionStream("gzip"));
  return { form: await new Response(stream).json(), publishedDay: row.published_day };
}

/** The public id stored under delete key hash `keyHash`, or null. */
export async function findIdByKeyHash(db, keyHash) {
  const row = await query(() => db.prepare("SELECT id FROM records WHERE delete_key_hash = ?").bind(keyHash).first());
  return row === null ? null : row.id;
}

/**
 * Publishes one record (the batch of the design's publish step 4) and judges the outcome.
 *
 * `p`: `{id, keyHash, payload, charge, ticketHash, day, now, budget, dailyLimit}`.
 * Returns `{status: "created"}`, `{status: "existing", id}` (the same key committed first),
 * `{status: "refused", reason: "ticket" | "storage" | "daily" | "changed"}` or
 * `{status: "idCollision"}`. Throws Unavailable when D1 fails.
 */
export async function publishRecord(db, p) {
  const exists = "EXISTS (SELECT 1 FROM records WHERE id = ?2)";
  const statements = [
    // A row already holding this id makes the insert run and break the primary key even when a
    // condition fails, so a refused publish can never find that row and commit statements 2 to 4.
    db
      .prepare(
        `INSERT INTO records (id, delete_key_hash, schema, payload, charge, published_day)
         SELECT ?1, ?2, 1, ?3, ?4, ?5
         WHERE EXISTS (SELECT 1 FROM records WHERE id = ?1)
            OR ((SELECT remaining FROM tickets WHERE hash = ?6 AND expires_at > ?7) > 0
                AND (SELECT bytes FROM totals WHERE id = 1) + ?4 <= ?8
                AND COALESCE((SELECT publish_bytes FROM daily WHERE day = ?5), 0) + ?4 <= ?9)`,
      )
      .bind(p.id, p.keyHash, p.payload, p.charge, p.day, p.ticketHash, p.now, p.budget, p.dailyLimit),
    db.prepare(`UPDATE tickets SET remaining = remaining - 1 WHERE hash = ?1 AND ${exists}`).bind(p.ticketHash, p.id),
    db
      .prepare(`UPDATE totals SET bytes = bytes + ?1, count = count + 1 WHERE id = 1 AND ${exists}`)
      .bind(p.charge, p.id),
    db
      .prepare(
        `INSERT INTO daily (day, publish_bytes, publish_count)
         SELECT ?1, ?3, 1 WHERE ${exists}
         ON CONFLICT (day) DO UPDATE SET publish_bytes = publish_bytes + excluded.publish_bytes,
                                         publish_count = publish_count + 1`,
      )
      .bind(p.day, p.id, p.charge),
  ];

  let results;
  try {
    results = await db.batch(statements);
  } catch (error) {
    // Rolled back: this request consumed nothing.
    const broken = brokenConstraint(error);
    if (broken === "idCollision") return { status: "idCollision" };
    if (broken === "duplicateKey") return existingOrUnavailable(db, p.keyHash);
    throw new Unavailable("unexpected constraint", { cause: error });
  }
  if (results[0].meta.changes === 1) return { status: "created" };

  // Nothing changed. A request with the same key may have committed after this one looked for it
  // and used the ticket's last publish or the last of the budget, so the condition failed here
  // before the unique constraint could: look for the key again before refusing.
  const id = await findIdByKeyHash(db, p.keyHash);
  if (id !== null) return { status: "existing", id };
  return { status: "refused", reason: await refusalReason(db, p) };
}

async function existingOrUnavailable(db, keyHash) {
  const id = await findIdByKeyHash(db, keyHash);
  if (id === null) throw new Unavailable("the key that broke the constraint is gone");
  return { status: "existing", id };
}

/**
 * Why a publish was refused, read after the refusal. Other requests may have changed the state in
 * between; the refusal itself was decided atomically, and "changed" reports that none of the
 * conditions fails any more.
 */
async function refusalReason(db, p) {
  const row = await query(() =>
    db
      .prepare(
        `SELECT (SELECT remaining FROM tickets WHERE hash = ?1 AND expires_at > ?2) AS remaining,
                (SELECT bytes FROM totals WHERE id = 1) AS bytes,
                COALESCE((SELECT publish_bytes FROM daily WHERE day = ?3), 0) AS published`,
      )
      .bind(p.ticketHash, p.now, p.day)
      .first(),
  );
  if (row.remaining === null || row.remaining <= 0) return "ticket";
  if (row.bytes + p.charge > p.budget) return "storage";
  if (row.published + p.charge > p.dailyLimit) return "daily";
  return "changed";
}

/**
 * Registers ticket hash `hash` (the batch of the design's ticket step 2).
 *
 * `t`: `{hash, uses, expiresAt, day, limit}`. Returns "issued", "limit" (the day's tickets are
 * used up) or "alreadyIssued" (the same hash was registered before). Throws Unavailable.
 */
export async function issueTicket(db, t) {
  const statements = [
    db
      .prepare(
        `INSERT INTO tickets (hash, remaining, expires_at)
         SELECT ?1, ?2, ?3 WHERE COALESCE((SELECT tickets FROM daily WHERE day = ?4), 0) < ?5`,
      )
      .bind(t.hash, t.uses, t.expiresAt, t.day, t.limit),
    // Counts only the row this batch inserted: an older row with the same hash would have broken
    // the primary key above, and one left from before does not carry this expiry.
    db
      .prepare(
        `INSERT INTO daily (day, tickets)
         SELECT ?1, 1 WHERE EXISTS (SELECT 1 FROM tickets WHERE hash = ?2 AND expires_at = ?3)
         ON CONFLICT (day) DO UPDATE SET tickets = tickets + 1`,
      )
      .bind(t.day, t.hash, t.expiresAt),
  ];
  try {
    const results = await db.batch(statements);
    return results[0].meta.changes === 1 ? "issued" : "limit";
  } catch (error) {
    if (brokenConstraint(error) === "duplicateTicket") return "alreadyIssued";
    throw new Unavailable("unexpected constraint", { cause: error });
  }
}

/** Removes up to `limit` expired tickets, through the expires_at index. */
export async function sweepTickets(db, now, limit) {
  await db
    .prepare("DELETE FROM tickets WHERE hash IN (SELECT hash FROM tickets WHERE expires_at < ?1 LIMIT ?2)")
    .bind(now, limit)
    .run();
}

/**
 * Withdraws record `id` if `keyHash` is its delete key hash, giving its charge back to the totals
 * in the same transaction. Returns "withdrawn", "forbidden" (the row exists under another key) or
 * "notFound" (no such row, including one a concurrent withdrawal removed). Throws Unavailable.
 */
export async function withdrawRecord(db, id, keyHash) {
  const match = "id = ?1 AND delete_key_hash = ?2";
  const statements = [
    db
      .prepare(
        `UPDATE totals SET bytes = bytes - (SELECT charge FROM records WHERE ${match}), count = count - 1
         WHERE id = 1 AND EXISTS (SELECT 1 FROM records WHERE ${match})`,
      )
      .bind(id, keyHash),
    db.prepare(`DELETE FROM records WHERE ${match}`).bind(id, keyHash),
  ];
  const results = await query(() => db.batch(statements));
  if (results[1].meta.changes === 1) return "withdrawn";
  const row = await query(() => db.prepare("SELECT 1 AS found FROM records WHERE id = ?").bind(id).first());
  return row === null ? "notFound" : "forbidden";
}
