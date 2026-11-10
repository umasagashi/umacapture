// Every D1 query the Worker makes. Payloads are stored gzip-compressed (D1 does not compress).
//
// Each write that commits anything is one `batch()`, which D1 runs as one transaction: an error in
// any statement rolls the whole batch back. A conditional statement whose condition fails changes
// 0 rows without an error, so the first statement of a batch carries every condition and the later
// statements apply only if the row the first one inserted exists. "That row exists" has to mean
// "this batch inserted it": each batch says below how a row from before cannot pass for its own.
// The outcome is then read from the first statement's `meta.changes` (the deciding statement's, for
// an unshare), never inferred from how far the code got.

/** D1 answered with an error (overload, daily quota): nothing was committed and a retry is safe. */
export class Unavailable extends Error {}

const CONSTRAINTS = [
  ["duplicateKey", /UNIQUE constraint failed: records\.client_key\b/],
  ["idCollision", /UNIQUE constraint failed: records\.id\b/],
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

const gunzipJson = (payload) =>
  new Response(new Blob([new Uint8Array(payload)]).stream().pipeThrough(new DecompressionStream("gzip"))).json();

/**
 * The state of the images of a share whose row is `row` (with `images_name` and `images_stored_at`):
 * "none" (it declares none, which it never does later), "pending" (declared, the bundle not stored
 * yet) or "stored".
 */
export const imageState = (row) => (row.images_name === null ? "none" : row.images_stored_at === null ? "pending" : "stored");

/**
 * The declaration of a share's images from its row, `{name, size, parts, state}` (`imageState`), or
 * null for a share that declares none.
 */
const declaredImages = (row) =>
  row.images_name === null
    ? null
    : { name: row.images_name, size: row.images_size, parts: JSON.parse(row.images), state: imageState(row) };

/**
 * The posted form, share day, owner and declared images (`declaredImages`) of record `id`, or null when
 * no such row exists.
 */
export async function readRecord(db, id) {
  const row = await db
    .prepare("SELECT schema, payload, shared_day, owner_id, images, images_name, images_size, images_stored_at FROM records WHERE id = ?")
    .bind(id)
    .first();
  if (row === null) return null;
  if (row.schema !== 1) throw new Error(`record ${id} has posted-form schema ${row.schema}`);
  return { form: await gunzipJson(row.payload), sharedDay: row.shared_day, owner: row.owner_id, images: declaredImages(row) };
}

/**
 * The owner and declared images (`declaredImages`) of share `id`, `{owner, images}`, or null when no such
 * row exists: what the bundle's endpoints read, without the posted form. Throws Unavailable.
 */
export async function readShareImages(db, id) {
  const row = await query(() =>
    db.prepare("SELECT owner_id, images, images_name, images_size, images_stored_at FROM records WHERE id = ?1").bind(id).first(),
  );
  return row === null ? null : { owner: row.owner_id, images: declaredImages(row) };
}

/**
 * Account `id` as `GET /api/me` reads it: `{shareCount, deleting, trainerIds}`, or null when no such
 * account exists. Throws Unavailable.
 */
export async function readAccount(db, id) {
  const [account, trainers] = await query(() =>
    db.batch([
      db.prepare("SELECT share_count, deleting_since FROM accounts WHERE id = ?1").bind(id),
      db.prepare("SELECT trainer_id FROM account_trainers WHERE account_id = ?1 ORDER BY trainer_id").bind(id),
    ]),
  );
  const row = account.results[0];
  if (row === undefined) return null;
  return {
    shareCount: row.share_count,
    deleting: row.deleting_since !== null,
    trainerIds: trainers.results.map((t) => t.trainer_id),
  };
}

/** Whether account `id` exists. Throws Unavailable. */
export async function accountExists(db, id) {
  return (await query(() => db.prepare("SELECT 1 AS found FROM accounts WHERE id = ?1").bind(id).first())) !== null;
}

/**
 * Registers trainer `trainerId` under account `owner`, while the account holds fewer than `cap` of
 * them and is not being deleted; one already registered is left as it is. The cap is judged inside
 * the insert, so racing registrations cannot pass it together. Returns "deleting" (the account is
 * being deleted, judged before anything else), "gone" (no such account), "registered" (the trainer
 * is registered now, whether by this request or before) or "limit". Throws Unavailable.
 */
export async function registerTrainer(db, owner, trainerId, cap) {
  const results = await query(() =>
    db.batch([
      db
        .prepare(
          `INSERT INTO account_trainers (account_id, trainer_id)
           SELECT ?1, ?2 WHERE (SELECT count(*) FROM account_trainers WHERE account_id = ?1) < ?3
             AND EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND deleting_since IS NULL)
           ON CONFLICT (account_id, trainer_id) DO NOTHING`,
        )
        .bind(owner, trainerId, cap),
      db.prepare("SELECT 1 FROM account_trainers WHERE account_id = ?1 AND trainer_id = ?2").bind(owner, trainerId),
      db.prepare("SELECT deleting_since FROM accounts WHERE id = ?1").bind(owner),
    ]),
  );
  const account = results[2].results[0];
  if (account === undefined) return "gone";
  if (account.deleting_since !== null) return "deleting";
  return results[1].results.length > 0 ? "registered" : "limit";
}

/**
 * `{id, images}` of the share stored under client key hash `clientKey`, `images` its `imageState`, or
 * null.
 */
export async function findByClientKey(db, clientKey) {
  const row = await query(() =>
    db.prepare("SELECT id, images_name, images_stored_at FROM records WHERE client_key = ?").bind(clientKey).first(),
  );
  return row === null ? null : { id: row.id, images: imageState(row) };
}

/** The charge account ?1 has shared on day ?3, read from its row. */
const ACCOUNT_SHARED_TODAY = "(SELECT CASE WHEN quota_day = ?3 THEN quota_bytes ELSE 0 END FROM accounts WHERE id = ?1)";

/** The image bytes account ?1 has declared on day ?3, read from its row: the same day as ACCOUNT_SHARED_TODAY's. */
const ACCOUNT_IMAGES_TODAY = "(SELECT CASE WHEN quota_day = ?3 THEN image_quota_bytes ELSE 0 END FROM accounts WHERE id = ?1)";

/**
 * Shares one record for account `owner` (one batch) and judges the outcome.
 *
 * `p`: `{id, owner, clientKey, payload, charge, day, budget, dailyLimit, accountCap, accountDailyLimit,
 * images, imageBudget, imageDailyLimit, accountImageDailyLimit}`. `images` is the share's declaration
 * `{name, size, parts}` (`parts` the JSON stored as it is), or null for a share without images: its
 * size is counted, once, against the image limits, which a share without images is never judged by.
 * Returns `{status: "created"}`, `{status: "existing", id, images}` (the same client key committed
 * first; `images` its `imageState`), `{status: "refused", reason: "gone" | "deleting" | "storage" |
 * "daily" | "account" | "imageStorage" | "imageDaily" | "imageAccount" | "changed"}` or
 * `{status: "idCollision"}`.
 * Throws Unavailable when D1 fails.
 */
export async function shareRecord(db, p) {
  const exists = "EXISTS (SELECT 1 FROM records WHERE id = ?2)";
  const images = p.images ?? { name: null, size: null, parts: null };
  const statements = [
    // A row already holding this id makes the insert run and break the primary key even when a
    // condition fails, so a refused share can never find that row and commit statements 2 to 4.
    db
      .prepare(
        `INSERT INTO records (id, owner_id, client_key, schema, payload, charge, shared_day, images, images_name, images_size)
         SELECT ?2, ?1, ?4, 1, ?5, ?6, ?3, ?11, ?12, ?13
         WHERE EXISTS (SELECT 1 FROM records WHERE id = ?2)
            OR (EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND deleting_since IS NULL)
                AND (SELECT bytes FROM totals WHERE id = 1) + ?6 <= ?7
                AND COALESCE((SELECT share_bytes FROM daily WHERE day = ?3), 0) + ?6 <= ?8
                AND (SELECT share_count FROM accounts WHERE id = ?1) < ?9
                AND ${ACCOUNT_SHARED_TODAY} + ?6 <= ?10
                AND (?13 IS NULL
                     OR ((SELECT image_bytes FROM totals WHERE id = 1) + ?13 <= ?14
                         AND COALESCE((SELECT image_bytes FROM daily WHERE day = ?3), 0) + ?13 <= ?15
                         AND ${ACCOUNT_IMAGES_TODAY} + ?13 <= ?16)))`,
      )
      .bind(
        p.owner,
        p.id,
        p.day,
        p.clientKey,
        p.payload,
        p.charge,
        p.budget,
        p.dailyLimit,
        p.accountCap,
        p.accountDailyLimit,
        images.parts,
        images.name,
        images.size,
        p.imageBudget,
        p.imageDailyLimit,
        p.accountImageDailyLimit,
      ),
    db
      .prepare(
        `UPDATE accounts SET share_count = share_count + 1,
           quota_bytes = CASE WHEN quota_day = ?3 THEN quota_bytes + ?4 ELSE ?4 END,
           image_quota_bytes = CASE WHEN quota_day = ?3 THEN image_quota_bytes + ?5 ELSE ?5 END, quota_day = ?3
         WHERE id = ?1 AND ${exists}`,
      )
      .bind(p.owner, p.id, p.day, p.charge, images.size ?? 0),
    db
      .prepare(`UPDATE totals SET bytes = bytes + ?1, count = count + 1, image_bytes = image_bytes + ?3 WHERE id = 1 AND ${exists}`)
      .bind(p.charge, p.id, images.size ?? 0),
    db
      .prepare(
        `INSERT INTO daily (day, share_bytes, share_count, image_bytes)
         SELECT ?1, ?3, 1, ?4 WHERE ${exists}
         ON CONFLICT (day) DO UPDATE SET share_bytes = share_bytes + excluded.share_bytes,
                                         share_count = share_count + 1,
                                         image_bytes = image_bytes + excluded.image_bytes`,
      )
      .bind(p.day, p.id, p.charge, images.size ?? 0),
  ];

  let results;
  try {
    results = await db.batch(statements);
  } catch (error) {
    // Rolled back: this request consumed nothing.
    const broken = brokenConstraint(error);
    if (broken === "idCollision") return { status: "idCollision" };
    if (broken === "duplicateKey") return existingOrUnavailable(db, p.clientKey);
    throw new Unavailable("unexpected constraint", { cause: error });
  }
  if (results[0].meta.changes === 1) return { status: "created" };

  // Nothing changed. A request with the same key may have committed after this one looked for it
  // and used the last of a limit, so the condition failed here before the unique constraint could:
  // look for the key again before refusing.
  const found = await findByClientKey(db, p.clientKey);
  if (found !== null) return { status: "existing", ...found };
  return { status: "refused", reason: await refusalReason(db, p) };
}

async function existingOrUnavailable(db, clientKey) {
  const found = await findByClientKey(db, clientKey);
  if (found === null) throw new Unavailable("the key that broke the constraint is gone");
  return { status: "existing", ...found };
}

/**
 * Why a share was refused, read after the refusal. Other requests may have changed the state in
 * between; the refusal itself was decided atomically, and "changed" reports that none of the
 * conditions fails any more. The account is judged first: "gone" (its deletion completed, so the
 * session that authorised the request is gone too) and "deleting" say nothing about any limit.
 */
async function refusalReason(db, p) {
  const row = await query(() =>
    db
      .prepare(
        `SELECT (SELECT bytes FROM totals WHERE id = 1) AS bytes,
                COALESCE((SELECT share_bytes FROM daily WHERE day = ?3), 0) AS shared,
                EXISTS (SELECT 1 FROM accounts WHERE id = ?1) AS account_exists,
                (SELECT deleting_since FROM accounts WHERE id = ?1) AS deleting_since,
                (SELECT share_count FROM accounts WHERE id = ?1) AS account_count,
                ${ACCOUNT_SHARED_TODAY} AS account_shared,
                (SELECT image_bytes FROM totals WHERE id = 1) AS image_bytes,
                COALESCE((SELECT image_bytes FROM daily WHERE day = ?3), 0) AS images_shared,
                ${ACCOUNT_IMAGES_TODAY} AS account_images`,
      )
      .bind(p.owner, null, p.day)
      .first(),
  );
  if (row.account_exists === 0) return "gone";
  if (row.deleting_since !== null) return "deleting";
  if (row.bytes + p.charge > p.budget) return "storage";
  if (row.shared + p.charge > p.dailyLimit) return "daily";
  if (row.account_count >= p.accountCap) return "account";
  if (row.account_shared + p.charge > p.accountDailyLimit) return "account";
  const size = p.images?.size;
  if (size != null && row.image_bytes + size > p.imageBudget) return "imageStorage";
  if (size != null && row.images_shared + size > p.imageDailyLimit) return "imageDaily";
  if (size != null && row.account_images + size > p.accountImageDailyLimit) return "imageAccount";
  return "changed";
}

/**
 * Records a begun login (the begin's batch) and counts it against the day's logins. A begin of an
 * `h` already present replaces that row only when the row has expired at `now`, or when `markHash`
 * (the SHA-256 of the request's `uc_begin_<h>`, or null) is the row's `begin_hash`: the later begin
 * then wins and the earlier state is void. That is the user who goes back from the provider's screen
 * to the start page and presses login again in the same browser. Another browser that learnt `h`
 * (and the Windows port) from the start URL holds no such mark, so it cannot take the row over and
 * complete it as itself. A completed row (stage 1) cannot be replaced while it lives, because its
 * callback removed the mark. The replacement counts as one login like any other begin.
 *
 * `l`: `{h, provider, stateHash, pkceVerifier, nonceHash, beginHash, port, expiresAt, day, limit,
 * now, markHash}`. Returns "begun", "taken" (a live row of `h` begun in another browser stays), or
 * "limit" (the day's logins are used up). Throws Unavailable.
 */
export async function beginLogin(db, l) {
  const statements = [
    db
      .prepare(
        `INSERT INTO logins (h, provider, state_hash, pkce_verifier, nonce_hash, begin_hash, port, stage, expires_at)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, ?8
         WHERE COALESCE((SELECT logins FROM daily WHERE day = ?9), 0) < ?10
         ON CONFLICT (h) DO UPDATE SET provider = excluded.provider, state_hash = excluded.state_hash,
           pkce_verifier = excluded.pkce_verifier, nonce_hash = excluded.nonce_hash,
           begin_hash = excluded.begin_hash, port = excluded.port, stage = 0, account_id = NULL,
           proof_hash = NULL, expires_at = excluded.expires_at
         WHERE logins.expires_at < ?11 OR logins.begin_hash = ?12`,
      )
      .bind(
        l.h,
        l.provider,
        l.stateHash,
        l.pkceVerifier,
        l.nonceHash,
        l.beginHash,
        l.port,
        l.expiresAt,
        l.day,
        l.limit,
        l.now,
        l.markHash,
      ),
    // Counts only the row this batch wrote: the state hash is this request's own random value, so
    // a row from before (including the one this batch replaced) cannot match it.
    db
      .prepare(
        `INSERT INTO daily (day, logins)
         SELECT ?1, 1 WHERE EXISTS (SELECT 1 FROM logins WHERE h = ?2 AND state_hash = ?3)
         ON CONFLICT (day) DO UPDATE SET logins = logins + 1`,
      )
      .bind(l.day, l.h, l.stateHash),
    // Read in the same batch, so whether another begin's row stood in the way is decided against the
    // row the insert met, not one a later request wrote.
    db.prepare("SELECT 1 FROM logins WHERE h = ?1 AND state_hash <> ?2").bind(l.h, l.stateHash),
  ];
  const results = await query(() => db.batch(statements));
  if (results[0].meta.changes === 1) return "begun";
  return results[2].results.length > 0 ? "taken" : "limit";
}

/**
 * The login a callback's state belongs to, while it can still be completed: `{h, provider,
 * pkce_verifier, nonce_hash, begin_hash, port}` of the stage-0 row whose state hash is `stateHash`
 * and which has not expired at `now`, or null. Throws Unavailable.
 */
export async function findStartedLogin(db, stateHash, now) {
  return query(() =>
    db
      .prepare(
        `SELECT h, provider, pkce_verifier, nonce_hash, begin_hash, port FROM logins
         WHERE state_hash = ?1 AND stage = 0 AND expires_at >= ?2`,
      )
      .bind(stateHash, now)
      .first(),
  );
}

/**
 * Completes a login (the callback's batch): finds the account of identity (`provider`,
 * `subjectHmac`), creating it under `newAccountId` when there is none and the day's account limit
 * allows, and moves the login to stage 1 with that account and `proofHash`.
 *
 * The login moves only while it is still the stage-0 row with `stateHash` and unexpired at `now`, so
 * a begin that replaced it, or a callback that completed it first, leaves it alone. It also moves
 * only while the account row exists, so a login cannot complete onto an account whose deletion
 * finished in between: the deletion's batch removes the identity and the account, and D1 runs the
 * two batches one after the other.
 *
 * `c`: `{h, stateHash, provider, subjectHmac, newAccountId, proofHash, now, day, limit}`. Returns
 * "completed", "limit" (no account and the day's new accounts are used up) or "gone" (the login can
 * no longer be completed). Throws Unavailable.
 */
export async function completeLogin(db, c) {
  const identity = "SELECT account_id FROM identities WHERE provider = ?1 AND subject_hmac = ?2";
  const statements = [
    db
      .prepare(
        `INSERT INTO accounts (id, created_day)
         SELECT ?3, ?4 WHERE NOT EXISTS (${identity})
           AND COALESCE((SELECT accounts_created FROM daily WHERE day = ?4), 0) < ?5`,
      )
      .bind(c.provider, c.subjectHmac, c.newAccountId, c.day, c.limit),
    // The account id is this request's own random value, so only the account inserted above matches.
    db
      .prepare(
        `INSERT INTO identities (provider, subject_hmac, account_id)
         SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ?3)`,
      )
      .bind(c.provider, c.subjectHmac, c.newAccountId),
    db
      .prepare(
        `INSERT INTO daily (day, accounts_created)
         SELECT ?1, 1 WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ?2)
         ON CONFLICT (day) DO UPDATE SET accounts_created = accounts_created + 1`,
      )
      .bind(c.day, c.newAccountId),
    db
      .prepare(
        `UPDATE logins SET stage = 1, account_id = (${identity}), proof_hash = ?5
         WHERE h = ?3 AND state_hash = ?4 AND stage = 0 AND expires_at >= ?6
           AND EXISTS (SELECT 1 FROM accounts WHERE id = (${identity}))`,
      )
      .bind(c.provider, c.subjectHmac, c.h, c.stateHash, c.proofHash, c.now),
  ];
  const results = await query(() => db.batch(statements));
  if (results[3].meta.changes === 1) return "completed";
  const found = await query(() => db.prepare(identity).bind(c.provider, c.subjectHmac).first());
  return found === null ? "limit" : "gone";
}

/** `{stage, port, proof_hash}` of login `h` unexpired at `now`, or null. Throws Unavailable. */
export async function findLogin(db, h, now) {
  return query(() =>
    db.prepare("SELECT stage, port, proof_hash FROM logins WHERE h = ?1 AND expires_at >= ?2").bind(h, now).first(),
  );
}

/**
 * Exchanges a completed login for a session (the claim's batch): a session row for the login's
 * account, and the login removed. Only the stage-1 row of `h` holding `proofHash`, unexpired at
 * `now`, is exchanged; the login is removed only once the session this batch inserted exists.
 *
 * The session is a full one expiring at `expiresAt`, or, when the account is being deleted, one that
 * can only continue the deletion (scope "delete") expiring at `deleteExpiresAt`: an account being
 * deleted is never given a full session again.
 *
 * `s`: `{h, proofHash, tokenHash, now, expiresAt, deleteExpiresAt}`. Returns `{accountId, scope,
 * expiresAt}` of the session, or null when the login was replaced, claimed or expired in between.
 * Throws Unavailable.
 */
export async function claimLogin(db, s) {
  const statements = [
    db
      .prepare(
        `INSERT INTO sessions (token_hash, account_id, expires_at, scope)
         SELECT ?3, logins.account_id,
                CASE WHEN accounts.deleting_since IS NULL THEN ?5 ELSE ?6 END,
                CASE WHEN accounts.deleting_since IS NULL THEN 'full' ELSE 'delete' END
         FROM logins JOIN accounts ON accounts.id = logins.account_id
         WHERE logins.h = ?1 AND logins.stage = 1 AND logins.proof_hash = ?2 AND logins.expires_at >= ?4`,
      )
      .bind(s.h, s.proofHash, s.tokenHash, s.now, s.expiresAt, s.deleteExpiresAt),
    db
      .prepare("DELETE FROM logins WHERE h = ?1 AND EXISTS (SELECT 1 FROM sessions WHERE token_hash = ?2)")
      .bind(s.h, s.tokenHash),
    db.prepare("SELECT account_id, scope, expires_at FROM sessions WHERE token_hash = ?1").bind(s.tokenHash),
  ];
  const results = await query(() => db.batch(statements));
  const row = results[2].results[0];
  return row === undefined ? null : { accountId: row.account_id, scope: row.scope, expiresAt: row.expires_at };
}

/** `{account_id, scope}` of the session `tokenHash` unexpired at `now`, or null. Throws Unavailable. */
export async function findSession(db, tokenHash, now) {
  return query(() =>
    db
      .prepare("SELECT account_id, scope FROM sessions WHERE token_hash = ?1 AND expires_at >= ?2")
      .bind(tokenHash, now)
      .first(),
  );
}

/** Removes session `tokenHash`. Throws Unavailable. */
export async function deleteSession(db, tokenHash) {
  await query(() => db.prepare("DELETE FROM sessions WHERE token_hash = ?1").bind(tokenHash).run());
}

/** Removes up to `limit` expired logins and up to `limit` expired sessions, through their expiry indexes. */
export async function sweepLogins(db, now, limit) {
  await db.batch([
    db.prepare("DELETE FROM logins WHERE h IN (SELECT h FROM logins WHERE expires_at < ?1 LIMIT ?2)").bind(now, limit),
    db
      .prepare("DELETE FROM sessions WHERE token_hash IN (SELECT token_hash FROM sessions WHERE expires_at < ?1 LIMIT ?2)")
      .bind(now, limit),
  ]);
}

/**
 * Unshares record `id` if account `owner` holds it, giving its charge and its declared image bytes back
 * to the totals and its place back to the account's cap in the same transaction, while the account is
 * not being deleted (its deletion removes its records itself, under the opposite condition:
 * `deleteShareChunk`). When the share declares images, the same transaction records in the write ledger
 * (space "s", for request `by` at clock `now`) that its bundle's versions are to go: from then on no row
 * accounts for them, and the record stays until they are deleted (`removeBundle` in share_images.mjs, or
 * the hourly run).
 * Returns `{status, images}`: status "unshared", "deleting" (the account is being deleted, or its
 * deletion completed), "forbidden" (another account holds it) or "notFound" (no such row, including one
 * a concurrent unshare removed), and `images` the bundle's name when it unshared a share declaring
 * images, else null. Throws Unavailable.
 */
export async function unshareRecord(db, id, owner, by, now) {
  const match = "id = ?1 AND owner_id = ?2 AND EXISTS (SELECT 1 FROM accounts WHERE id = ?2 AND deleting_since IS NULL)";
  const statements = [
    db
      .prepare(
        `UPDATE totals SET bytes = bytes - (SELECT charge FROM records WHERE ${match}), count = count - 1,
           image_bytes = image_bytes - (SELECT COALESCE(images_size, 0) FROM records WHERE ${match})
         WHERE id = 1 AND EXISTS (SELECT 1 FROM records WHERE ${match})`,
      )
      .bind(id, owner),
    db
      .prepare(`UPDATE accounts SET share_count = share_count - 1 WHERE id = ?2 AND EXISTS (SELECT 1 FROM records WHERE ${match})`)
      .bind(id, owner),
    db
      .prepare(
        `INSERT INTO sync_writes (account_id, write_by, names, written_at, space)
         SELECT ?2, ?3, json_array(id || '/' || images_name), ?4, 's' FROM records WHERE ${match} AND images_name IS NOT NULL`,
      )
      .bind(id, owner, by, now),
    db.prepare(`SELECT images_name FROM records WHERE ${match}`).bind(id, owner),
    db.prepare(`DELETE FROM records WHERE ${match}`).bind(id, owner),
  ];
  const results = await query(() => db.batch(statements));
  if (results[4].meta.changes === 1) return { status: "unshared", images: results[3].results[0]?.images_name ?? null };
  const row = await query(() =>
    db
      .prepare(
        `SELECT EXISTS (SELECT 1 FROM records WHERE id = ?1) AS found,
                EXISTS (SELECT 1 FROM accounts WHERE id = ?2 AND deleting_since IS NULL) AS writable`,
      )
      .bind(id, owner)
      .first(),
  );
  if (row.writable === 0) return { status: "deleting", images: null };
  return { status: row.found === 0 ? "notFound" : "forbidden", images: null };
}

/**
 * Begins deleting account `accountId` from its full session `tokenHash` (one batch): marks the
 * account as being deleted since `now`, removes every other session of it, and turns this one into a
 * deletion-only session (scope "delete") expiring at `expiresAt`. Returns "begun", "deleting" (the
 * account was being deleted already) or "gone" (no such account). Throws Unavailable.
 */
export async function beginAccountDeletion(db, accountId, tokenHash, now, expiresAt) {
  // Only the account this batch marked: its deletion began at this request's `now`, and this request's
  // full session is still there. A competing start in the same second has the same `now`; once it
  // marked the account it removed this session, so this batch must not remove its session in turn.
  const marked =
    "EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND deleting_since = ?3) " +
    "AND EXISTS (SELECT 1 FROM sessions WHERE token_hash = ?2 AND account_id = ?1 AND scope = 'full')";
  const results = await query(() =>
    db.batch([
      db
        .prepare(
          `UPDATE accounts SET deleting_since = ?3
           WHERE id = ?1 AND deleting_since IS NULL
             AND EXISTS (SELECT 1 FROM sessions WHERE token_hash = ?2 AND account_id = ?1 AND scope = 'full')`,
        )
        .bind(accountId, tokenHash, now),
      db.prepare(`DELETE FROM sessions WHERE account_id = ?1 AND token_hash <> ?2 AND ${marked}`).bind(accountId, tokenHash, now),
      db
        .prepare(`UPDATE sessions SET scope = 'delete', expires_at = ?4 WHERE token_hash = ?2 AND account_id = ?1 AND ${marked}`)
        .bind(accountId, tokenHash, now, expiresAt),
    ]),
  );
  if (results[0].meta.changes === 1) return "begun";
  return (await accountExists(db, accountId)) ? "deleting" : "gone";
}

/**
 * Removes up to `limit` records of account `accountId` (one batch), giving their charge back to the
 * totals and their places back to the account's cap. Allowed only while the account is being
 * deleted: the opposite of an unshare's condition, which the mark of the deletion makes fail. The mark
 * is what allows it, not a session, since the hourly run continues a deletion with none. Returns the
 * records it removed. Throws Unavailable.
 */
export async function deleteShareChunk(db, accountId, limit) {
  const allowed = "EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND deleting_since IS NOT NULL)";
  // The same rows in every statement: the batch is one transaction and the order is total.
  const chunk = "SELECT id FROM records WHERE owner_id = ?1 ORDER BY id LIMIT ?2";
  const results = await query(() =>
    db.batch([
      db
        .prepare(
          `UPDATE totals SET bytes = bytes - COALESCE((SELECT sum(charge) FROM records WHERE id IN (${chunk})), 0),
             count = count - (SELECT count(*) FROM records WHERE id IN (${chunk})),
             image_bytes = image_bytes - COALESCE((SELECT sum(images_size) FROM records WHERE id IN (${chunk})), 0)
           WHERE id = 1 AND ${allowed}`,
        )
        .bind(accountId, limit),
      db
        .prepare(
          `UPDATE accounts SET share_count = share_count - (SELECT count(*) FROM records WHERE id IN (${chunk}))
           WHERE id = ?1 AND ${allowed}`,
        )
        .bind(accountId, limit),
      db.prepare(`DELETE FROM records WHERE id IN (${chunk}) AND ${allowed}`).bind(accountId, limit),
    ]),
  );
  return results[2].meta.changes;
}

/**
 * The ids of up to `limit` accounts being deleted, the longest deleted first. Read through the
 * partial index of migrations/0004_accounts_deleting.sql, which holds only those accounts, so the
 * read costs what is being deleted rather than every account. Throws Unavailable.
 */
export async function accountsBeingDeleted(db, limit) {
  const { results } = await query(() =>
    db
      .prepare(
        "SELECT id FROM accounts INDEXED BY accounts_deleting WHERE deleting_since IS NOT NULL ORDER BY deleting_since LIMIT ?1",
      )
      .bind(limit)
      .all(),
  );
  return results.map((row) => row.id);
}

/** How many records account `accountId` still shares. Throws Unavailable. */
export async function countShares(db, accountId) {
  const row = await query(() => db.prepare("SELECT count(*) AS n FROM records WHERE owner_id = ?1").bind(accountId).first());
  return row.n;
}

/**
 * Completes the deletion of account `accountId` (one batch), once nothing else of it remains: its
 * trainers, identities, sessions (the deletion-only one included), the logins completed onto it and
 * not claimed, then the account. Children go before the account, whose references D1 enforces; a
 * login holds no reference, but is removed with the rest so no record of a login onto the account
 * outlives it. Throws Unavailable.
 */
export async function finishAccountDeletion(db, accountId) {
  const deleting = "EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND deleting_since IS NOT NULL)";
  await query(() =>
    db.batch([
      db.prepare(`DELETE FROM account_trainers WHERE account_id = ?1 AND ${deleting}`).bind(accountId),
      db.prepare(`DELETE FROM identities WHERE account_id = ?1 AND ${deleting}`).bind(accountId),
      db.prepare(`DELETE FROM sessions WHERE account_id = ?1 AND ${deleting}`).bind(accountId),
      db.prepare(`DELETE FROM logins WHERE account_id = ?1 AND ${deleting}`).bind(accountId),
      db.prepare("DELETE FROM accounts WHERE id = ?1 AND deleting_since IS NOT NULL").bind(accountId),
    ]),
  );
}

/**
 * The records account `owner` shares, newest share day first: `{id, clientKey, sharedDay, form,
 * images}` each, `images` its `imageState`. ACCOUNT_SHARE_CAP bounds how many there are. Throws
 * Unavailable.
 */
export async function listOwnShares(db, owner) {
  const { results } = await query(() =>
    db
      .prepare(
        `SELECT id, client_key, schema, payload, shared_day, images_name, images_stored_at FROM records
         WHERE owner_id = ?1 ORDER BY shared_day DESC, id`,
      )
      .bind(owner)
      .all(),
  );
  return Promise.all(
    results.map(async (row) => {
      if (row.schema !== 1) throw new Error(`record ${row.id} has posted-form schema ${row.schema}`);
      return {
        id: row.id,
        clientKey: row.client_key,
        sharedDay: row.shared_day,
        form: await gunzipJson(row.payload),
        images: imageState(row),
      };
    }),
  );
}
