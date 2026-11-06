// Sharing under an account (POST /api/shares, PATCH and DELETE /api/shares/<id>, GET /api/me/shares) and the
// sharing switch, driven over HTTP against a real (local) D1 with sessions claimed through the login.
//
// The concurrency cases run through the batch gate (see worker_harness.mjs): every racing request
// has finished its reads before any batch runs, so they exercise the interleaving the judgement of
// a share is written for. Local D1 serialises the batches the way production D1 is documented to;
// whether production does is checked on the staging D1, not here.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import { newClientKey, newLoginHash, ORIGIN, postedForm, secretHash, startWorker } from "./support/worker_harness.mjs";

/** Status and parsed body of one response (null for a body that is not JSON). */
async function answer(resPromise) {
  const res = await resPromise;
  const text = await res.text();
  const body = res.headers.get("content-type")?.startsWith("application/json") ? JSON.parse(text) : null;
  return { status: res.status, body, text, headers: res.headers };
}

/** A share of `record` (the fixture's form by default) under a fresh client key. */
const share = (record = postedForm()) => ({ client_key: newClientKey(), record });

/** The results of one POST /api/shares that answered 200. */
async function results(worker, token, shares) {
  const res = await answer(worker.share(token, shares));
  assert.equal(res.status, 200, JSON.stringify(res.body));
  return res.body.results;
}

