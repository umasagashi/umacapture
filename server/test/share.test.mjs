// Sharing under an account (POST /api/shares, DELETE /api/shares/<id>, GET /api/me/shares) and the
// sharing switch, driven over HTTP against a real (local) D1 with sessions claimed through the login.
//
// The concurrency cases run through the batch gate (see worker_harness.mjs): every racing request
// has finished its reads before any batch runs, so they exercise the interleaving the judgement of
// a share is written for. Local D1 serialises the batches the way production D1 is documented to;
// whether production does is checked on the staging D1, not here.

import { after, before, beforeEach, describe, test } from "node:test";
import { createHash } from "node:crypto";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import {
  appendTables,
  FIXTURE_TABLES,
  imageBundle,
  newClientKey,
  newLoginHash,
  ORIGIN,
  postedForm,
  secretHash,
  startWorker,
} from "./support/worker_harness.mjs";

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

  /** Shares `record` and asserts that share alone was refused, storing and charging nothing. */
  async function refused(record, error, field) {
    const [result] = await results(worker, token, [share(record)]);
    assert.deepEqual(result, field === undefined ? { status: "refused", error } : { status: "refused", error, field });
    assert.equal(await worker.count("records"), 0);
    assert.deepEqual(await worker.account(owner), { share_count: 0, quota_day: 0, quota_bytes: 0 });
  }

  test("an unknown key is refused at any depth", async () => {
    await refused({ ...postedForm(), trainer_id: "123456789" }, "invalid_payload", "record.trainer_id");
    await refused(postedForm({ trainee: { character: 3, card: 3, rank: 2, name: "x" } }), "invalid_payload", "record.trainee.name");
  });

  test("icons, parents' ranks and parents' record types out of range are refused", async () => {
    const parent = (self) => ({ parent1: { ...postedForm().family.parent1, self }, parent2: postedForm().family.parent2 });
    await refused(postedForm({ trainee: { character: 3, card: 3, rank: 2, icon: 65_536 } }), "invalid_payload", "record.trainee.icon");
    await refused(postedForm({ family: parent({ character: 1, card: 1, icon: -1 }) }), "invalid_payload", "record.family.parent1.self.icon");
    await refused(postedForm({ family: parent({ character: 1, card: 1, rank: 99 }) }), "invalid_payload", "record.family.parent1.self.rank");
    await refused(postedForm({ family: parent({ character: 1, card: 1, record_type: "Friend" }) }), "invalid_payload", "record.family.parent1.self.record_type");
  });

  test("a sid past the end of a table is refused, as server_tables_older when the client's modules are newer", async () => {
    const pastEnd = [{ id: 3 }]; // the fixture's skill table holds sids 0 to 2
    await refused(postedForm({ skills: pastEnd }), "invalid_payload", "record.skills[0].id");
    await refused(postedForm({ skills: pastEnd, module_version: "2027-01-01T00:00:00+0900" }), "server_tables_older", "record.skills[0].id");
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
    assert.deepEqual(shared, { status: "created", id, url: `${ORIGIN}/r/${id}`, json_url: `${ORIGIN}/r/${id}.json`, images: "none" });
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

  test("/api/shares/<id> returns the stored form with its sids and without module_version, with no session, until unshared", async () => {
    const token = await worker.signIn("100000000000000000014");
    const c = (character, card, rank, icon, recordType) => ({ character, card, rank, icon, record_type: recordType });
    const record = postedForm({
      trainee: { character: 3, card: 3, rank: 2, icon: 876 },
      family: {
        parent1: { self: c(1, 1, 1, 10, "FriendStandard"), parent1: c(0, 0, 0, 0, "Standard"), parent2: c(2, 2, 2, 65_535, "InheritanceOnly"), rental: true },
        // A parent read without a record type carries none.
        parent2: { self: { character: 2, card: 2, rank: 0, icon: 7 }, parent1: c(0, 0, 1, 1, "FriendInheritance"), parent2: c(1, 1, 2, 2, "Standard") },
      },
    });
    const [plain, extended] = await results(worker, token, [share(), share(record)]);
    const { module_version: _, ...expected } = record;
    const got = await answer(worker.fetch(`/api/shares/${extended.id}`));
    assert.equal(got.status, 200);
    assert.equal(got.headers.get("cache-control"), "no-store");
    assert.equal(got.headers.get("access-control-allow-origin"), null);
    const today = got.body.shared_on;
    assert.match(today, /^\d{4}-\d{2}-\d{2}$/);
    assert.deepEqual(got.body, { schema: 1, id: extended.id, shared_on: today, record: expected, images: null });

    // A share posted without the new keys is returned as stored, without them.
    const { module_version: __, ...old } = postedForm();
    assert.deepEqual((await answer(worker.fetch(`/api/shares/${plain.id}`))).body.record, old);

    // The new keys publish nothing on the public JSON: it is the same as that of the share without them.
    const publicOf = async (id) => {
      const { id: _id, url: _url, ...rest } = (await answer(worker.fetch(`/r/${id}.json`))).body;
      return rest;
    };
    assert.deepEqual(await publicOf(extended.id), await publicOf(plain.id));

    for (const { id } of [extended, plain]) assert.equal((await worker.unshare(token, id)).status, 204);
    const unshared = await answer(worker.fetch(`/api/shares/${extended.id}`));
    assert.deepEqual([unshared.status, unshared.body], [404, { error: "not_found" }]);
    const never = extended.id === "zzzzzzzzzz" || plain.id === "zzzzzzzzzz" ? "yyyyyyyyyy" : "zzzzzzzzzz";
    const missing = await answer(worker.fetch(`/api/shares/${never}`));
    assert.deepEqual([missing.status, missing.body], [404, { error: "not_found" }]);
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
        summary: {
          record_type: "standard",
          trainee: { card: { gid: 1004, name: "card <b>&\"'" }, character: { name: "chara 3" }, rank: { name: "rank 2" } },
          evaluation: 12345,
        },
        images: "none",
        tagline: null,
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
  test('SHARING_ENABLED "false" refuses the login begin, shares and new public text, and lets reading, removing or keeping text, unsharing and logging out through', async () => {
    const worker = await startWorker({ vars: { SHARING_ENABLED: "false" } });
    try {
      // A session and a record from before the switch, stored directly: this Worker cannot make them.
      const token = newClientKey() + newClientKey().slice(0, 21);
      const owner = "0123456789abcdef";
      await worker.db.batch([
        worker.db
          .prepare("INSERT INTO accounts (id, created_day, share_count, trainer_name, game_trainer_id) VALUES (?, 0, 1, 'name', '123456789')")
          .bind(owner),
        worker.db.prepare("INSERT INTO sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)").bind(secretHash(token), owner, 2 ** 40),
      ]);
      await worker.insertRecord("0123456789", postedForm());
      await worker.db.prepare("UPDATE records SET owner_id = ?, tagline = 'old'").bind(owner).run();

      const begin = await worker.begin({ h: newLoginHash() });
      assert.equal(begin.status, 503);
      assert.ok((await begin.text()).includes('data-error="sharing_paused"'));
      assert.equal(await worker.count("logins"), 0);
      assert.equal(worker.siteverify.calls.length, 0);

      const shared = await answer(worker.share(token, [share()]));
      assert.equal(shared.status, 503);
      assert.equal(shared.body.error, "sharing_paused");
      assert.equal(await worker.count("records"), 1);

      // A tagline or a profile publishing new text is refused; removing either, or leaving it, goes through.
      const stored = async () => [
        (await worker.db.prepare("SELECT tagline FROM records").first()).tagline,
        await worker.db.prepare("SELECT trainer_name, game_trainer_id FROM accounts WHERE id = ?").bind(owner).first(),
      ];
      const profile = { trainer_name: "name", game_trainer_id: "123456789" };

      for (const res of [
        await answer(worker.putTagline(token, "0123456789", { tagline: "new", previous: "old" })),
        await answer(worker.putProfile(token, { trainer_name: "new", game_trainer_id: null, previous: profile })),
      ]) {
        assert.deepEqual([res.status, res.body], [503, { error: "sharing_paused" }]);
      }
      assert.deepEqual(await stored(), ["old", profile]);

      assert.equal((await answer(worker.putTagline(token, "0123456789", { tagline: "old", previous: "old" }))).status, 200);
      assert.equal((await answer(worker.putTagline(token, "0123456789", { tagline: null, previous: "old" }))).status, 200);
      const kept = await answer(worker.putProfile(token, { trainer_name: null, game_trainer_id: "123 456 789", previous: profile }));
      assert.deepEqual([kept.status, kept.body], [200, { trainer_name: null, game_trainer_id: "123456789" }]);
      assert.deepEqual(await stored(), [null, { trainer_name: null, game_trainer_id: "123456789" }]);
      assert.equal((await answer(worker.fetch("/r/0123456789.json"))).body.tagline, null);

      assert.equal((await answer(worker.fetch("/r/0123456789.json"))).status, 200);
      assert.equal((await answer(worker.myShares(token))).status, 200);
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
      profile: { trainer_name: null, game_trainer_id: null },
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

  const NONE = { trainer_name: null, game_trainer_id: null };
  const cp = (...points) => String.fromCodePoint(...points);
  const putProfile = (token, body) => answer(worker.putProfile(token, body));
  const putTagline = (token, id, body) => answer(worker.putTagline(token, id, body));
  const page = async (path) => (await answer(worker.fetch(path))).text;
  const publicJson = async (path) => (await answer(worker.fetch(path))).body;
  const ogDescription = (html) => /<meta property="og:description" content="([^"]*)">/.exec(html)?.[1] ?? null;
  const bytes = (text) => new TextEncoder().encode(text).byteLength;
  const chargeOfShare = async (id) => (await worker.db.prepare("SELECT charge FROM records WHERE id = ?").bind(id).first()).charge;

  test("a profile is stored in its canonical form, shown on every page of the account's shares and on its list, and a malformed one is refused", async () => {
    const token = await worker.signIn("100000000000000000041");
    const owner = await worker.accountOf(token);
    const [first, second] = await results(worker, token, [share(), share()]);
    assert.deepEqual((await me(token)).body.profile, NONE);

    const refused = [
      [{ trainer_name: 1, game_trainer_id: null, previous: NONE }, "trainer_name"],
      [{ trainer_name: `a${cp(0x202e)}b`, game_trainer_id: null, previous: NONE }, "trainer_name"],
      [{ trainer_name: `a${cp(10)}b`, game_trainer_id: null, previous: NONE }, "trainer_name"],
      [{ trainer_name: cp(0xd800), game_trainer_id: null, previous: NONE }, "trainer_name"],
      [{ trainer_name: "x".repeat(21), game_trainer_id: null, previous: NONE }, "trainer_name"],
      [{ trainer_name: null, game_trainer_id: "12345678", previous: NONE }, "game_trainer_id"],
      [{ trainer_name: null, game_trainer_id: "1234567890", previous: NONE }, "game_trainer_id"],
      [{ trainer_name: null, game_trainer_id: "12345678a", previous: NONE }, "game_trainer_id"],
      [{ trainer_name: null, game_trainer_id: null }, "previous"],
      [{ trainer_name: null, game_trainer_id: null, previous: { trainer_name: null } }, "previous.game_trainer_id"],
    ];
    for (const [body, field] of refused) {
      const res = await putProfile(token, body);
      assert.deepEqual([res.status, res.body], [400, { error: "invalid_payload", field }], JSON.stringify(body));
    }
    assert.deepEqual((await me(token)).body.profile, NONE, "a refused profile was stored");

    // NFC and trimmed; the emoji's zero-width joiner passes; the id loses its separators.
    const name = `<s>&"'${cp(0x65)}${cp(0x301)}${cp(0x1f469, 0x200d, 0x1f4bb)}`;
    const canonical = `<s>&"'${cp(0xe9)}${cp(0x1f469, 0x200d, 0x1f4bb)}`;
    const written = await putProfile(token, { trainer_name: ` ${name}${cp(10)}`, game_trainer_id: "123 456 789", previous: NONE });
    assert.deepEqual([written.status, written.body], [200, { trainer_name: canonical, game_trainer_id: "123456789" }]);
    const profile = { trainer_name: canonical, game_trainer_id: "123456789" };
    assert.deepEqual((await me(token)).body.profile, profile);

    // Every page of the account's shares and its list show it; the description, the card and the import do not.
    for (const { id } of [first, second]) {
      assert.deepEqual((await publicJson(`/r/${id}.json`)).sharer, profile);
      const html = await page(`/r/${id}`);
      assert.ok(html.includes("&lt;s&gt;&amp;&quot;&#39;"), "the name is not escaped on the page");
      assert.equal(html.includes("<s>"), false, "the name reached the page as markup");
      assert.ok(html.includes("ID 123 456 789"), "the id is not grouped by three");
      assert.equal(ogDescription(html).includes("&lt;s&gt;"), false, "the description carries the profile");
      assert.deepEqual(Object.keys((await answer(worker.fetch(`/api/shares/${id}`))).body).sort(), ["id", "images", "record", "schema", "shared_on"]);
    }
    assert.deepEqual((await publicJson(`/u/${owner}.json`)).sharer, profile);
    assert.ok((await page(`/u/${owner}`)).includes("ID 123 456 789"));

    // Both pages carry the id's copy button with the bare digits, and the CSP lets the page's one
    // script, the one that shows the button and copies, run by its hash.
    for (const path of [`/r/${first.id}`, `/u/${owner}`]) {
      const res = await worker.fetch(path);
      const html = await res.text();
      assert.ok(html.includes('data-copy="123456789"'), `${path}: no copy button with the bare digits`);
      const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
      assert.equal(scripts.length, 1, `${path}: not exactly one script`);
      const hash = createHash("sha256").update(scripts[0]).digest("base64");
      const csp = res.headers.get("Content-Security-Policy");
      assert.ok(csp.includes(`script-src 'sha256-${hash}'`), `${path}: the CSP does not let the page's script run: ${csp}`);
      assert.equal(csp.includes("unsafe-inline"), false);
      // A refused copy tells the viewer and does not offer the refused button again.
      assert.ok(
        /catch \{\s*b\.textContent = "コピーできませんでした";\s*b\.disabled = true;/.test(scripts[0]),
        `${path}: a refused copy is not shown`,
      );
    }

    // Written from a profile changed since: nothing is written, and the answer carries what it is.
    const stale = await putProfile(token, { trainer_name: "other", game_trainer_id: null, previous: NONE });
    assert.deepEqual([stale.status, stale.body], [409, { error: "changed", profile }]);

    const twelve = await putProfile(token, { trainer_name: null, game_trainer_id: "1234-5678-9012", previous: profile });
    assert.deepEqual(twelve.body, { trainer_name: null, game_trainer_id: "123456789012" });
    assert.ok((await page(`/r/${first.id}`)).includes("ID 123 456 789 012"));
    assert.ok((await page(`/r/${first.id}`)).includes('data-copy="123456789012"'));

    // A name with no id: no copy button.
    const named = await putProfile(token, { trainer_name: "name", game_trainer_id: null, previous: twelve.body });
    assert.deepEqual(named.body, { trainer_name: "name", game_trainer_id: null });
    for (const path of [`/r/${first.id}`, `/u/${owner}`]) {
      const html = await page(path);
      assert.ok(html.includes("name"), path);
      assert.equal(html.includes("data-copy="), false, `${path}: a copy button with no id`);
      assert.equal(html.includes("<script"), false, `${path}: a script with no button`);
    }

    const removed = await putProfile(token, { trainer_name: null, game_trainer_id: "  ", previous: named.body });
    assert.deepEqual([removed.status, removed.body], [200, NONE]);
    assert.equal((await publicJson(`/r/${first.id}.json`)).sharer, null);
    assert.equal((await publicJson(`/u/${owner}.json`)).sharer, null);
    assert.equal((await page(`/r/${first.id}`)).includes("rec-sharer"), false);
    assert.equal((await putProfile(newClientKey(), { ...NONE, previous: NONE })).status, 401);
  });

  test("a tagline is written by its share's owner only, from the value it replaces, shown on the share's page and its row of the list, and charged with the share", async () => {
    const token = await worker.signIn("100000000000000000042");
    const other = await worker.signIn("100000000000000000043");
    const owner = await worker.accountOf(token);
    const [mine, plain] = await results(worker, token, [share(), share()]);
    const start = { charge: await chargeOfShare(mine.id), totals: (await worker.totals()).bytes };

    const theirs = await putTagline(other, mine.id, { tagline: "x", previous: null });
    assert.deepEqual([theirs.status, theirs.body], [403, { error: "forbidden" }]);
    const missing = await putTagline(token, mine.id === "zzzzzzzzzz" ? "yyyyyyyyyy" : "zzzzzzzzzz", { tagline: "x", previous: null });
    assert.deepEqual([missing.status, missing.body], [404, { error: "not_found" }]);
    for (const [body, field] of [
      [{ tagline: `a${cp(10)}b`, previous: null }, "tagline"],
      [{ tagline: "x".repeat(81), previous: null }, "tagline"],
      [{ tagline: `a${cp(0xe000)}`, previous: null }, "tagline"],
      [{ tagline: "x", previous: 1 }, "previous"],
      [{ tagline: "x" }, "previous"],
    ]) {
      const res = await putTagline(token, mine.id, body);
      assert.deepEqual([res.status, res.body], [400, { error: "invalid_payload", field }], JSON.stringify(body));
    }

    const text = `${cp(0x1f600).repeat(70)}<b>&"x`;
    const written = await putTagline(token, mine.id, { tagline: `${text}${cp(10)}`, previous: null });
    assert.deepEqual([written.status, written.body], [200, { tagline: text }]);
    assert.equal(await chargeOfShare(mine.id), start.charge + bytes(text));
    assert.equal((await worker.totals()).bytes, start.totals + bytes(text));

    const listed = (await answer(worker.myShares(token))).body;
    assert.deepEqual(listed.map((s) => [s.id, s.tagline]).sort(), [[mine.id, text], [plain.id, null]].sort());
    assert.equal((await publicJson(`/r/${mine.id}.json`)).tagline, text);
    assert.equal((await publicJson(`/r/${plain.id}.json`)).tagline, null);
    const list = await publicJson(`/u/${owner}.json`);
    assert.deepEqual(list.records.map((r) => [r.id, r.tagline]).sort(), [[mine.id, text], [plain.id, null]].sort());
    for (const html of [await page(`/r/${mine.id}`), await page(`/u/${owner}`)]) {
      assert.ok(html.includes("&lt;b&gt;&amp;&quot;x"), "the tagline is not escaped");
      assert.equal(html.includes("<b>"), false, "the tagline reached the page as markup");
    }
    assert.equal(ogDescription(await page(`/r/${mine.id}`)).includes("&lt;b&gt;"), false, "the description carries the tagline");
    assert.equal("tagline" in (await answer(worker.fetch(`/api/shares/${mine.id}`))).body, false, "the import carries the tagline");

    // Written from a tagline changed since: nothing is written.
    const stale = await putTagline(token, mine.id, { tagline: "y", previous: null });
    assert.deepEqual([stale.status, stale.body], [409, { error: "changed", tagline: text }]);
    assert.equal(await chargeOfShare(mine.id), start.charge + bytes(text));

    // A tagline that would grow past the budget is refused; one that shrinks is not.
    const { bytes: held } = await worker.totals();
    await worker.db.prepare("UPDATE totals SET bytes = ? WHERE id = 1").bind(limits.STORAGE_BUDGET).run();
    const full = await putTagline(token, plain.id, { tagline: "z", previous: null });
    assert.deepEqual([full.status, full.body], [409, { error: "storage_full" }]);
    assert.equal((await putTagline(token, mine.id, { tagline: null, previous: text })).status, 200);
    assert.equal((await worker.totals()).bytes, limits.STORAGE_BUDGET - bytes(text));
    await worker.db.prepare("UPDATE totals SET bytes = ? WHERE id = 1").bind(held - bytes(text)).run();
    assert.equal(await chargeOfShare(mine.id), start.charge);
    assert.equal((await publicJson(`/r/${mine.id}.json`)).tagline, null);
    assert.equal((await page(`/r/${mine.id}`)).includes("rec-tagline"), false);

    // An unshare gives the tagline's bytes back with the rest of the charge.
    assert.equal((await putTagline(token, plain.id, { tagline: "abc", previous: null })).status, 200);
    const before = (await worker.totals()).bytes;
    const charge = await chargeOfShare(plain.id);
    assert.equal((await worker.unshare(token, plain.id)).status, 204);
    assert.equal((await worker.totals()).bytes, before - charge);
    assert.equal((await putTagline(newClientKey(), mine.id, { tagline: null, previous: null })).status, 401);
  });
});

describe("daily text writes", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  const NONE = { trainer_name: null, game_trainer_id: null };
  const me = (token) => answer(worker.fetch("/api/me", { headers: { Authorization: `Bearer ${token}` } }));
  const putProfile = (token, body) => answer(worker.putProfile(token, body));
  const putTagline = (token, id, body) => answer(worker.putTagline(token, id, body));
  const publicJson = async (path) => (await answer(worker.fetch(path))).body;

  test("taglines and profiles count together against the account's and the service's daily text writes, a refused write counting nothing", async () => {
    const token = await worker.signIn("100000000000000000044");
    const owner = await worker.accountOf(token);
    const [mine] = await results(worker, token, [share()]);
    const day = await today(worker);
    const counts = async () => ({
      account: (await worker.db.prepare("SELECT text_writes FROM accounts WHERE id = ? AND text_writes_day = ?").bind(owner, day).first())?.text_writes ?? 0,
      service: (await worker.db.prepare("SELECT text_writes FROM daily WHERE day = ?").bind(day).first())?.text_writes ?? 0,
    });
    const refusedFor = (res, scope) => {
      assert.deepEqual([res.status, res.body], [429, { error: "daily_limit", scope }]);
      assert.ok(Number(res.headers.get("retry-after")) > 0);
    };

    const start = await counts();
    assert.equal((await putTagline(token, mine.id, { tagline: "a", previous: null })).status, 200);
    assert.equal((await putProfile(token, { trainer_name: "n", game_trainer_id: null, previous: NONE })).status, 200);
    assert.deepEqual(await counts(), { account: start.account + 2, service: start.service + 2 });
    // Written from a value changed since: refused, and counted against neither limit.
    assert.equal((await putTagline(token, mine.id, { tagline: "b", previous: null })).status, 409);
    assert.equal((await putProfile(token, { ...NONE, previous: NONE })).status, 409);
    assert.deepEqual(await counts(), { account: start.account + 2, service: start.service + 2 });

    // The account's last write of the day goes through; the next of either kind is refused, writing nothing.
    const profile = { trainer_name: "n", game_trainer_id: null };
    await worker.db
      .prepare("UPDATE accounts SET text_writes = ? WHERE id = ?")
      .bind(limits.ACCOUNT_TEXT_WRITES_PER_DAY - 1, owner)
      .run();
    assert.equal((await putTagline(token, mine.id, { tagline: "c", previous: "a" })).status, 200);
    refusedFor(await putTagline(token, mine.id, { tagline: "d", previous: "c" }), "account");
    refusedFor(await putProfile(token, { trainer_name: "m", game_trainer_id: null, previous: profile }), "account");
    assert.equal((await publicJson(`/r/${mine.id}.json`)).tagline, "c");
    assert.deepEqual((await me(token)).body.profile, profile);
    // A write from a stale value is still told what the value is, not the limit.
    const stale = await putTagline(token, mine.id, { tagline: "d", previous: "a" });
    assert.deepEqual([stale.status, stale.body], [409, { error: "changed", tagline: "c" }]);
    assert.equal((await counts()).account, limits.ACCOUNT_TEXT_WRITES_PER_DAY);

    // Past the limit, a write that clears one profile field and changes the other is refused like any write.
    const named = { trainer_name: "n", game_trainer_id: "123456789" };
    await worker.db.prepare("UPDATE accounts SET game_trainer_id = '123456789' WHERE id = ?").bind(owner).run();
    refusedFor(await putProfile(token, { trainer_name: null, game_trainer_id: "987654321", previous: named }), "account");
    assert.deepEqual((await me(token)).body.profile, named);
    // Past the limit, text can still be taken down, and taking it down counts nothing.
    const atLimit = await counts();
    assert.equal((await putProfile(token, { trainer_name: null, game_trainer_id: "123456789", previous: named })).status, 200);
    assert.equal((await putProfile(token, { ...NONE, previous: { trainer_name: null, game_trainer_id: "123456789" } })).status, 200);
    assert.deepEqual((await me(token)).body.profile, NONE);
    assert.equal((await putTagline(token, mine.id, { tagline: null, previous: "c" })).status, 200);
    assert.equal((await publicJson(`/r/${mine.id}.json`)).tagline, null);
    assert.deepEqual(await counts(), atLimit);
    // Clearing what is already clear is a write, refused past the limit.
    refusedFor(await putProfile(token, { ...NONE, previous: NONE }), "account");

    // Every account together: another account is refused once the day's writes are used up.
    const other = await worker.signIn("100000000000000000045");
    await worker.db.prepare("UPDATE daily SET text_writes = ? WHERE day = ?").bind(limits.TEXT_WRITES_PER_DAY, day).run();
    refusedFor(await putProfile(other, { trainer_name: "o", game_trainer_id: null, previous: NONE }), "service");

    // The next UTC day starts both counts again.
    await worker.advanceClock(86_400);
    assert.equal((await putTagline(token, mine.id, { tagline: "d", previous: null })).status, 200);
    assert.equal((await putProfile(other, { trainer_name: "o", game_trainer_id: null, previous: NONE })).status, 200);
  });
});

describe("name tables loaded into D1 after the Worker started", () => {
  let worker;
  let token;
  before(async () => {
    worker = await startWorker({ testEntry: true });
    token = await worker.signIn();
  });
  after(() => worker.dispose());

  /** FIXTURE_TABLES with the skill table grown to `size` entries (gids 2001 onwards), at `version`. */
  const grown = (size, version) => ({
    version,
    names: { ...FIXTURE_TABLES.names, "skill.name": Array.from({ length: size }, (_, i) => `skill ${i}`) },
    gids: { ...FIXTURE_TABLES.gids, "skill.name": Array.from({ length: size }, (_, i) => 2001 + i) },
  });

  test("a stored name is never changed or deleted, and a key's names are added only at its end", async () => {
    const { db } = worker;
    for (const [sql, args, message] of [
      ["UPDATE share_table_name SET name = 'x' WHERE key = 'skill.name' AND pos = 0", [], /never changed/],
      ["DELETE FROM share_table_name WHERE key = 'skill.name' AND pos = 2", [], /never deleted/],
      ["UPDATE share_table_gid SET gid = 1 WHERE key = 'skill.name' AND pos = 0", [], /never changed/],
      ["DELETE FROM share_table_gid WHERE key = 'skill.name'", [], /never deleted/],
      ["INSERT INTO share_table_name (key, pos, name) VALUES (?, ?, ?)", ["skill.name", 4, "gap"], /added at the end/],
      ["INSERT INTO share_table_name (key, pos, name) VALUES (?, ?, ?)", ["new.key", 1, "gap"], /added at the end/],
      ["INSERT INTO share_table_gid (key, pos, gid) VALUES (?, ?, ?)", ["skill.name", 5, 9], /added at the end/],
    ]) {
      await assert.rejects(db.prepare(sql).bind(...args).run(), message, sql);
    }
    // A batch that fails part way commits none of its rows.
    const add = (pos) => db.prepare("INSERT INTO share_table_name (key, pos, name) VALUES ('skill.name', ?, 'x')").bind(pos);
    await assert.rejects(db.batch([add(3), add(5)]), /added at the end/);
    const { names } = await db.prepare("SELECT COUNT(*) AS names FROM share_table_name WHERE key = 'skill.name'").first();
    assert.equal(names, 3);
  });

  test("a sid D1 gained after the Worker read its tables is shared and published, under the latest version", async () => {
    // The Worker reads its tables (generation 1, skills 0 to 2) and keeps them.
    assert.equal((await results(worker, token, [share()]))[0].status, "created");

    // A module set adds skill 3: a stored record naming it is published.
    assert.equal(await appendTables(worker.db, grown(4, "2026-02-01T00:00:00Z")), 2);
    await worker.insertRecord("0123456789", postedForm({ skills: [{ id: 3 }] }));
    const page = await worker.fetch("/r/0123456789.json");
    assert.equal(page.status, 200);
    const json = await page.json();
    assert.deepEqual(json.skills, [{ gid: 2004, name: "skill 3" }]);
    assert.equal(json.tables_version, "2026-02-01T00:00:00Z");

    // Another adds skill 4: a share naming it is stored, and its page names it.
    await appendTables(worker.db, grown(5, "2026-03-01T00:00:00Z"));
    const [created] = await results(worker, token, [share(postedForm({ skills: [{ id: 4 }] }))]);
    assert.equal(created.status, "created", JSON.stringify(created));
    const shared = await (await worker.fetch(`/r/${created.id}.json`)).json();
    assert.deepEqual(shared.skills, [{ gid: 2005, name: "skill 4" }]);
    assert.equal(shared.tables_version, "2026-03-01T00:00:00Z");
  });

  test("names D1 holds without a load row are not read: the generation has not moved, so the sid stays refused", async () => {
    await worker.fetch("/r/0123456789.json"); // the Worker holds the latest generation's tables
    const { held } = await worker.db.prepare("SELECT COUNT(*) AS held FROM share_table_name WHERE key = 'skill.name'").first();
    for (const [table, value] of [["share_table_name", "skill late"], ["share_table_gid", 2999]]) {
      const field = table === "share_table_name" ? "name" : "gid";
      await worker.db.prepare(`INSERT INTO ${table} (key, pos, ${field}) VALUES ('skill.name', ?, ?)`).bind(held, value).run();
    }
    const [result] = await results(worker, token, [share(postedForm({ skills: [{ id: held }] }))]);
    assert.deepEqual(result, { status: "refused", error: "invalid_payload", field: "record.skills[0].id" });
  });

  // The rows of skill `pos`, and a load row, as SQL a test writes directly: a load's statements one
  // at a time, so a test can stop between them where appendTables writes them in one batch.
  const nameRow = (pos) => `INSERT INTO share_table_name (key, pos, name) VALUES ('skill.name', ${pos}, 'skill ${pos}')`;
  const gidRow = (pos) => `INSERT INTO share_table_gid (key, pos, gid) VALUES ('skill.name', ${pos}, ${2001 + pos})`;
  const loadRow = `INSERT INTO share_table_load (generation, archive_sha256, recognizer_version, rows_added, loaded_at)
    VALUES ((SELECT COALESCE(MAX(generation), 0) + 1 FROM share_table_load), '${"0".repeat(64)}', '2026-04-01T00:00:00Z', 1, 0)`;
  const write = (...sql) => worker.db.batch(sql.map((s) => worker.db.prepare(s)));
  const skillNames = async () =>
    (await worker.db.prepare("SELECT COUNT(*) AS n FROM share_table_name WHERE key = 'skill.name'").first()).n;
  const shareSkill = (id) => results(worker, token, [share(postedForm({ skills: [{ id }] }))]).then(([r]) => r);
  /** Makes the next read of the tables fail, with a newer generation in D1 so a request reads them. */
  async function failNextRead(id) {
    await write(loadRow);
    await worker.failD1At("FROM share_table_name ORDER BY");
    (await worker.share(token, [share(postedForm({ skills: [{ id }] }))])).body?.cancel();
    assert.equal(await worker.d1FaultLeft(), null, "the tables were not read");
  }

  test("a failed read of the tables is not kept: once D1 answers, the next request reads them", async () => {
    // The late skill of the previous test gets its load row, and the read it starts fails.
    const late = (await skillNames()) - 1;
    await failNextRead(late);
    const created = await shareSkill(late);
    assert.equal(created.status, "created", JSON.stringify(created));
  });

  test("the generation is read before the rows: a load committing between the two is read again later", async () => {
    const next = await skillNames();
    await failNextRead(next); // the Worker holds no tables now: the next request reads them first
    // A load commits all its rows and its generation just before the Worker reads the generation.
    await worker.writeD1Before("FROM share_table_load ORDER BY generation DESC", [nameRow(next), gidRow(next), loadRow]);
    const created = await shareSkill(next);
    assert.equal(created.status, "created", JSON.stringify(created));
  });

  test("a name whose gid is not written yet is not held: its sid is read again once the load ends", async () => {
    const first = await skillNames();
    await write(nameRow(first), gidRow(first), loadRow);
    // A load has written skill first + 1's name but not its gid when a request reads the tables.
    await write(nameRow(first + 1));
    assert.equal((await shareSkill(first)).status, "created");
    // The load ends: the gid, then its load row.
    await write(gidRow(first + 1), loadRow);
    const created = await shareSkill(first + 1);
    assert.equal(created.status, "created", JSON.stringify(created));
    const shared = await (await worker.fetch(`/r/${created.id}.json`)).json();
    assert.deepEqual(shared.skills, [{ gid: 2001 + first + 1, name: `skill ${first + 1}` }]);
  });

  test("a factor whose tags are not written yet is not held: the tables are read again once the load ends", async () => {
    const next = (await worker.db.prepare("SELECT COUNT(*) AS n FROM share_table_name WHERE key = 'factor.name'").first())
      .n;
    // A load has written the factor's name and gid but not its tags when a request reads the tables
    // (a newer generation than the Worker holds, so the request reads them).
    await write(
      loadRow,
      `INSERT INTO share_table_name (key, pos, name) VALUES ('factor.name', ${next}, 'factor ${next}')`,
      `INSERT INTO share_table_gid (key, pos, gid) VALUES ('factor.name', ${next}, ${3001 + next})`,
    );
    // A skill the tables do not hold makes the Worker read them again, part way through the load.
    assert.equal((await shareSkill(await skillNames())).status, "refused");
    // The load ends: the tags, then its load row.
    await write(`INSERT INTO share_table_tags (key, pos, tags) VALUES ('factor.name', ${next}, '["factor_aptitude"]')`, loadRow);
    const factors = { self: [{ id: next, star: 2 }], parent1: [], parent2: [] };
    const [created] = await results(worker, token, [share(postedForm({ factors }))]);
    assert.equal(created.status, "created", JSON.stringify(created));
    const json = await worker.fetch(`/r/${created.id}.json`);
    assert.equal(json.status, 200);
    const factor = { gid: 3001 + next, name: `factor ${next}`, color: "red", star: 2 };
    assert.deepEqual((await json.json()).factors.self, [factor]);
    assert.equal((await worker.fetch(`/r/${created.id}`)).status, 200);
  });
});

describe("shared images", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  /** A share of the fixture's form declaring the images of `bundle` (from imageBundle). */
  const withImages = (bundle) => ({ ...share(), images: bundle.images });

  /** The key of share `id`'s bundle `bundle` of account `account` in B2. */
  const keyOf = (account, id, bundle) => `s/${account}/${id}/${bundle.images.name}`;

  /** The records of the account's writes of shared images that no row accounts for yet. */
  const imageWritesOf = async (account) =>
    (await worker.db.prepare("SELECT count(*) AS n FROM sync_writes WHERE account_id = ?1 AND space = 's'").bind(account).first()).n;

  /** `image_bytes` of the totals, of today's daily row, and of account `account`'s day. */
  async function imageUsage(account) {
    const day = await today(worker);
    const totals = await worker.db.prepare("SELECT image_bytes FROM totals WHERE id = 1").first();
    const daily = await worker.db.prepare("SELECT image_bytes FROM daily WHERE day = ?1").bind(day).first();
    const own = await worker.db.prepare("SELECT image_quota_bytes FROM accounts WHERE id = ?1 AND quota_day = ?2").bind(account, day).first();
    return { total: totals.image_bytes, daily: daily?.image_bytes ?? 0, account: own?.image_quota_bytes ?? 0 };
  }

  /** Moves the Worker's clock on until what a request left in the write ledger is taken, and runs the hourly run. */
  async function takeWrites() {
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER + 2 * limits.RESTORE_MARGIN_SECONDS);
    assert.equal(await worker.scheduled(), "ok");
  }

  test("a bundle is stored only by the PUT of the owner of a share declaring images, and only with the declared bytes", async () => {
    const mine = await worker.signIn("images-owner");
    const theirs = await worker.signIn("images-other");
    const owner = await worker.accountOf(mine);
    const bundle = imageBundle({ seed: 10 });
    const declared = withImages(bundle);
    const [shared, plain] = await results(worker, mine, [declared, share()]);
    assert.deepEqual([shared.status, shared.images, plain.status, plain.images], ["created", "pending", "created", "none"]);
    const key = keyOf(owner, shared.id, bundle);

    const refusedWith = async (res, status, error, field) => {
      const got = await answer(res);
      assert.deepEqual([got.status, got.body], [status, field === undefined ? { error } : { error, field }]);
    };
    await refusedWith(worker.putImages(theirs, shared.id, bundle.bytes), 403, "forbidden");
    await refusedWith(worker.putImages(newClientKey(), shared.id, bundle.bytes), 401, "session_required");
    await refusedWith(worker.putImages(mine, plain.id, bundle.bytes), 409, "no_images_declared");
    const tampered = bundle.bytes.slice();
    tampered[301 + 100] ^= 1; // a byte inside the second part, the factor screenshot
    await refusedWith(worker.putImages(mine, shared.id, tampered), 400, "invalid_payload", "parts[1]");
    await refusedWith(worker.putImages(mine, shared.id, bundle.bytes.subarray(1)), 400, "invalid_payload", "content-length");
    // Another bundle's bytes of the same length: every part differs from the declaration.
    await refusedWith(worker.putImages(mine, shared.id, imageBundle({ seed: 20 }).bytes), 400, "invalid_payload", "parts[0]");
    assert.deepEqual(worker.b2.keys("s/"), [], "a refused PUT reached B2");
    assert.equal((await answer(worker.getImages(shared.id))).status, 404, "a bundle not stored is served");

    const stored = await answer(worker.putImages(mine, shared.id, bundle.bytes));
    assert.deepEqual([stored.status, stored.body], [200, { status: "stored" }]);
    assert.deepEqual(worker.b2.versions(key), ["v"]);
    assert.deepEqual(Buffer.from(worker.b2.visible(key)), Buffer.from(bundle.bytes));
    assert.equal(await imageWritesOf(owner), 0, "the put's record of its write was left");

    const puts = worker.b2.count("PUT");
    const again = await answer(worker.putImages(mine, shared.id, bundle.bytes));
    assert.deepEqual([again.status, again.body], [200, { status: "exists" }]);
    assert.equal(worker.b2.count("PUT"), puts, "a bundle stored already was put again");

    const served = await worker.getImages(shared.id);
    assert.equal(served.status, 200);
    assert.deepEqual(Buffer.from(await served.arrayBuffer()), Buffer.from(bundle.bytes));
    assert.equal(served.headers.get("content-type"), "application/octet-stream");
    assert.equal(served.headers.get("content-disposition"), "attachment");
    assert.equal(served.headers.get("x-content-type-options"), "nosniff");
    assert.equal(served.headers.get("cache-control"), "no-store");

    // The state of the images follows the bundle in the account's list and on a resend.
    const listed = (await answer(worker.myShares(mine))).body;
    assert.deepEqual(
      listed.map((s) => [s.id, s.images]).sort(),
      [
        [shared.id, "stored"],
        [plain.id, "none"],
      ].sort(),
    );
    const [resent] = await results(worker, mine, [declared]);
    assert.deepEqual([resent.status, resent.id, resent.images], ["existing", shared.id, "stored"]);
  });

  test("declared image bytes are counted once a share, not again on a resend or a failed put, and given back on unshare", async () => {
    const token = await worker.signIn("images-usage");
    const owner = await worker.accountOf(token);
    const start = await imageUsage(owner);
    const bundle = imageBundle({ seed: 30 });
    const declared = withImages(bundle);
    const [shared, plain] = await results(worker, token, [declared, share()]);
    const size = bundle.bytes.length;
    const counted = { total: start.total + size, daily: start.daily + size, account: start.account + size };
    assert.deepEqual(await imageUsage(owner), counted);
    const charges = await worker.db.prepare("SELECT id, charge FROM records WHERE id IN (?1, ?2)").bind(shared.id, plain.id).all();
    const chargeOfId = (id) => charges.results.find((r) => r.id === id).charge;
    assert.ok(chargeOfId(shared.id) > chargeOfId(plain.id), "the declaration's bytes are not in the row's charge");

    const [resent] = await results(worker, token, [declared]);
    assert.equal(resent.status, "existing");
    assert.equal((await worker.putImages(token, shared.id, bundle.bytes.subarray(1))).status, 400);
    worker.b2.failPuts(keyOf(owner, shared.id, bundle), [{ status: 403, code: "AccessDenied" }]);
    assert.deepEqual((await answer(worker.putImages(token, shared.id, bundle.bytes))).body, { error: "storage_refused" });
    assert.equal((await worker.putImages(token, shared.id, bundle.bytes)).status, 200);
    assert.deepEqual(await imageUsage(owner), counted, "a resend or a put changed the count");

    assert.equal((await worker.unshare(token, shared.id)).status, 204);
    assert.deepEqual(await imageUsage(owner), { ...counted, total: start.total }, "the unshare did not give the declared bytes back");
    assert.deepEqual(worker.b2.keys(`s/${owner}/${shared.id}/`), [], "the unshare left the bundle in B2");
    assert.equal(await imageWritesOf(owner), 1, "the refused put's record is left to the hourly run");
  });

  test("past an image limit a share declaring images is refused, and one without images in the same request is not", async () => {
    const token = await worker.signIn("images-limit");
    const bundle = imageBundle({ seed: 40 });
    const { image_bytes: before } = await worker.db.prepare("SELECT image_bytes FROM totals WHERE id = 1").first();
    // Room for less than the bundle.
    await worker.db.prepare("UPDATE totals SET image_bytes = ?1").bind(limits.SHARE_IMAGE_BUDGET - bundle.bytes.length + 1).run();
    try {
      const list = await results(worker, token, [withImages(bundle), share()]);
      assert.deepEqual(statuses(list), ["refused image_storage_full", "created"]);
      assert.equal((await worker.db.prepare("SELECT image_bytes FROM totals WHERE id = 1").first()).image_bytes, limits.SHARE_IMAGE_BUDGET - bundle.bytes.length + 1);
    } finally {
      await worker.db.prepare("UPDATE totals SET image_bytes = ?1").bind(before).run();
    }
  });

  test("an operator's takedown, of the images and then of the share, leaves what the sharer's own withdrawal leaves, once, and the account's other share and synced objects stay", async () => {
    const token = await worker.signIn("images-takedown");
    const owner = await worker.accountOf(token);
    const bundles = [100, 110].map((seed) => imageBundle({ seed }));
    const [target, kept] = await results(worker, token, bundles.map(withImages));
    for (const [s, i] of [[target, 0], [kept, 1]]) assert.equal((await worker.putImages(token, s.id, bundles[i].bytes)).status, 200);
    const [targetKey, keptKey] = [target, kept].map((s, i) => keyOf(owner, s.id, bundles[i]));
    const synced = `a/${owner}/${"1".repeat(64)}`;
    worker.b2.objects.set(synced, [{ versionId: "synced", marker: false, bytes: new Uint8Array([1]), at: await worker.now() }]);
    const usage = async () => ({
      ...(await worker.db.prepare("SELECT bytes, count, image_bytes FROM totals WHERE id = 1").first()),
      ...(await worker.db.prepare("SELECT share_count FROM accounts WHERE id = ?1").bind(owner).first()),
    });
    const { charge } = await worker.db.prepare("SELECT charge FROM records WHERE id = ?1").bind(target.id).first();
    const order = (id, scope) =>
      worker.db.prepare("INSERT INTO share_takedowns (share_id, scope, ordered_at) VALUES (?1, ?2, unixepoch())").bind(id, scope).run();
    const done = async () =>
      (await worker.db.prepare("SELECT share_id, scope FROM share_takedowns WHERE done_at IS NOT NULL ORDER BY share_id, scope").all()).results;
    const stays = async () => {
      assert.deepEqual(worker.b2.versions(keptKey), ["v"], "the account's other share lost its bundle");
      assert.equal((await answer(worker.getImages(kept.id))).status, 200);
      assert.deepEqual(worker.b2.versions(synced), ["v"], "a synced object was reached");
      assert.equal(await imageWritesOf(owner), 0, "a record of the removal stayed");
    };

    // 1. The images only: the share stays and tells no images, as one shared without them.
    const before = await usage();
    await order(target.id, "images");
    await order("0123456789", "share"); // a share that is not there
    assert.equal(await worker.scheduled(), "ok");
    const imported = await answer(worker.fetch(`/api/shares/${target.id}`));
    assert.deepEqual([imported.status, imported.body.images], [200, null]);
    assert.equal((await answer(worker.getImages(target.id))).status, 404);
    assert.deepEqual(worker.b2.versions(targetKey), [], "the bundle stayed in B2");
    assert.deepEqual(await usage(), { ...before, image_bytes: before.image_bytes - bundles[0].bytes.length });
    assert.equal((await worker.putImages(token, target.id, bundles[0].bytes)).status, 409, "the withdrawn images were put again");
    await stays();
    assert.deepEqual(await done(), [{ share_id: "0123456789", scope: "share" }, { share_id: target.id, scope: "images" }]);

    // 2. The whole share: as its sharer's unshare, and the order run again changes nothing.
    await order(target.id, "share");
    for (let run = 0; run < 2; run++) assert.equal(await worker.scheduled(), "ok");
    assert.equal((await answer(worker.fetch(`/api/shares/${target.id}`))).status, 404);
    assert.deepEqual(await usage(), { ...before, image_bytes: before.image_bytes - bundles[0].bytes.length, bytes: before.bytes - charge, count: before.count - 1, share_count: before.share_count - 1 });
    assert.deepEqual((await answer(worker.myShares(token))).body.map((s) => s.id), [kept.id]);
    await stays();
    assert.equal((await done()).length, 3);

    // 3. A share of an account being deleted: the withdrawal changes nothing, so the order stays not done
    // while the share is there, and is done in the run after the deletion removed it.
    await worker.db.prepare("UPDATE accounts SET deleting_since = unixepoch() WHERE id = ?1").bind(owner).run();
    await order(kept.id, "share");
    assert.equal(await worker.scheduled(), "ok");
    assert.equal((await done()).length, 3, "the order was done while its share was still there");
    assert.equal((await answer(worker.fetch(`/api/shares/${kept.id}`))).status, 404, "the account's deletion left the share");
    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual((await done()).map((d) => d.share_id).includes(kept.id), true);
  });

  test("an unshare or a put meeting in any order leaves, once the hourly run took the writes, no version and no record of what was withdrawn, and the account's other share and synced objects stay", async () => {
    const token = await worker.signIn("images-crossing");
    const owner = await worker.accountOf(token);
    const bundles = [50, 60, 70, 80].map((seed) => imageBundle({ seed }));
    const [late, cut, failed, kept] = await results(worker, token, bundles.map(withImages));
    const keys = [late, cut, failed, kept].map((s, i) => keyOf(owner, s.id, bundles[i]));
    for (const [s, i] of [[failed, 2], [kept, 3]]) assert.equal((await worker.putImages(token, s.id, bundles[i].bytes)).status, 200);
    // A synced object of the same account, which nothing here may reach.
    const synced = `a/${owner}/${"0".repeat(64)}`;
    worker.b2.objects.set(synced, [{ versionId: "synced", marker: false, bytes: new Uint8Array([1]), at: await worker.now() }]);

    // 1. A put held at B2 while its share is unshared: it lands after the unshare listed the prefix.
    const held = worker.b2.hold("PUT", keys[0]);
    const put = answer(worker.putImages(token, late.id, bundles[0].bytes));
    await held.entered;
    assert.equal((await worker.unshare(token, late.id)).status, 204);
    held.release();
    assert.deepEqual([(await put).status, (await put).body], [404, { error: "not_found" }]);
    assert.deepEqual(worker.b2.versions(keys[0]), ["v"], "a version no share accounts for");

    // 2. A put B2 stored whose D1 batch failed; the put sent again stores it, so B2 holds it twice.
    await worker.cutD1At("SET images_stored_at");
    assert.equal((await worker.putImages(token, cut.id, bundles[1].bytes)).status, 503);
    await worker.restoreD1();
    assert.equal((await worker.putImages(token, cut.id, bundles[1].bytes)).status, 200);
    assert.deepEqual(worker.b2.versions(keys[1]), ["v", "v"]);

    // 3. An unshare whose deletion B2 fails: the unshare is done, the bundle is left.
    worker.b2.fail(keys[2]);
    assert.equal((await worker.unshare(token, failed.id)).status, 204);
    assert.deepEqual(worker.b2.versions(keys[2]), ["v"]);
    assert.equal((await answer(worker.getImages(failed.id))).status, 404, "an unshared share's bundle is served");
    assert.equal(await imageWritesOf(owner), 3, "each crossing leaves its record");

    await takeWrites();
    assert.deepEqual(worker.b2.versions(keys[0]), [], "the late put's version stayed");
    assert.deepEqual(worker.b2.versions(keys[2]), [], "the failed unshare's version stayed");
    // The share that holds its bundle keeps both versions, the same bytes: B2's lifecycle takes the older.
    assert.deepEqual(worker.b2.versions(keys[1]), ["v", "v"]);
    assert.equal(await imageWritesOf(owner), 0, "a record stayed");
    assert.deepEqual(worker.b2.versions(keys[3]), ["v"], "the account's other share lost its bundle");
    assert.equal((await answer(worker.getImages(kept.id))).status, 200);
    assert.deepEqual(worker.b2.versions(synced), ["v"], "a synced object was reached");

    // Unsharing the share B2 holds twice deletes both.
    assert.equal((await worker.unshare(token, cut.id)).status, 204);
    assert.deepEqual(worker.b2.keys(`s/${owner}/${cut.id}/`), []);
    assert.equal(await imageWritesOf(owner), 0);
  });

  test("a put B2 stores but answers 503, refused on the retry after its share was unshared, leaves no version once the hourly run took its record", async () => {
    const token = await worker.signIn("images-stored-then-refused");
    const owner = await worker.accountOf(token);
    const bundle = imageBundle({ seed: 90 });
    const [shared] = await results(worker, token, [withImages(bundle)]);
    const key = keyOf(owner, shared.id, bundle);
    // The unshare completes once the put recorded its write, listing a prefix that holds nothing yet.
    await worker.writeD1Before("INSERT INTO sync_writes", [`DELETE FROM records WHERE id = '${shared.id}'`]);
    // The first attempt is stored but answered 503, and the retry is refused.
    worker.b2.failPuts(key, [
      { status: 503, code: "ServiceUnavailable", retryAfter: "0" },
      { status: 403, code: "AccessDenied" },
    ]);
    worker.b2.objects.set(key, [{ versionId: "stored-on-503", marker: false, bytes: bundle.bytes, at: await worker.now() }]);
    assert.deepEqual((await answer(worker.putImages(token, shared.id, bundle.bytes))).body, { error: "storage_refused" });
    assert.equal(await imageWritesOf(owner), 1, "the refused put dropped the only record of what it may have stored");

    await takeWrites();
    assert.deepEqual(worker.b2.keys(`s/${owner}/`), [], "the version stored on the 503 stayed");
    assert.equal(await imageWritesOf(owner), 0);
  });
});

describe("image switch", () => {
  test('SHARE_IMAGES_ENABLED "false" refuses images in and out, and lets unsharing, a takedown and the hourly run remove them, sync switched off too', async () => {
    const worker = await startWorker({ testEntry: true, vars: { SHARE_IMAGES_ENABLED: "false", SYNC_ENABLED: "false" } });
    try {
      const token = await worker.signIn();
      const owner = await worker.accountOf(token);
      const bundle = imageBundle({ seed: 90 });
      const list = await results(worker, token, [{ ...share(), images: bundle.images }, share()]);
      assert.deepEqual(statuses(list), ["refused image_sharing_paused", "created"]);
      assert.equal(await worker.count("records"), 1);

      // A share stored with its bundle before the switch, written directly: this Worker cannot make it.
      const id = "0123456789";
      await worker.insertRecord(id, postedForm());
      await worker.db
        .prepare("UPDATE records SET owner_id = ?1, images = ?2, images_name = ?3, images_size = ?4, images_stored_at = 1 WHERE id = ?5")
        .bind(owner, JSON.stringify(bundle.images.parts), bundle.images.name, bundle.images.size, id)
        .run();
      const key = `s/${owner}/${id}/${bundle.images.name}`;
      worker.b2.objects.set(key, [{ versionId: "before", marker: false, bytes: bundle.bytes, at: await worker.now() }]);

      const imported = await answer(worker.fetch(`/api/shares/${id}`));
      assert.deepEqual([imported.status, imported.body.images], [200, { state: "unavailable" }]);
      assert.equal((await answer(worker.fetch(`/api/shares/${list[1].id}`))).body.images, null, "a share without images is told apart");
      assert.equal((await answer(worker.getImages(id))).status, 404);
      const put = await answer(worker.putImages(token, id, bundle.bytes));
      assert.deepEqual([put.status, put.body], [503, { error: "image_sharing_paused" }]);

      worker.b2.fail(key);
      assert.equal((await worker.unshare(token, id)).status, 204);
      assert.deepEqual(worker.b2.versions(key), ["v"]);
      // An operator's takedown of the images of the share still served, ordered while switched off.
      await worker.db
        .prepare("UPDATE records SET owner_id = ?1, images = ?2, images_name = ?3, images_size = ?4, images_stored_at = 1 WHERE id = ?5")
        .bind(owner, JSON.stringify(bundle.images.parts), bundle.images.name, bundle.images.size, list[1].id)
        .run();
      const servedKey = `s/${owner}/${list[1].id}/${bundle.images.name}`;
      worker.b2.objects.set(servedKey, [{ versionId: "before", marker: false, bytes: bundle.bytes, at: await worker.now() }]);
      await worker.db.prepare("INSERT INTO share_takedowns (share_id, scope, ordered_at) VALUES (?1, 'images', unixepoch())").bind(list[1].id).run();
      await worker.advanceClock(limits.SYNC_ABANDONED_AFTER + 2 * limits.RESTORE_MARGIN_SECONDS);
      assert.equal(await worker.scheduled(), "ok");
      assert.deepEqual(worker.b2.versions(key), [], "the hourly run left the bundle while switched off");
      assert.deepEqual(worker.b2.versions(servedKey), [], "the takedown was not carried out while switched off");
      assert.equal((await answer(worker.fetch(`/api/shares/${list[1].id}`))).body.images, null);
      assert.equal(await worker.count("sync_writes"), 0);
    } finally {
      await worker.dispose();
    }
  });
});
