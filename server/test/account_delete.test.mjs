// Deleting an account (DELETE /api/me), driven over HTTP against a real (local) D1 with sessions
// claimed through the login: the calls that remove the account's shares a chunk at a time, the
// refusals while it is being deleted, and the logins that meet a deletion. An account that synced
// has its sync rows removed within the day's limit and every version under its B2 prefix, read
// through the in-memory bucket.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import { ROUTES } from "../src/routes.mjs";
import { named, STATEMENT } from "../src/sync_refs.mjs";
import { answer as answerWithHeaders, bodyOf, idIn, newImage, recordPart, root, syncClient } from "./support/sync_fixtures.mjs";
import { CookieJar, GOOGLE, imageBundle, newClientKey, newLoginSecret, postedForm, secretHash, startWorker } from "./support/worker_harness.mjs";

/** Status and parsed body of one response (null for a body that is not JSON). */
async function answer(resPromise) {
  const res = await resPromise;
  const text = await res.text();
  const body = res.headers.get("content-type")?.startsWith("application/json") ? JSON.parse(text) : null;
  return { status: res.status, body, text };
}

/** A hide's (c), recording its markers, by its name: cutting D1 off there leaves a marker no row names. */
const HIDE_RECORD = named(STATEMENT.HIDE_RECORD);

const TRAINER = "0f8fad5b-d9cb-469f-a165-70867728950e";