/** PATCH /api/shares/<id> with `body` as JSON. */
const changeView = (worker, token, id, body) =>
  worker.fetch(`/api/shares/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });

const statuses = (list) => list.map((r) => (r.error === undefined ? r.status : `${r.status} ${r.error}`));

/** The charge of a stored record; every share of the fixture's form carries the same one. */
const chargeOf = async (worker) => (await worker.db.prepare("SELECT charge FROM records").first()).charge;

/** The Worker's current UTC day (needs `testEntry: true`). */
const today = async (worker) => Math.floor((await worker.now()) / 86_400);

describe("share checks", () => {
  let worker;
  let token;
  let owner;
  before(async () => {
    worker = await startWorker();
    token = await worker.signIn();
    owner = await worker.accountOf(token);
  });
  after(() => worker.dispose());

  /** Shares `record` (with `view`, if given) and asserts that share alone was refused, storing and charging nothing. */
  async function refused(record, error, field, view) {
    const [result] = await results(worker, token, [view === undefined ? share(record) : { ...share(record), view }]);
    assert.deepEqual(result, field === undefined ? { status: "refused", error } : { status: "refused", error, field });
    assert.equal(await worker.count("records"), 0);
    assert.deepEqual(await worker.account(owner), { share_count: 0, quota_day: 0, quota_bytes: 0 });
  }

  test("an unknown key is refused at any depth", async () => {
    await refused({ ...postedForm(), trainer_id: "123456789" }, "invalid_payload", "record.trainer_id");
    await refused(postedForm({ trainee: { character: 3, card: 3, rank: 2, icon: 0 } }), "invalid_payload", "record.trainee.icon");
  });

  test("a sid past the end of a table is refused, as server_tables_older when the client's modules are newer", async () => {
    const pastEnd = [{ id: 3 }]; // the fixture's skill table holds sids 0 to 2
    await refused(postedForm({ skills: pastEnd }), "invalid_payload", "record.skills[0].id");
    await refused(postedForm({ skills: pastEnd, module_version: "2027-01-01T00:00:00+0900" }), "server_tables_older", "record.skills[0].id");
  });

  test("a focus other than training or inheritance is refused, when sharing and when changing a share", async () => {
    await refused(postedForm(), "invalid_payload", "view.focus", { focus: "bogus" });

    // A share of its own Worker: the one above stays clean for the other refusals.
    const other = await startWorker();
    try {
      const token = await other.signIn();
      const [created] = await results(other, token, [share()]);
      assert.equal(created.status, "created");
      for (const view of [{ focus: "bogus" }, {}]) {
        const res = await answer(changeView(other, token, created.id, { view }));
        assert.equal(res.status, 400, JSON.stringify(view));
        assert.equal(res.body.error, "invalid_payload");
      }
      const [mine] = (await answer(other.myShares(token))).body;
      assert.deepEqual(mine.view, { focus: null });
    } finally {
      await other.dispose();
    }
  });

  test("a friend's record is refused", async () => {
    await refused(postedForm({ record_type: "FriendStandard" }), "invalid_payload", "record.record_type");
  });

  test("a request needs a session, 1 to MAX_SHARES_PER_REQUEST shares and a body within MAX_SHARE_BODY", async () => {
    const noSession = await answer(worker.share(newClientKey(), [share()]));
    assert.equal(noSession.status, 401);
    assert.equal(noSession.body.error, "session_required");

    for (const shares of [[], Array.from({ length: limits.MAX_SHARES_PER_REQUEST + 1 }, () => share())]) {
      const res = await answer(worker.share(token, shares));
      assert.equal(res.status, 400, `${shares.length} shares`);
      assert.deepEqual(res.body, { error: "invalid_payload", field: "shares" });
    }

    const text = JSON.stringify({ shares: [share()] });
    const padded = text + " ".repeat(limits.MAX_SHARE_BODY + 1 - text.length);
    const big = await answer(
      worker.fetch("/api/shares", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: padded,
      }),
    );
    assert.equal(big.status, 413);
    assert.equal(big.body.error, "payload_too_large");
    assert.equal(await worker.count("records"), 0);
  });
});

describe("share, list and unshare", () => {
  let worker;
  before(async () => {
    worker = await startWorker();
  });
  after(() => worker.dispose());

  test("a shared record is unshared only by its owner, and is gone afterwards", async () => {
    const mine = await worker.signIn("100000000000000000011");
    const theirs = await worker.signIn("100000000000000000012");
    const owner = await worker.accountOf(mine);
    const [shared] = await results(worker, mine, [share()]);
    assert.equal(shared.status, "created");
    const { id } = shared;
    assert.deepEqual(shared, { status: "created", id, url: `${ORIGIN}/r/${id}`, json_url: `${ORIGIN}/r/${id}.json` });
    assert.equal((await answer(worker.fetch(`/r/${id}.json`))).status, 200);
    const charge = await chargeOf(worker);
    assert.deepEqual(await worker.totals(), { bytes: charge, count: 1 });
    assert.equal((await worker.account(owner)).share_count, 1);

    const wrong = await answer(worker.unshare(theirs, id));
    assert.equal(wrong.status, 403);
    assert.equal(wrong.body.error, "forbidden");
    assert.equal(await worker.count("records"), 1, "another account removed the record");
    assert.equal((await answer(worker.fetch(`/r/${id}.json`))).status, 200);

    assert.equal((await answer(worker.unshare(mine, id))).status, 204);
    assert.equal((await answer(worker.fetch(`/r/${id}.json`))).status, 404);
    // The page of an unshared record is the one an id never shared, or not an id at all, gets.
    const [unshared, never, malformed] = await Promise.all(
      [`/r/${id}`, `/r/${id === "zzzzzzzzzz" ? "yyyyyyyyyy" : "zzzzzzzzzz"}`, "/r/NOT-AN-ID"].map((path) => answer(worker.fetch(path))),
    );
    assert.equal(unshared.status, 404);
    assert.match(unshared.headers.get("content-type"), /^text\/html/);
    assert.deepEqual([never.status, never.text], [404, unshared.text], "an unshared id is told from one never shared");
    assert.deepEqual([malformed.status, malformed.text], [404, unshared.text], "an unshared id is told from a malformed one");
    assert.deepEqual(await worker.totals(), { bytes: 0, count: 0 });
    assert.equal((await worker.account(owner)).share_count, 0);
    assert.equal((await answer(worker.unshare(mine, id))).status, 404);
    assert.equal((await answer(worker.unshare(newClientKey(), id))).status, 401);
  });

  test("a resend with the same client key answers existing with the same id and charges once", async () => {
    const token = await worker.signIn("100000000000000000013");
    const owner = await worker.accountOf(token);
    const resent = share();
    const [first] = await results(worker, token, [resent]);
    const [second] = await results(worker, token, [resent]);
    assert.equal(first.status, "created");
    assert.deepEqual(second, { ...first, status: "existing" });
    assert.equal((await worker.account(owner)).share_count, 1);
    assert.equal((await worker.unshare(token, first.id)).status, 204);
  });

  test("/api/me/shares lists the account's own records with client_key_hash as 64 lowercase hex digits, never the key", async () => {
    const token = await worker.signIn("100000000000000000014");
    const other = await worker.signIn("100000000000000000015");
    const kept = share();
    const [mine] = await results(worker, token, [kept]);
    await results(worker, other, [share()]);

    const res = await answer(worker.myShares(token));
    assert.equal(res.status, 200);
    assert.equal(res.text.includes(kept.client_key), false, "the raw client key was returned");
    const day = new Date().toISOString().slice(0, 10);
    assert.deepEqual(res.body, [
      {
        id: mine.id,
        url: `${ORIGIN}/r/${mine.id}`,
        shared_on: day,
        client_key_hash: secretHash(kept.client_key).toString("hex"),
        view: { focus: null },
        summary: {
          record_type: "standard",
          trainee: { card: { gid: 1004, name: "card <b>&\"'" }, character: { name: "chara 3" }, rank: { name: "rank 2" } },
          evaluation: 12345,
        },
      },
    ]);
    assert.match(res.body[0].client_key_hash, /^[0-9a-f]{64}$/);
    assert.equal((await answer(worker.myShares(newClientKey()))).status, 401);
  });
});

describe("several shares in one request", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());
  beforeEach(async () => {
    await worker.db.batch([
      worker.db.prepare("DELETE FROM records"),
      worker.db.prepare("UPDATE accounts SET share_count = 0, quota_day = 0, quota_bytes = 0"),
      worker.db.prepare("UPDATE totals SET bytes = 0, count = 0"),
      worker.db.prepare("DELETE FROM daily"),
    ]);
  });

  /** Measures the fixture form's charge with one share, then empties the account again. */
  async function measureCharge(token) {
    const [seed] = await results(worker, token, [share()]);
    const charge = await chargeOf(worker);
    assert.equal((await worker.unshare(token, seed.id)).status, 204);
    await worker.db.batch([
      worker.db.prepare("UPDATE accounts SET quota_bytes = 0"),
      worker.db.prepare("DELETE FROM daily"),
    ]);
    return charge;
  }

  test("a share the server's daily limit refuses leaves the rest of the request skipped", async () => {
    const token = await worker.signIn();
    const owner = await worker.accountOf(token);
    const charge = await measureCharge(token);
    // Room for 3 more shares today, server-wide.
    await worker.db
      .prepare("INSERT INTO daily (day, share_bytes) VALUES (?, ?)")
      .bind(await today(worker), limits.DAILY_LIMIT - 3 * charge - Math.floor(charge / 2))
      .run();

    const shares = Array.from({ length: limits.MAX_SHARES_PER_REQUEST }, () => share());
    const list = await results(worker, token, shares);
    assert.deepEqual(statuses(list), [
      "created",
      "created",
      "created",
      "refused daily_limit",
      ...Array(4).fill("skipped not_attempted"),
    ]);
    assert.equal(await worker.count("records"), 3);
    assert.deepEqual(await worker.account(owner), { share_count: 3, quota_day: await today(worker), quota_bytes: 3 * charge });

    // The skipped shares were not tried: sent again tomorrow, they are created, not found existing.
    await worker.advanceClock(86_400);
    assert.deepEqual(statuses(await results(worker, token, shares.slice(3, 5))), ["created", "created"]);
  });

  test("the account's daily limit refuses only its own share, and the request goes on", async () => {
    const token = await worker.signIn();
    const owner = await worker.accountOf(token);
    const charge = await measureCharge(token);
    // Room for 2 more shares of this account today.
    await worker.db
      .prepare("UPDATE accounts SET quota_day = ?, quota_bytes = ? WHERE id = ?")
      .bind(await today(worker), limits.ACCOUNT_DAILY_LIMIT - 2 * charge - Math.floor(charge / 2), owner)
      .run();

    const first = share();
    const list = await results(worker, token, [first, share(), share(), first, share(postedForm({ record_type: "FriendStandard" }))]);
    assert.deepEqual(statuses(list), [
      "created",
      "created",
      "refused account_limit",
      "existing",
      "refused invalid_payload",
    ]);
    assert.equal(list[3].id, list[0].id);
    assert.equal(await worker.count("records"), 2);

    // The account's day ends with the UTC day.
    await worker.advanceClock(86_400);
    assert.deepEqual(statuses(await results(worker, token, [share()])), ["created"]);
  });

  test("an account holding ACCOUNT_SHARE_CAP records is refused the next until it unshares one", async () => {
    const token = await worker.signIn();
    const owner = await worker.accountOf(token);
    await worker.db.prepare("UPDATE accounts SET share_count = ? WHERE id = ?").bind(limits.ACCOUNT_SHARE_CAP - 1, owner).run();

    const list = await results(worker, token, [share(), share()]);
    assert.deepEqual(statuses(list), ["created", "refused account_limit"]);
    assert.equal((await worker.account(owner)).share_count, limits.ACCOUNT_SHARE_CAP);

    assert.equal((await worker.unshare(token, list[0].id)).status, 204);
    assert.deepEqual(statuses(await results(worker, token, [share()])), ["created"]);
  });
});

describe("limits", () => {
  test("a change of a share's focus counts against the account's daily quota, and is refused once it is used up", async () => {
    const worker = await startWorker({ testEntry: true });
    try {
      const token = await worker.signIn();
      const owner = await worker.accountOf(token);
      const [created] = await results(worker, token, [share()]);
      const quota = (await worker.account(owner)).quota_bytes;

      assert.equal((await changeView(worker, token, created.id, { view: { focus: "inheritance" } })).status, 204);
      assert.equal((await worker.account(owner)).quota_bytes, quota + limits.ROW_CHARGE);

      await worker.db
        .prepare("UPDATE accounts SET quota_bytes = ? WHERE id = ?")
        .bind(limits.ACCOUNT_DAILY_LIMIT - limits.ROW_CHARGE + 1, owner)
        .run();
      const full = await answer(changeView(worker, token, created.id, { view: { focus: "training" } }));
      assert.deepEqual([full.status, full.body], [429, { error: "daily_limit", scope: "account" }]);
      const [mine] = (await answer(worker.myShares(token))).body;
      assert.deepEqual(mine.view, { focus: "inheritance" });
    } finally {
      await worker.dispose();
    }
  });

  test("a change of a share's focus counts against the server's daily limit, and is refused once it is used up", async () => {
    const worker = await startWorker({ testEntry: true });
    try {
      const token = await worker.signIn();
      const [created] = await results(worker, token, [share()]);
      const [{ share_bytes: shared }] = await worker.daily();

      assert.equal((await changeView(worker, token, created.id, { view: { focus: "inheritance" } })).status, 204);
      assert.deepEqual((await worker.daily()).map((d) => d.share_bytes), [shared + limits.ROW_CHARGE]);

      await worker.db
        .prepare("UPDATE daily SET share_bytes = ? WHERE day = ?")
        .bind(limits.DAILY_LIMIT - limits.ROW_CHARGE + 1, await today(worker))
        .run();
      const full = await answer(changeView(worker, token, created.id, { view: { focus: "training" } }));
      assert.deepEqual([full.status, full.body], [429, { error: "daily_limit", scope: "service" }]);
      const [mine] = (await answer(worker.myShares(token))).body;
      assert.deepEqual(mine.view, { focus: "inheritance" });
    } finally {
      await worker.dispose();
    }
  });

  test("the storage budget refuses with storage_full, charging nothing", async () => {
    const worker = await startWorker();
    try {
      const token = await worker.signIn();
      const owner = await worker.accountOf(token);
      assert.deepEqual(statuses(await results(worker, token, [share()])), ["created"]);
      const charge = await chargeOf(worker);
      const before = { account: await worker.account(owner), daily: await worker.daily() };
      await worker.db.prepare("UPDATE totals SET bytes = ?").bind(limits.STORAGE_BUDGET - charge + 1).run();

      assert.deepEqual(statuses(await results(worker, token, [share(), share()])), [
        "refused storage_full",
        "skipped not_attempted",
      ]);
      assert.equal(await worker.count("records"), 1);
      assert.deepEqual({ account: await worker.account(owner), daily: await worker.daily() }, before);
    } finally {
      await worker.dispose();
    }
  });

  test("a failure after the batch's first statement consumes none of the counters", async () => {
    const worker = await startWorker();
    try {
      const token = await worker.signIn();
      const owner = await worker.accountOf(token);
      const accountBefore = await worker.account(owner);
      const dailyBefore = await worker.daily();
      // The third statement (the totals update) fails after the record was inserted and the account
      // charged.
      await worker.db
        .prepare("CREATE TRIGGER fail_totals BEFORE UPDATE ON totals BEGIN SELECT RAISE(ABORT, 'injected'); END")
        .run();
      const kept = share();
      assert.deepEqual(statuses(await results(worker, token, [kept, share()])), [
        "refused temporarily_unavailable",
        "skipped not_attempted",
      ]);
      assert.equal(await worker.count("records"), 0);
      assert.deepEqual(await worker.account(owner), accountBefore);
      assert.deepEqual(await worker.totals(), { bytes: 0, count: 0 });
      assert.deepEqual(await worker.daily(), dailyBefore);

      // Nothing was left half-done: the same client key shares once the failure is gone.
      await worker.db.prepare("DROP TRIGGER fail_totals").run();
      assert.deepEqual(statuses(await results(worker, token, [kept])), ["created"]);
    } finally {
      await worker.dispose();
    }
  });

  test("a refused share whose candidate id is already taken changes nothing", async () => {
    const worker = await startWorker({ testEntry: true });
    try {
      const token = await worker.signIn();
      const owner = await worker.accountOf(token);
      const [seed] = await results(worker, token, [share()]);
      assert.equal(seed.status, "created");
      const charge = await chargeOf(worker);
      // No room for another record, and the next share draws the stored record's id first.
      await worker.db.prepare("UPDATE totals SET bytes = ?").bind(limits.STORAGE_BUDGET - charge + 1).run();
      const state = async () => ({ totals: await worker.totals(), daily: await worker.daily(), account: await worker.account(owner) });
      const before = await state();
      await worker.forcePublicIds([seed.id]);

      assert.deepEqual(statuses(await results(worker, token, [share()])), ["refused storage_full"]);
      assert.deepEqual(await worker.forcedPublicIdsLeft(), [], "the share did not draw the taken id");
      assert.deepEqual(await state(), before, "a refused share changed the counters");
      assert.equal(await worker.count("records"), 1);
    } finally {
      await worker.dispose();
    }
  });
});

describe("concurrent writes", () => {
  let worker;
  let token;
  let owner;
  before(async () => {
    worker = await startWorker({ testEntry: true });
    token = await worker.signIn();
    owner = await worker.accountOf(token);
  });
  after(() => worker.dispose());
  beforeEach(async () => {
    await worker.db.batch([
      worker.db.prepare("DELETE FROM records"),
      worker.db.prepare("UPDATE accounts SET share_count = 0, quota_day = 0, quota_bytes = 0"),
      worker.db.prepare("UPDATE totals SET bytes = 0, count = 0"),
      worker.db.prepare("DELETE FROM daily"),
    ]);
  });

  /** Sends `requests` with the batch gate armed for all of them, and checks they all reached it. */
  async function race(requests) {
    await worker.armGate(requests.length);
    const answers = await Promise.all(requests.map((send) => answer(send())));
    assert.deepEqual(await worker.gate(), { expected: requests.length, arrived: requests.length }, "the requests did not overlap");
    return answers;
  }

  /** The single result of each racing one-share request, sorted by status. */
  const sorted = (answers) =>
    answers
      .map((a) => {
        assert.equal(a.status, 200, JSON.stringify(a.body));
        return a.body.results[0];
      })
      .sort((a, b) => statuses([a])[0].localeCompare(statuses([b])[0]));

  test("two shares racing for the last of the budget commit one", async () => {
    const [seed] = await results(worker, token, [share()]);
    assert.equal(seed.status, "created");
    const charge = await chargeOf(worker);
    // Room for one more record, not two.
    const start = limits.STORAGE_BUDGET - charge - Math.floor(charge / 2);
    await worker.db.prepare("UPDATE totals SET bytes = ?").bind(start).run();

    const send = () => worker.share(token, [share()]);
    const [won, lost] = sorted(await race([send, send]));
    assert.deepEqual(statuses([won, lost]), ["created", "refused storage_full"]);
    assert.equal((await worker.totals()).bytes, start + charge);
    assert.equal(await worker.count("records"), 2);
    assert.equal((await worker.account(owner)).share_count, 2);
  });

  test("two shares racing for the account's last place commit one", async () => {
    await worker.db.prepare("UPDATE accounts SET share_count = ? WHERE id = ?").bind(limits.ACCOUNT_SHARE_CAP - 1, owner).run();
    const send = () => worker.share(token, [share()]);
    const [won, lost] = sorted(await race([send, send]));
    assert.deepEqual(statuses([won, lost]), ["created", "refused account_limit"]);
    assert.equal((await worker.account(owner)).share_count, limits.ACCOUNT_SHARE_CAP);
    assert.equal(await worker.count("records"), 1);
  });

  test("concurrent resends with one client key converge on one id even when the first takes the account's last place", async () => {
    await worker.db.prepare("UPDATE accounts SET share_count = ? WHERE id = ?").bind(limits.ACCOUNT_SHARE_CAP - 1, owner).run();
    const resent = share();
    const send = () => worker.share(token, [resent]);
    const [first, second] = sorted(await race([send, send]));
    assert.deepEqual(statuses([first, second]), ["created", "existing"]);
    assert.equal(second.id, first.id);
    assert.equal(await worker.count("records"), 1);
  });

  test("two concurrent unshares by the owner give the charge back once", async () => {
    const [shared] = await results(worker, token, [share()]);
    const charge = await chargeOf(worker);
    const before = await worker.totals();

    const unshare = () => worker.unshare(token, shared.id);
    const codes = (await race([unshare, unshare])).map((a) => a.status).sort();
    assert.deepEqual(codes, [204, 404]);
    assert.deepEqual(await worker.totals(), { bytes: before.bytes - charge, count: before.count - 1 });
    assert.equal((await worker.account(owner)).share_count, 0);
  });
});

describe("sharing switch", () => {
  test('SHARING_ENABLED "false" refuses the login begin and shares, and lets reading, changing the focus of a share, unsharing and logging out through', async () => {
    const worker = await startWorker({ vars: { SHARING_ENABLED: "false" } });
    try {
      // A session and a record from before the switch, stored directly: this Worker cannot make them.
      const token = newClientKey() + newClientKey().slice(0, 21);
      const owner = "0123456789abcdef";
      await worker.db.batch([
        worker.db.prepare("INSERT INTO accounts (id, created_day, share_count) VALUES (?, 0, 1)").bind(owner),
        worker.db.prepare("INSERT INTO sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)").bind(secretHash(token), owner, 2 ** 40),
      ]);
      await worker.insertRecord("0123456789", postedForm());
      await worker.db.prepare("UPDATE records SET owner_id = ?").bind(owner).run();

      const begin = await worker.begin({ h: newLoginHash() });
      assert.equal(begin.status, 503);
      assert.ok((await begin.text()).includes('data-error="sharing_paused"'));
      assert.equal(await worker.count("logins"), 0);
      assert.equal(worker.siteverify.calls.length, 0);

      const shared = await answer(worker.share(token, [share()]));
      assert.equal(shared.status, 503);
      assert.equal(shared.body.error, "sharing_paused");
      assert.equal(await worker.count("records"), 1);

      assert.equal((await answer(worker.fetch("/r/0123456789.json"))).status, 200);
      assert.equal((await answer(worker.myShares(token))).status, 200);
      assert.equal((await changeView(worker, token, "0123456789", { view: { focus: "inheritance" } })).status, 204);
      assert.equal((await answer(worker.unshare(token, "0123456789"))).status, 204);
      assert.equal((await answer(worker.logout(token))).status, 204);
    } finally {
      await worker.dispose();
    }
  });
});

describe("the session's account", () => {
  let worker;
  before(async () => {
    worker = await startWorker();
  });
  after(() => worker.dispose());

  const me = (token) => answer(worker.fetch("/api/me", { headers: { Authorization: `Bearer ${token}` } }));
  const trainer = (token, body) =>
    answer(
      worker.fetch("/api/me/trainers", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify(body),
      }),
    );
  const uuid = (n) => `00000000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
  const trainerRows = (account) =>
    worker.db
      .prepare("SELECT count(*) AS n FROM account_trainers WHERE account_id = ?")
      .bind(account)
      .first()
      .then((r) => r.n);

  test("/api/me counts the account's shares and what remains, following shares and unshares", async () => {
    const token = await worker.signIn("100000000000000000031");
    const owner = await worker.accountOf(token);
    const first = await me(token);
    assert.equal(first.status, 200);
    assert.deepEqual(first.body, {
      account_id: owner,
      list_url: `${ORIGIN}/u/${owner}`,
      share_count: 0,
      shares_remaining: limits.ACCOUNT_SHARE_CAP,
      trainer_ids: [],
      deleting: false,
    });
    const [a, b] = await results(worker, token, [share(), share()]);
    assert.deepEqual(
      [(await me(token)).body.share_count, (await me(token)).body.shares_remaining],
      [2, limits.ACCOUNT_SHARE_CAP - 2],
    );
    assert.equal((await worker.unshare(token, a.id)).status, 204);
    const after = (await me(token)).body;
    assert.deepEqual([after.share_count, after.shares_remaining], [1, limits.ACCOUNT_SHARE_CAP - 1]);
    assert.ok(b.id);
    assert.equal((await me(newClientKey())).status, 401);
  });

  test("trainers: a UUID registers once, a malformed one is 400, and the account's ACCOUNT_TRAINERS_CAP + 1st is 409 trainer_limit", async () => {
    const token = await worker.signIn("100000000000000000032");
    const owner = await worker.accountOf(token);
    for (const bad of [{ trainer_id: "not-a-uuid" }, { trainer_id: uuid(0xabc).toUpperCase() }, { trainer_id: 1 }, {}]) {
      const res = await trainer(token, bad);
      assert.equal(res.status, 400, JSON.stringify(bad));
      assert.equal(res.body.error, "invalid_payload");
    }
    assert.equal(await trainerRows(owner), 0);

    assert.equal((await trainer(token, { trainer_id: uuid(1) })).status, 200);
    assert.equal((await trainer(token, { trainer_id: uuid(1) })).status, 200, "a re-registration is refused");
    assert.equal(await trainerRows(owner), 1, "a re-registration added a row");
    for (let n = 2; n <= limits.ACCOUNT_TRAINERS_CAP; n++) {
      assert.equal((await trainer(token, { trainer_id: uuid(n) })).status, 200, `trainer ${n}`);
    }
    assert.equal(await trainerRows(owner), limits.ACCOUNT_TRAINERS_CAP);
    const over = await trainer(token, { trainer_id: uuid(limits.ACCOUNT_TRAINERS_CAP + 1) });
    assert.equal(over.status, 409);
    assert.equal(over.body.error, "trainer_limit");
    assert.equal(await trainerRows(owner), limits.ACCOUNT_TRAINERS_CAP);
    // At the cap, one already registered is still answered as registered.
    assert.equal((await trainer(token, { trainer_id: uuid(1) })).status, 200);
    assert.deepEqual(
      (await me(token)).body.trainer_ids,
      Array.from({ length: limits.ACCOUNT_TRAINERS_CAP }, (_, i) => uuid(i + 1)),
    );
    // The cap is the account's: another account still registers.
    const other = await worker.signIn("100000000000000000033");
    assert.equal((await trainer(other, { trainer_id: uuid(1) })).status, 200);
    assert.equal((await trainer(newClientKey(), { trainer_id: uuid(99) })).status, 401);
  });
});
