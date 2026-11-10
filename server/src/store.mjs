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
 * "none" (it declares none, or an operator took its images down: `withdrawShareImages`), "pending" (declared, the bundle not stored
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
 * The posted form, share day, owner and declared images (`declaredImages`) of record `id`, with what its
 * sharer wrote for readers: the share's `tagline` and the owner's `profile` (`profileOf`), each null
 * when not written. Null when no such row exists.
 */
export async function readRecord(db, id) {
  const row = await db
    .prepare(
      `SELECT r.schema, r.payload, r.shared_day, r.owner_id, r.images, r.images_name, r.images_size, r.images_stored_at,
              r.tagline, a.trainer_name, a.game_trainer_id
       FROM records r LEFT JOIN accounts a ON a.id = r.owner_id WHERE r.id = ?`,
    )
    .bind(id)
    .first();
  if (row === null) return null;
  if (row.schema !== 1) throw new Error(`record ${id} has posted-form schema ${row.schema}`);
  return {
    form: await gunzipJson(row.payload),
    sharedDay: row.shared_day,
    owner: row.owner_id,
    images: declaredImages(row),
    tagline: row.tagline,
    profile: profileOf(row),
  };
}

/** The public profile an account's row holds: `{trainerName, gameTrainerId}`, each null when not written. */
const profileOf = (row) => ({ trainerName: row.trainer_name ?? null, gameTrainerId: row.game_trainer_id ?? null });

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
 * Account `id` as `GET /api/me` reads it: `{shareCount, deleting, trainerIds, profile}` (`profileOf`),
 * or null when no such account exists. Throws Unavailable.
 */
export async function readAccount(db, id) {
  const [account, trainers] = await query(() =>
    db.batch([
      db.prepare("SELECT share_count, deleting_since, trainer_name, game_trainer_id FROM accounts WHERE id = ?1").bind(id),
      db.prepare("SELECT trainer_id FROM account_trainers WHERE account_id = ?1 ORDER BY trainer_id").bind(id),
    ]),
  );
  const row = account.results[0];
  if (row === undefined) return null;
  return {
    shareCount: row.share_count,
    deleting: row.deleting_since !== null,
    trainerIds: trainers.results.map((t) => t.trainer_id),
    profile: profileOf(row),
  };
}

/** Whether account `id` exists. Throws Unavailable. */
export async function accountExists(db, id) {
  return (await query(() => db.prepare("SELECT 1 AS found FROM accounts WHERE id = ?1").bind(id).first())) !== null;
}

/** The public profile (`profileOf`) of account `id`, or null when no such account exists. Throws Unavailable. */
export async function readProfile(db, id) {
  const row = await query(() => db.prepare("SELECT trainer_name, game_trainer_id FROM accounts WHERE id = ?1").bind(id).first());
  return row === null ? null : profileOf(row);
}

/** The text writes (taglines and profiles) of the account in parameter `account` on the UTC day in parameter `day`. */
const accountTextWritesToday = (account, day) =>
  `(SELECT CASE WHEN text_writes_day = ${day} THEN text_writes ELSE 0 END FROM accounts WHERE id = ${account})`;

/** The text writes over every account on the UTC day in parameter `day`. */
const textWritesToday = (day) => `COALESCE((SELECT text_writes FROM daily WHERE day = ${day}), 0)`;

/**
 * The two statements that count one text write of account `owner` on UTC day `day`, each made only
 * when the statement before it changed one row: the account's counter, then the day's.
 */
const countTextWrite = (db, owner, day) => [
  db
    .prepare(
      `UPDATE accounts SET text_writes = CASE WHEN text_writes_day = ?2 THEN text_writes + 1 ELSE 1 END, text_writes_day = ?2
       WHERE id = ?1 AND changes() = 1`,
    )
    .bind(owner, day),
  db
    .prepare(
      `INSERT INTO daily (day, text_writes) SELECT ?1, 1 WHERE changes() = 1
       ON CONFLICT (day) DO UPDATE SET text_writes = text_writes + 1`,
    )
    .bind(day),
];

/**
 * Which text-write limit of `quota` (`{accountLimit, dailyLimit}`) is used up: "account", "service",
 * or null. `row` holds `account_writes` and `service_writes`, read with `accountTextWritesToday` and
 * `textWritesToday`.
 */
const textWriteRefusal = (row, quota) =>
  row.account_writes >= quota.accountLimit ? "account" : row.service_writes >= quota.dailyLimit ? "service" : null;

/**
 * The SQL condition that the text-write limits leave room for a write of the account in parameter
 * `account` on the UTC day in parameter `day`, against the limits in parameters `accountLimit` and
 * `dailyLimit`; always true when parameter `clears` is 1, for a write that only clears (`onlyClears`).
 */
const textWriteRoom = (clears, account, day, accountLimit, dailyLimit) =>
  `(${clears} = 1 OR (${accountTextWritesToday(account, day)} < ${accountLimit} AND ${textWritesToday(day)} < ${dailyLimit}))`;

/**
 * Whether writing `next` over `previous` (objects with the same fields) only clears: at least one field
 * goes from a value to null and every other field is left as it is. A write that clears one field and
 * changes another does not only clear, so no new text is published past the limits. A write that only
 * clears is neither refused by the text-write limits nor counted against them, so a sharer past them
 * can still take text down; the text cleared had to be written first, so clears stay bounded by writes.
 */
const onlyClears = (next, previous) =>
  Object.keys(next).every((k) => next[k] === null || next[k] === previous[k]) &&
  Object.keys(next).some((k) => next[k] === null && previous[k] !== null);

/**
 * Replaces the public profile of account `owner` with `profile` (`{trainerName, gameTrainerId}`) if it
 * is still `previous`, both fields compared, the account is not being deleted, and the text-write
 * limits of `quota` (`{day, accountLimit, dailyLimit}`) leave room; a write made counts against them.
 * A write that only clears (`onlyClears`) is neither refused by those limits nor counted.
 * One batch, so a write made from a value another device has changed since changes and counts nothing.
 * Returns `{status}`: "written", "deleting", "gone" (no such account), `{status: "changed", profile}`
 * when the profile is not `previous`, `profile` what it is, or `{status: "limit", scope}` ("account"
 * or "service"). Throws Unavailable.
 */
export async function writeProfile(db, owner, profile, previous, quota) {
  const clears = onlyClears(profile, previous);
  const results = await query(() =>
    db.batch([
      db
        .prepare(
          `UPDATE accounts SET trainer_name = ?2, game_trainer_id = ?3
           WHERE id = ?1 AND deleting_since IS NULL AND trainer_name IS ?4 AND game_trainer_id IS ?5
             AND ${textWriteRoom("?9", "?1", "?6", "?7", "?8")}`,
        )
        .bind(
          owner,
          profile.trainerName,
          profile.gameTrainerId,
          previous.trainerName,
          previous.gameTrainerId,
          quota.day,
          quota.accountLimit,
          quota.dailyLimit,
          clears ? 1 : 0,
        ),
      ...(clears ? [] : countTextWrite(db, owner, quota.day)),
    ]),
  );
  if (results[0].meta.changes === 1) return { status: "written" };
  const row = await query(() =>
    db
      .prepare(
        `SELECT deleting_since, trainer_name, game_trainer_id,
                ${accountTextWritesToday("?1", "?2")} AS account_writes, ${textWritesToday("?2")} AS service_writes
         FROM accounts WHERE id = ?1`,
      )
      .bind(owner, quota.day)
      .first(),
  );
  if (row === null) return { status: "gone" };
  if (row.deleting_since !== null) return { status: "deleting" };
  const current = profileOf(row);
  const unchanged = current.trainerName === previous.trainerName && current.gameTrainerId === previous.gameTrainerId;
  const scope = unchanged && !clears ? textWriteRefusal(row, quota) : null;
  if (scope !== null) return { status: "limit", scope };
  return { status: "changed", profile: current };
}

/**
 * Replaces the tagline of share `id` with `tagline` if account `owner` holds the share, its tagline is
 * still `previous`, and the account is not being deleted (one batch). The row's charge and the totals
 * move by `delta`, the UTF-8 bytes of `tagline` less those of `previous`, so an unshare and a deletion
 * give the tagline's bytes back with the rest of the charge. A tagline that grows is refused past
 * `budget` (STORAGE_BUDGET); one that shrinks or goes never is. Removing the tagline (`tagline`
 * null) only clears (`onlyClears`), so the text-write limits neither refuse nor count it. Returns `{status}`: "written",
 * "deleting" (the account is being deleted, or its deletion completed), "notFound", "forbidden"
 * (another account holds it), "storage" (the budget refused it), `{status: "limit", scope}` when a
 * text-write limit refused it (as `writeProfile`, with `day`, `accountLimit` and `dailyLimit` its
 * `quota`), or `{status: "changed", tagline}` when the tagline is not `previous`, `tagline` what it is.
 * A write made counts against the text-write limits. Throws Unavailable.
 */
export async function writeTagline(db, { id, owner, tagline, previous, delta, budget, day, accountLimit, dailyLimit }) {
  const clears = onlyClears({ tagline }, { tagline: previous });
  const match = "id = ?1 AND owner_id = ?2 AND EXISTS (SELECT 1 FROM accounts WHERE id = ?2 AND deleting_since IS NULL)";
  const results = await query(() =>
    db.batch([
      db
        .prepare(
          `UPDATE records SET tagline = ?3, charge = charge + ?5
           WHERE ${match} AND tagline IS ?4 AND (?5 <= 0 OR (SELECT bytes FROM totals WHERE id = 1) + ?5 <= ?6)
             AND ${textWriteRoom("?10", "?2", "?7", "?8", "?9")}`,
        )
        .bind(id, owner, tagline, previous, delta, budget, day, accountLimit, dailyLimit, clears ? 1 : 0),
      // changes() counts what the statement before changed: the totals, then the counters, move only
      // with the row this batch updated (the totals row always exists, so its update changes one).
      db.prepare("UPDATE totals SET bytes = bytes + ?1 WHERE id = 1 AND changes() = 1").bind(delta),
      ...(clears ? [] : countTextWrite(db, owner, day)),
    ]),
  );
  if (results[0].meta.changes === 1) return { status: "written" };
  const row = await query(() =>
    db
      .prepare(
        `SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ?2 AND deleting_since IS NULL) AS writable,
                (SELECT owner_id FROM records WHERE id = ?1) AS owner_id,
                (SELECT tagline FROM records WHERE id = ?1) AS tagline,
                (SELECT bytes FROM totals WHERE id = 1) AS bytes,
                ${accountTextWritesToday("?2", "?3")} AS account_writes, ${textWritesToday("?3")} AS service_writes`,
      )
      .bind(id, owner, day)
      .first(),
  );
  if (row.writable === 0) return { status: "deleting" };
  if (row.owner_id === null) return { status: "notFound" };
  if (row.owner_id !== owner) return { status: "forbidden" };
  if (row.tagline === previous) {
    const scope = clears ? null : textWriteRefusal(row, { accountLimit, dailyLimit });
    if (scope !== null) return { status: "limit", scope };
    if (delta > 0 && row.bytes + delta > budget) return { status: "storage" };
  }
  return { status: "changed", tagline: row.tagline };
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
 * The statement that records in the write ledger (space "s", for request `by` at clock `now`) that the
 * bundle of share `id` of account `owner` is to go, when the row `match` (bound to ?1 `id`, ?2 `owner`)
 * selects declares images: from its commit no row accounts for the bundle's versions, and the record
 * stays until they are deleted (`removeBundle` in share_images.mjs, or the hourly run).
 */
const bundleRemoval = (db, match, id, owner, by, now) =>
  db
    .prepare(
      `INSERT INTO sync_writes (account_id, write_by, names, written_at, space)
       SELECT ?2, ?3, json_array(id || '/' || images_name), ?4, 's' FROM records WHERE ${match} AND images_name IS NOT NULL`,
    )
    .bind(id, owner, by, now);

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
    bundleRemoval(db, match, id, owner, by, now),
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
 * Withdraws the images of share `id` if account `owner` holds it and it declares images, while the
 * account is not being deleted: in one transaction it gives the declared image bytes back to the totals,
 * records the bundle's removal as an unshare does (`bundleRemoval`), and clears the declaration, so the
 * share stays and tells no images from then on, as one shared without them. The row's charge stays as
 * charged, given back whole when the share goes. Returns the bundle's name when it withdrew them, else
 * null (no such share, another account's, one without images or with them withdrawn already, or an
 * account being deleted, whose deletion removes the bundle itself). Throws Unavailable.
 */
export async function withdrawShareImages(db, id, owner, by, now) {
  const match =
    "id = ?1 AND owner_id = ?2 AND images_name IS NOT NULL AND EXISTS (SELECT 1 FROM accounts WHERE id = ?2 AND deleting_since IS NULL)";
  const results = await query(() =>
    db.batch([
      db
        .prepare(
          `UPDATE totals SET image_bytes = image_bytes - (SELECT images_size FROM records WHERE ${match})
           WHERE id = 1 AND EXISTS (SELECT 1 FROM records WHERE ${match})`,
        )
        .bind(id, owner),
      bundleRemoval(db, match, id, owner, by, now),
      db.prepare(`SELECT images_name FROM records WHERE ${match}`).bind(id, owner),
      db
        .prepare(`UPDATE records SET images = NULL, images_name = NULL, images_size = NULL, images_stored_at = NULL WHERE ${match}`)
        .bind(id, owner),
    ]),
  );
  return results[3].meta.changes === 1 ? results[2].results[0].images_name : null;
}

/**
 * Begins deleting account `accountId` from its full session `tokenHash` (one batch): marks the
 * account as being deleted since `now` and clears its public profile (from then on no page shows it,
 * and no write brings it back, since every write requires the mark's absence), removes every other
 * session of it, and turns this one into a
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
          `UPDATE accounts SET deleting_since = ?3, trainer_name = NULL, game_trainer_id = NULL
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
 * images, tagline}` each, `images` its `imageState` and `tagline` null when not written.
 * ACCOUNT_SHARE_CAP bounds how many there are. Throws Unavailable.
 */
export async function listOwnShares(db, owner) {
  const { results } = await query(() =>
    db
      .prepare(
        `SELECT id, client_key, schema, payload, shared_day, images_name, images_stored_at, tagline FROM records
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
        tagline: row.tagline,
      };
    }),
  );
}

/** The UTC day share `id` was shared on, or null when it does not exist (never shared, or unshared). Throws Unavailable. */
export async function readSharedDay(db, id) {
  const row = await query(() => db.prepare("SELECT shared_day FROM records WHERE id = ?").bind(id).first());
  return row === null ? null : row.shared_day;
}

/**
 * Counts one report on UTC day `day` while the day's reports are below `limit`. Returns whether it was
 * counted; a report that was not is refused. Throws Unavailable.
 */
export async function countReport(db, day, limit) {
  const result = await query(() =>
    db
      .prepare(
        `INSERT INTO daily (day, reports) SELECT ?1, 1 WHERE ?2 > 0
         ON CONFLICT (day) DO UPDATE SET reports = reports + 1 WHERE reports < ?2`,
      )
      .bind(day, limit)
      .run(),
  );
  return result.meta.changes === 1;
}