describe("account deletion", () => {
  let worker;
  before(async () => (worker = await startWorker({ testEntry: true })));
  after(() => worker.dispose());
  beforeEach(async () => {
    const db = worker.db;
    await db.batch([
      ...["records", "account_trainers", "sessions", "identities", "logins", "sync_objects", "sync_accounts", "sync_daily", "accounts", "daily"].map(
        (table) => db.prepare(`DELETE FROM ${table}`),
      ),
      db.prepare("UPDATE totals SET bytes = 0, count = 0"),
      db.prepare("UPDATE sync_totals SET stored_bytes = 0, hidden_bytes = '{}'"),
    ]);
  });

  const deleteMe = (token) => answer(worker.fetch("/api/me", { method: "DELETE", headers: { Authorization: `Bearer ${token}` } }));
  const getMe = (token) => answer(worker.fetch("/api/me", { headers: { Authorization: `Bearer ${token}` } }));
  const postTrainer = (token, trainerId) =>
    answer(
      worker.fetch("/api/me/trainers", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ trainer_id: trainerId }),
      }),
    );
  const shareOnce = (token) => answer(worker.share(token, [{ client_key: newClientKey(), record: postedForm() }]));

  /** Shares `n` records under `token`, MAX_SHARES_PER_REQUEST to a request; returns their ids. */
  async function shareMany(token, n) {
    const ids = [];
    while (ids.length < n) {
      const size = Math.min(limits.MAX_SHARES_PER_REQUEST, n - ids.length);
      const shares = Array.from({ length: size }, () => ({ client_key: newClientKey(), record: postedForm() }));
      const res = await answer(worker.share(token, shares));
      assert.equal(res.status, 200, res.text);
      for (const r of res.body.results) {
        assert.equal(r.status, "created", JSON.stringify(r));
        ids.push(r.id);
      }
    }
    return ids;
  }

  /** Rows of `table` whose `column` is `id`. */
  const rowsOf = async (table, column, id) =>
    (await worker.db.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${column} = ?`).bind(id).first()).n;

  /** A web login of `sub` through Google up to the callback, in a browser of its own: `{s, jar, callback}`. */
  async function loginToCallback(sub = GOOGLE.SUB) {
    const jar = new CookieJar();
    const s = newLoginSecret();
    const begun = await worker.begin({ h: secretHash(s).toString("hex") }, {}, jar);
    await begun.arrayBuffer();
    const callback = worker.authorize(begun.headers.get("location"), { sub });
    return { s, jar, callback };
  }

  /** Completes `login` (from loginToCallback) and claims it; returns the claim's answer. */
  async function finishLogin(login) {
    const back = await worker.visit(login.callback, login.jar);
    await back.arrayBuffer();
    return answer(worker.claim({ s: login.s }, login.jar));
  }

  test("removes the shares ACCOUNT_DELETE_CHUNK at a time with one token, then everything of the account with 204", async () => {
    const token = await worker.signIn();
    const other = await worker.signIn();
    const owner = await worker.accountOf(token);
    assert.equal((await postTrainer(token, TRAINER)).status, 200);
    await shareMany(token, limits.ACCOUNT_DELETE_CHUNK + 1);

    const first = await deleteMe(token);
    assert.equal(first.status, 200, first.text);
    assert.deepEqual(first.body, { remaining: { sync_rows: 0, sync_versions: 0, shares: 1, share_images: 0 } });
    assert.equal(await rowsOf("records", "owner_id", owner), 1);
    assert.equal(await rowsOf("sessions", "account_id", owner), 1, "only the deleting session is left");
    assert.equal((await getMe(other)).status, 401);

    const last = await deleteMe(token);
    assert.equal(last.status, 204, last.text);
    for (const [table, column] of [
      ["records", "owner_id"],
      ["account_trainers", "account_id"],
      ["identities", "account_id"],
      ["sessions", "account_id"],
      ["logins", "account_id"],
      ["accounts", "id"],
    ]) {
      assert.equal(await rowsOf(table, column, owner), 0, table);
    }
    assert.deepEqual(await worker.totals(), { bytes: 0, count: 0 });
    assert.equal((await deleteMe(token)).status, 401);
  });

  test("refuses every write of an account being deleted with 409 account_deleting, and every use of the deleting session but logout", async () => {
    const token = await worker.signIn();
    const owner = await worker.accountOf(token);
    const [kept] = await shareMany(token, limits.ACCOUNT_DELETE_CHUNK + 1);
    const profile = { trainer_name: "name", game_trainer_id: "123456789" };
    const none = { trainer_name: null, game_trainer_id: null };
    assert.equal((await answer(worker.putProfile(token, { ...profile, previous: none }))).status, 200);
    assert.equal((await deleteMe(token)).status, 200);
    const left = await rowsOf("records", "owner_id", owner);
    // The profile is gone from the moment the deletion began, while the account's shares are still listed.
    const list = await answer(worker.fetch(`/u/${owner}.json`));
    assert.deepEqual([list.status, list.body.sharer], [200, null]);
    assert.equal(list.body.count, left);

    for (const res of [
      await shareOnce(token),
      await answer(worker.unshare(token, kept)),
      await postTrainer(token, TRAINER),
      await getMe(token),
      await answer(worker.myShares(token)),
      await answer(worker.putProfile(token, { ...profile, previous: none })),
      await answer(worker.putTagline(token, kept, { tagline: "x", previous: null })),
    ]) {
      assert.equal(res.status, 409, res.text);
      assert.equal(res.body.error, "account_deleting");
    }
    assert.equal(await rowsOf("records", "owner_id", owner), left);
    assert.equal(await rowsOf("account_trainers", "account_id", owner), 0);
  });

  test("refuses the writes of a full session once its account is marked as being deleted", async () => {
    const token = await worker.signIn();
    const owner = await worker.accountOf(token);
    const [id] = await shareMany(token, 1);
    await worker.db.prepare("UPDATE accounts SET deleting_since = 1 WHERE id = ?").bind(owner).run();

    for (const res of [
      await answer(worker.unshare(token, id)),
      await shareOnce(token),
      await postTrainer(token, TRAINER),
      await answer(worker.putProfile(token, { trainer_name: "x", game_trainer_id: null, previous: { trainer_name: null, game_trainer_id: null } })),
      await answer(worker.putTagline(token, id, { tagline: "x", previous: null })),
    ]) {
      assert.equal(res.status, 409, res.text);
      assert.equal(res.body.error, "account_deleting");
    }
    const written = await worker.db
      .prepare("SELECT a.trainer_name, r.tagline FROM accounts a JOIN records r ON r.owner_id = a.id WHERE a.id = ?")
      .bind(owner)
      .first();
    assert.deepEqual(written, { trainer_name: null, tagline: null }, "a write reached an account being deleted");
    assert.equal(await rowsOf("records", "owner_id", owner), 1);
    assert.equal(await rowsOf("account_trainers", "account_id", owner), 0);
    assert.equal((await worker.account(owner)).share_count, 1);
  });

  test("never answers a share that meets the deletion's completion with account_limit", async () => {
    const full = await worker.signIn();
    const deleting = await worker.signIn();
    const owner = await worker.accountOf(full);
    // The state a deletion leaves for a full session that authenticated just before it began.
    await worker.db.batch([
      worker.db.prepare("UPDATE accounts SET deleting_since = 1 WHERE id = ?").bind(owner),
      worker.db.prepare("UPDATE sessions SET scope = 'delete' WHERE token_hash = ?").bind(secretHash(deleting)),
    ]);
    await worker.armGate(2);
    const [shared, deleted] = await Promise.all([shareOnce(full), deleteMe(deleting)]);
    assert.deepEqual(await worker.gate(), { expected: 2, arrived: 2 }, "the requests did not overlap");
    assert.equal(deleted.status, 204, deleted.text);
    // Refused for the account, before or after its row went: never as a limit of the account.
    assert.ok(
      (shared.status === 409 && shared.body.error === "account_deleting") ||
        (shared.status === 401 && shared.body.error === "session_required"),
      shared.text,
    );
    assert.equal(await rowsOf("accounts", "id", owner), 0);
  });

  test("removes a login completed onto the account and not claimed, and a later callback makes a new account", async () => {
    const token = await worker.signIn();
    const owner = await worker.accountOf(token);
    const completed = await loginToCallback();
    const back = await worker.visit(completed.callback, completed.jar);
    await back.arrayBuffer();
    const late = await loginToCallback();
    assert.equal(await rowsOf("logins", "account_id", owner), 1);

    assert.equal((await deleteMe(token)).status, 204);
    assert.equal(await rowsOf("logins", "account_id", owner), 0);
    assert.equal((await answer(worker.claim({ s: completed.s }, completed.jar))).status, 410);

    // Deleting cannot be undone: the identity is gone, so logging in again is a new account.
    const relogin = await finishLogin(late);
    assert.equal(relogin.status, 200, relogin.text);
    assert.notEqual(relogin.body.account_id, owner);
    assert.equal(relogin.body.deleting, false);
    assert.equal(await rowsOf("accounts", "id", owner), 0);
  });

  test("gives a login onto an account being deleted a deletion-only session, also after the first one expired", async () => {
    const token = await worker.signIn();
    const owner = await worker.accountOf(token);
    await shareMany(token, limits.ACCOUNT_DELETE_CHUNK + 1);
    assert.equal((await deleteMe(token)).status, 200);

    await worker.advanceClock(limits.ACCOUNT_DELETE_SESSION_TTL_SECONDS + 1);
    assert.equal((await deleteMe(token)).status, 401);

    const login = await loginToCallback();
    // The Worker's clock keeps running with real time, so the claim is dated between these two reads.
    const before = await worker.now();
    const claimed = await finishLogin(login);
    const after = await worker.now();
    assert.equal(claimed.status, 200, claimed.text);
    assert.equal(claimed.body.account_id, owner);
    assert.equal(claimed.body.deleting, true);
    const ttl = limits.ACCOUNT_DELETE_SESSION_TTL_SECONDS;
    assert.ok(
      claimed.body.expires_at >= before + ttl && claimed.body.expires_at <= after + ttl,
      `${claimed.body.expires_at} not in [${before + ttl}, ${after + ttl}]`,
    );
    const again = claimed.body.token;
    assert.equal((await getMe(again)).status, 409);
    assert.equal((await shareOnce(again)).status, 409);

    assert.equal((await deleteMe(again)).status, 204);
    assert.equal(await rowsOf("accounts", "id", owner), 0);
    assert.equal(await rowsOf("records", "owner_id", owner), 0);
  });

  test("two deletions begun from two full sessions in the same second keep one session to finish it", async () => {
    const first = await worker.signIn();
    const second = await worker.signIn();
    const owner = await worker.accountOf(first);
    await shareMany(first, limits.ACCOUNT_DELETE_CHUNK + 1);
    // Both starts must read the same second: move the Worker's clock to just past a second boundary,
    // which leaves the rest of that second for the two requests to read it.
    await worker.advanceClock((1100 - (Date.now() % 1000)) / 1000);
    await worker.armGate(2);
    const begun = await Promise.all([deleteMe(first), deleteMe(second)]);
    assert.deepEqual(await worker.gate(), { expected: 2, arrived: 2 }, "the requests did not overlap");

    const at = begun.findIndex((res) => res.status === 200);
    assert.notEqual(at, -1, JSON.stringify(begun.map((res) => res.text)));
    assert.equal(await rowsOf("sessions", "account_id", owner), 1);
    const token = [first, second][at];
    assert.equal((await deleteMe(token)).status, 204);
    assert.equal(await rowsOf("accounts", "id", owner), 0);
    assert.equal(await rowsOf("records", "owner_id", owner), 0);
    assert.equal(await rowsOf("sessions", "account_id", owner), 0);
  });

  test("a deleting session may log out", async () => {
    const token = await worker.signIn();
    await shareMany(token, limits.ACCOUNT_DELETE_CHUNK + 1);
    assert.equal((await deleteMe(token)).status, 200);
    assert.equal((await worker.logout(token)).status, 204);
    assert.equal((await deleteMe(token)).status, 401);
  });

  /** Calls DELETE /api/me with `token` until it answers other than 200, at most `calls` times; the answers. */
  async function deleteUntilDone(token, calls) {
    const answers = [];
    for (let i = 0; i < calls; i++) {
      const res = await deleteMe(token);
      answers.push(res);
      if (res.status !== 200) break;
    }
    return answers;
  }

  /** The sync rows of account `id`: its sync_objects rows and its sync_accounts row. */
  const syncRowsOf = async (id) => (await rowsOf("sync_objects", "account_id", id)) + (await rowsOf("sync_accounts", "account_id", id));

  /** A signed-in account syncing PNGs: `{token, id, client, prefix}`. */
  async function syncing(sub) {
    const token = await worker.signIn(sub);
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    return { token, id, client, prefix: `a/${id}/` };
  }

  /** Inserts `n` stored, referenced sync_objects rows of account `id` straight into D1. */
  async function insertSyncRows(id, n) {
    const rows = Array.from({ length: n }, (_, i) => ({ name: String(i).padStart(64, "0") }));
    await worker.db
      .prepare(
        `INSERT INTO sync_objects (account_id, name, kind, size, stored_at, ref_count)
         SELECT ?1, json_extract(value, '$.name'), 'body', 10, 1, 1 FROM json_each(?2)`,
      )
      .bind(id, JSON.stringify(rows))
      .run();
  }

  /** The UTC day of the Worker's clock. */
  const today = async () => Math.floor((await worker.now()) / 86_400);

  /** Sets today's sync rows so that the deletions' share leaves `left` rows. */
  async function leaveDeleteRows(left) {
    await worker.db
      .prepare(
        `INSERT INTO sync_daily (day, rows_written, delete_rows) VALUES (?1, ?2, ?2)
         ON CONFLICT (day) DO UPDATE SET rows_written = ?2, delete_rows = ?2`,
      )
      .bind(await today(), limits.SYNC_DAILY_DELETE_ROWS - left)
      .run();
  }

  /** The list row of record `id` with body `body` (`{name, body}`) and the image binding in it. */
  const rowOf = (id, body) => ({
    id,
    body: { name: body.name, written_at: 1 },
    archive: { state: "normal", written_at: 1 },
    image: JSON.parse(body.body).metadata.binding,
    ratings: {},
  });

  /** The records of writes under the prefix of account `id` that no row accounts for yet (sync_writes). */
  const writesOf = (id) => rowsOf("sync_writes", "account_id", id);

  /** Moves the Worker's clock on until what a write a request left records is taken, and runs the hourly run. */
  async function takeWrites() {
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER + 2 * limits.RESTORE_MARGIN_SECONDS);
    assert.equal(await worker.scheduled(), "ok");
  }

  test("a put that passed its session check before the deletion began and reaches B2 after it answered 204 leaves nothing once the hourly run took its write", async () => {
    const a = await syncing("sync-put-after-delete");
    const body = bodyOf({});
    const key = `${a.prefix}${body.name}`;
    const store = worker.b2.hold("PUT", key);
    const put = a.client.putBodies([body]);
    await store.entered;
    const answers = await deleteUntilDone(a.token, 5);
    assert.equal(answers.at(-1).status, 204, answers.map((r) => r.text).join("\n"));
    store.release();
    assert.equal((await put).status, 503, "its row cannot reference the deleted account");
    assert.deepEqual(worker.b2.keys(a.prefix), [key], "stored under the prefix of a deleted account");
    assert.equal(await writesOf(a.id), 1);

    await takeWrites();
    assert.deepEqual(worker.b2.keys(a.prefix), []);
    assert.equal(await writesOf(a.id), 0);
  });

  test("a hide by the hourly run that adds its marker after the deletion listed the prefix for the last time, cut off before it gave the marker back, leaves nothing once a later run took its write", async () => {
    const a = await syncing("sync-hide-after-delete");
    const body = bodyOf({});
    assert.equal((await a.client.putBodies([body])).status, 200);
    const key = `${a.prefix}${body.name}`;
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    // The run reads the body as a hide to do and stops at adding its marker; the deletion removes the
    // row and every version, and answers 204, before the marker lands. The run finds no row to record
    // the marker on and would give it back; it is cut off right there.
    const hide = worker.b2.hold("DELETE_OBJECTS", key);
    const run = worker.scheduled();
    await hide.entered;
    const answers = await deleteUntilDone(a.token, 5);
    assert.equal(answers.at(-1).status, 204, answers.map((r) => r.text).join("\n"));
    await worker.cutD1After(HIDE_RECORD);
    hide.release();
    assert.notEqual(await run, "ok");
    await worker.restoreD1();
    assert.deepEqual(worker.b2.keys(a.prefix), [key], "a marker under the prefix of a deleted account");
    assert.deepEqual(worker.b2.versions(key), ["m"]);

    await takeWrites();
    assert.deepEqual(worker.b2.keys(a.prefix), []);
    assert.equal(await writesOf(a.id), 0);
  });

  test("a hide by the hourly run that adds its marker after the deletion listed the prefix for the last time, and that B2 fails to give back, leaves nothing once a later run took its write", async () => {
    const a = await syncing("sync-hide-after-delete-failed");
    const body = bodyOf({});
    assert.equal((await a.client.putBodies([body])).status, 200);
    const key = `${a.prefix}${body.name}`;
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    // The run stops at adding its marker while the deletion answers 204; it then finds no row to record
    // the marker on, and B2 fails the DeleteObjects that would give it back. The run itself finishes.
    const hide = worker.b2.hold("DELETE_OBJECTS", key);
    const run = worker.scheduled();
    await hide.entered;
    const answers = await deleteUntilDone(a.token, 5);
    assert.equal(answers.at(-1).status, 204, answers.map((r) => r.text).join("\n"));
    const giveBack = worker.b2.hold("DELETE_OBJECTS", key);
    hide.release();
    await giveBack.entered;
    worker.b2.failTarget(key);
    giveBack.release();
    assert.equal(await run, "ok");
    assert.deepEqual(worker.b2.versions(key), ["m"], "a marker under the prefix of a deleted account");

    await takeWrites();
    assert.deepEqual(worker.b2.keys(a.prefix), []);
    assert.equal(await writesOf(a.id), 0);
  });

  test("removes the bundle of every share under the account's prefix, and one a PUT stores after the deletion answered 204 once the hourly run took its write, another account's kept", async () => {
    const shareImages = async (token, bundles) => {
      const shares = bundles.map((b) => ({ client_key: newClientKey(), record: postedForm(), images: b.images }));
      return (await answer(worker.share(token, shares))).body.results.map((r) => r.id);
    };
    const imageWritesOf = async (id) =>
      (await worker.db.prepare("SELECT count(*) AS n FROM sync_writes WHERE account_id = ?1 AND space = 's'").bind(id).first()).n;
    const token = await worker.signIn("images-delete");
    const id = await worker.accountOf(token);
    const other = await worker.signIn("images-delete-other");
    const [stored, late, theirs] = [1, 2, 3].map((seed) => imageBundle({ seed }));
    const [storedId, lateId] = await shareImages(token, [stored, late]);
    const [theirsId] = await shareImages(other, [theirs]);
    assert.equal((await worker.putImages(token, storedId, stored.bytes)).status, 200);
    assert.equal((await worker.putImages(other, theirsId, theirs.bytes)).status, 200);
    const theirKey = `s/${await worker.accountOf(other)}/${theirsId}/${theirs.images.name}`;

    const lateKey = `s/${id}/${lateId}/${late.images.name}`;
    const held = worker.b2.hold("PUT", lateKey);
    const put = answer(worker.putImages(token, lateId, late.bytes));
    await held.entered;
    const answers = await deleteUntilDone(token, 5);
    assert.equal(answers.at(-1).status, 204, answers.map((r) => r.text).join("\n"));
    held.release();
    assert.equal((await put).status, 404, "a share of a deleted account was recorded as stored");
    assert.deepEqual(worker.b2.keys(`s/${id}/`), [lateKey], "the deletion left a bundle, or the late put stored none");
    assert.equal(await imageWritesOf(id), 1);

    await takeWrites();
    assert.deepEqual(worker.b2.keys(`s/${id}/`), []);
    assert.equal(await imageWritesOf(id), 0);
    assert.deepEqual(worker.b2.versions(theirKey), ["v"], "another account's bundle was reached");
    assert.equal((await worker.getImages(theirsId)).status, 200);
  });

  test("removes everything an account synced, every version and marker under its B2 prefix and every sync row, while D1 enforces references", async () => {
    assert.deepEqual((await worker.db.prepare("PRAGMA foreign_keys").all()).results, [{ foreign_keys: 1 }]);
    const a = await syncing("sync-deleted");
    const b = await syncing("sync-kept");
    const [skill, factor, later] = [newImage(), newImage(), newImage()];
    const first = bodyOf({ skill_png: skill.name, skill_jpeg: null, factor_png: factor.name });
    const second = bodyOf({ skill_png: later.name, skill_jpeg: null, factor_png: newImage().name });
    assert.equal((await a.client.putBodies([first, second])).status, 200);
    for (const image of [skill, factor, later]) assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    // The current root and its part, which reference the second body (one of whose images was never
    // put); the first root, replaced, and what only it referenced, hidden.
    const record = idIn(0);
    const p1 = recordPart(0, [rowOf(record, first)]);
    const p2 = recordPart(0, [rowOf(record, second)]);
    for (const p of [p1, p2]) assert.equal((await a.client.putPart(p)).status, 200);
    assert.equal((await a.client.replace(0, root({ 0: p1.name }))).status, 200);
    assert.equal((await a.client.replace(1, root({ 0: p2.name }))).status, 200);
    // Put and never referenced, so hidden by the account's next write once old enough, that hide cut
    // off after B2 added its marker and before D1 recorded it; and put and never referenced, shown.
    assert.equal((await a.client.putBodies([bodyOf({})])).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    await worker.cutD1At(HIDE_RECORD);
    assert.equal((await a.client.putBodies([bodyOf({})])).status, 200);
    await worker.restoreD1();
    assert.equal((await b.client.putBodies([bodyOf({})])).status, 200);
    const kept = worker.b2.keys(b.prefix);
    assert.ok(worker.b2.keys(a.prefix).some((key) => worker.b2.versions(key).includes("m")), "something is hidden");
    assert.ok((await syncRowsOf(a.id)) > 0);

    // Two versions to a page, so the versions take more than one call.
    worker.b2.pageSize = 2;
    try {
      const answers = await deleteUntilDone(a.token, 20);
      assert.deepEqual(
        answers.map((res) => res.status),
        [...Array(answers.length - 1).fill(200), 204],
        answers.map((res) => res.text).join("\n"),
      );
      assert.ok(answers.length > 2, "the versions took more than one call");
    } finally {
      worker.b2.pageSize = 1000;
    }
    assert.deepEqual(worker.b2.keys(a.prefix), []);
    assert.equal(await syncRowsOf(a.id), 0);
    assert.equal(await rowsOf("accounts", "id", a.id), 0);
    assert.deepEqual(worker.b2.keys(b.prefix), kept);
    const totals = await worker.db.prepare("SELECT stored_bytes FROM sync_totals").first();
    const bAccount = await worker.db.prepare("SELECT stored_bytes FROM sync_accounts WHERE account_id = ?").bind(b.id).first();
    assert.equal(totals.stored_bytes, bAccount.stored_bytes);
  });

  test("removes sync rows only within the deletions' half of the day's sync rows, refuses with sync_paused_today when that has no room, and goes on the next day", async () => {
    const a = await syncing("sync-paused");
    await insertSyncRows(a.id, 10);
    // Room for four rows at what each costs, and then for less than one.
    await leaveDeleteRows(4 * 3 + 2);
    const some = await deleteMe(a.token);
    assert.equal(some.status, 200, some.text);
    assert.deepEqual(some.body, { remaining: { sync_rows: 7, sync_versions: 0, shares: 0, share_images: 0 } });

    const paused = await answerWithHeaders(worker.fetch("/api/me", { method: "DELETE", headers: { Authorization: `Bearer ${a.token}` } }));
    assert.equal(paused.status, 429, paused.text);
    assert.deepEqual(paused.body, { error: "sync_paused_today", remaining: { sync_rows: 7, sync_versions: 0, shares: 0, share_images: 0 } });
    assert.ok(Number(paused.headers.get("retry-after")) > 0);
    assert.equal(await syncRowsOf(a.id), 7);
    const day = await worker.db.prepare("SELECT rows_written, delete_rows FROM sync_daily WHERE day = ?").bind(await today()).first();
    assert.deepEqual(day, { rows_written: limits.SYNC_DAILY_DELETE_ROWS - 2, delete_rows: limits.SYNC_DAILY_DELETE_ROWS - 2 });

    await worker.advanceClock(86_400);
    const done = await deleteMe(a.token);
    assert.equal(done.status, 204, done.text);
    assert.equal(await syncRowsOf(a.id), 0);
    assert.equal(await rowsOf("accounts", "id", a.id), 0);
  });

  test("counts what removing sync rows reads in the day's sync rows read, and refuses with sync_paused_today once those leave less than a call reads", async () => {
    const a = await syncing("sync-read-paused");
    await insertSyncRows(a.id, 10);
    const readOn = async () =>
      (await worker.db.prepare("SELECT rows_read FROM sync_daily WHERE day = ?").bind(await today()).first()).rows_read;
    // The first call begins and removes every row; what it read is counted. Leave the rows written
    // alone and the rows read one short of what a call may read.
    await worker.db
      .prepare("INSERT INTO sync_daily (day, rows_read) VALUES (?1, ?2) ON CONFLICT (day) DO UPDATE SET rows_read = ?2")
      .bind(await today(), limits.SYNC_DAILY_READ_ROWS - limits.ACCOUNT_DELETE_SYNC_READ_ROWS + 1)
      .run();
    const before = await readOn();
    const paused = await answerWithHeaders(worker.fetch("/api/me", { method: "DELETE", headers: { Authorization: `Bearer ${a.token}` } }));
    assert.equal(paused.status, 429, paused.text);
    assert.deepEqual(paused.body, { error: "sync_paused_today", remaining: { sync_rows: 11, sync_versions: 0, shares: 0, share_images: 0 } });
    assert.ok((await readOn()) > before, "what the call read is counted");
    assert.equal(await syncRowsOf(a.id), 11);

    await worker.advanceClock(86_400);
    const done = await deleteMe(a.token);
    assert.equal(done.status, 204, done.text);
    assert.ok((await readOn()) > 0, "the next day counts its reads too");
    assert.equal(await syncRowsOf(a.id), 0);
  });

  test("refuses every sync endpoint of an account being deleted with 409 account_deleting, the deletion-only session included", async () => {
    const a = await syncing("sync-refused");
    await insertSyncRows(a.id, 1);
    await leaveDeleteRows(0);
    assert.equal((await deleteMe(a.token)).status, 429);

    const sync = ROUTES.filter(([, , pattern]) => pattern.source.startsWith("^\\/api\\/sync\\/"));
    assert.ok(sync.length > 0);
    for (const [method, name, pattern] of sync) {
      const path = pattern.source.slice(1, -1).replaceAll("\\/", "/").replace("([0-9a-f]{64})", "0".repeat(64));
      const headers = { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` };
      const res = await answer(worker.fetch(path, { method, headers, body: method === "GET" ? undefined : "{}" }));
      assert.equal(res.status, 409, `${name}: ${res.text}`);
      assert.equal(res.body.error, "account_deleting", name);
    }
    assert.equal(await syncRowsOf(a.id), 2);
  });

  describe("with sync switched off", () => {
    // A Worker with SYNC_ENABLED "false" stands in for the shared one meanwhile: the helpers above read
    // `worker` when they are called.
    let shared;
    before(async () => {
      shared = worker;
      worker = await startWorker({ testEntry: true, vars: { SYNC_ENABLED: "false" } });
    });
    after(async () => {
      await worker.dispose();
      worker = shared;
    });

    test("the hourly run of the next UTC day finishes a deletion the day's share stopped with sync_paused_today", async () => {
      const token = await worker.signIn("deletion-paused-sync-off");
      const id = await worker.accountOf(token);
      await insertSyncRows(id, 10);
      await leaveDeleteRows(0);
      const paused = await deleteMe(token);
      assert.equal(paused.status, 429, paused.text);
      assert.equal(paused.body.error, "sync_paused_today");
      const left = await syncRowsOf(id);
      assert.ok(left > 0);

      // The day's share still has no room: the run removes nothing.
      assert.equal(await worker.scheduled(), "ok");
      assert.equal(await syncRowsOf(id), left);
      assert.equal(await rowsOf("accounts", "id", id), 1);

      await worker.advanceClock(86_400);
      assert.equal(await worker.scheduled(), "ok");
      assert.equal(await syncRowsOf(id), 0);
      assert.equal(await rowsOf("accounts", "id", id), 0);
      assert.equal((await getMe(token)).status, 401);
    });
  });
});
