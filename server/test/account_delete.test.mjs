// Deleting an account (DELETE /api/me), driven over HTTP against a real (local) D1 with sessions
// claimed through the login: the calls that remove the account's shares a chunk at a time, the
// refusals while it is being deleted, and the logins that meet a deletion.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import { CookieJar, GOOGLE, newClientKey, newLoginSecret, postedForm, secretHash, startWorker } from "./support/worker_harness.mjs";

/** Status and parsed body of one response (null for a body that is not JSON). */
async function answer(resPromise) {
  const res = await resPromise;
  const text = await res.text();
  const body = res.headers.get("content-type")?.startsWith("application/json") ? JSON.parse(text) : null;
  return { status: res.status, body, text };
}

const TRAINER = "0f8fad5b-d9cb-469f-a165-70867728950e";

describe("account deletion", () => {
  let worker;
  before(async () => (worker = await startWorker({ testEntry: true })));
  after(() => worker.dispose());
  beforeEach(async () => {
    const db = worker.db;
    await db.batch([
      ...["records", "account_trainers", "sessions", "identities", "logins", "accounts", "daily"].map((table) =>
        db.prepare(`DELETE FROM ${table}`),
      ),
      db.prepare("UPDATE totals SET bytes = 0, count = 0"),
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
    assert.deepEqual(first.body, { remaining: { shares: 1 } });
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
    assert.equal((await deleteMe(token)).status, 200);
    const left = await rowsOf("records", "owner_id", owner);

    for (const res of [
      await shareOnce(token),
      await answer(worker.unshare(token, kept)),
      await postTrainer(token, TRAINER),
      await getMe(token),
      await answer(worker.myShares(token)),
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

    for (const res of [await answer(worker.unshare(token, id)), await shareOnce(token), await postTrainer(token, TRAINER)]) {
      assert.equal(res.status, 409, res.text);
      assert.equal(res.body.error, "account_deleting");
    }
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
});
