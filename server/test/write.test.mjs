// The write side of the sharing Worker (tickets, publish, lookup, withdraw), driven over HTTP
// against a real (local) D1, with siteverify answered inside the test.
//
// The concurrency cases run through the batch gate (see worker_harness.mjs): every racing request
// has finished its reads before any batch runs, so they exercise the interleaving the design's
// judgement table is written for. Local D1 serialises the batches the way production D1 is
// documented to; whether production does is checked on the staging D1, not here.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import { newDeleteKey, newTicket, ORIGIN, postedForm, secretHash, startWorker, TURNSTILE } from "./support/worker_harness.mjs";

/** The JSON body of an API answer; null for an empty or non-JSON one (the read side's plain 404). */
async function body(res) {
  const text = await res.text();
  return res.headers.get("content-type")?.startsWith("application/json") ? JSON.parse(text) : null;
}

/** Status and parsed body of one response. */
async function answer(resPromise) {
  const res = await resPromise;
  return { status: res.status, body: await body(res), headers: res.headers };
}

const today = () => Math.floor(Date.now() / 86_400_000);

describe("posted form checks", () => {
  let worker;
  let ticket;
  before(async () => {
    worker = await startWorker();
    ticket = await worker.issueTicket();
  });
  after(() => worker.dispose());

  /** Publishes `record` and asserts it was refused without storing anything or using the ticket. */
  async function refused(record, status, error, field) {
    const res = await answer(worker.publish({ ticket, delete_key: newDeleteKey(), record }));
    assert.equal(res.status, status, JSON.stringify(res.body));
    assert.equal(res.body.error, error);
    if (field !== undefined) assert.equal(res.body.field, field);
    assert.equal(await worker.count("records"), 0);
    assert.equal(await worker.remaining(ticket), limits.TICKET_USES);
  }

  test("an unknown key is refused at any depth", async () => {
    await refused({ ...postedForm(), trainer_id: "123456789" }, 400, "invalid_payload", "record.trainer_id");
    await refused(postedForm({ trainee: { character: 3, card: 3, rank: 2, icon: 0 } }), 400, "invalid_payload", "record.trainee.icon");
  });

  test("a sid past the end of a table is refused, as server_tables_older when the client's modules are newer", async () => {
    const pastEnd = [{ id: 3 }]; // the fixture's skill table holds sids 0 to 2
    await refused(postedForm({ skills: pastEnd }), 400, "invalid_payload", "record.skills[0].id");
    await refused(
      postedForm({ skills: pastEnd, module_version: "2027-01-01T00:00:00+0900" }),
      409,
      "server_tables_older",
      "record.skills[0].id",
    );
  });

  test("a friend's record is refused", async () => {
    await refused(postedForm({ record_type: "FriendStandard" }), 400, "invalid_payload", "record.record_type");
  });

  test("a body over the size limit is refused before it is read", async () => {
    const record = postedForm();
    const text = JSON.stringify({ ticket, delete_key: newDeleteKey(), record });
    const padded = text + " ".repeat(limits.MAX_PUBLISH_BODY + 1 - text.length);
    const res = await answer(
      worker.fetch("/api/records", { method: "POST", headers: { "Content-Type": "application/json" }, body: padded }),
    );
    assert.equal(res.status, 413);
    assert.equal(res.body.error, "payload_too_large");
    assert.equal(await worker.count("records"), 0);
  });
});

describe("publish, lookup and withdraw", () => {
  let worker;
  before(async () => {
    worker = await startWorker();
  });
  after(() => worker.dispose());

  test("a published record is withdrawn only with its own key, and is gone afterwards", async () => {
    const ticket = await worker.issueTicket();
    const key = newDeleteKey();
    const published = await answer(worker.publish({ ticket, delete_key: key, record: postedForm() }));
    assert.equal(published.status, 201);
    const { id } = published.body;
    assert.deepEqual(published.body, { id, url: `${ORIGIN}/r/${id}`, json_url: `${ORIGIN}/r/${id}.json` });

    const json = await answer(worker.fetch(`/r/${id}.json`));
    assert.equal(json.status, 200);
    assert.deepEqual(json.body.trainee.card, { gid: 1004, name: "card <b>&\"'" });
    assert.deepEqual(
      json.body.races.map((r) => r.position.name),
      ["1", "18"],
    );
    const charge = (await worker.db.prepare("SELECT charge FROM records WHERE id = ?").bind(id).first()).charge;
    assert.deepEqual(await worker.totals(), { bytes: charge, count: 1 });

    const wrong = await answer(worker.withdraw(id, newDeleteKey()));
    assert.equal(wrong.status, 403);
    assert.equal(wrong.body.error, "forbidden");
    assert.equal((await answer(worker.fetch(`/r/${id}.json`))).status, 200, "a wrong key removed the record");

    assert.equal((await answer(worker.withdraw(id, key))).status, 204);
    assert.equal((await answer(worker.fetch(`/r/${id}.json`))).status, 404);
    assert.equal((await answer(worker.fetch(`/r/${id}`))).status, 404);
    assert.deepEqual(await worker.totals(), { bytes: 0, count: 0 });
    assert.equal((await answer(worker.withdraw(id, key))).status, 404);
  });

  test("lookup returns the id for the key it was published with and 404 for an unknown key", async () => {
    const ticket = await worker.issueTicket();
    const key = newDeleteKey();
    const published = await answer(worker.publish({ ticket, delete_key: key, record: postedForm() }));
    assert.equal(published.status, 201);

    const found = await answer(worker.post("/api/records/lookup", { delete_key: key }));
    assert.equal(found.status, 200);
    assert.deepEqual(found.body, published.body);

    const unknown = await answer(worker.post("/api/records/lookup", { delete_key: newDeleteKey() }));
    assert.equal(unknown.status, 404);
  });
});

describe("tickets", () => {
  let worker;
  before(async () => {
    worker = await startWorker();
  });
  after(() => worker.dispose());

  test("publishing is refused without a ticket, with an unknown, an expired or a used-up one", async () => {
    const attempt = (fields) => answer(worker.publish({ delete_key: newDeleteKey(), record: postedForm(), ...fields }));
    // Stored directly rather than issued: issuing a ticket sweeps expired ones in the background,
    // which would remove the expired row and leave "expired" testing an unknown ticket.
    const store = async (remaining, expiresAt) => {
      const ticket = newTicket();
      await worker.db
        .prepare("INSERT INTO tickets (hash, remaining, expires_at) VALUES (?, ?, ?)")
        .bind(secretHash(ticket), remaining, expiresAt)
        .run();
      return ticket;
    };
    const expired = await store(limits.TICKET_USES, 0);
    const usedUp = await store(0, Math.floor(Date.now() / 1000) + limits.TICKET_TTL_SECONDS);

    for (const [name, fields] of [
      ["none", {}],
      ["unknown", { ticket: newTicket() }],
      ["expired", { ticket: expired }],
      ["used up", { ticket: usedUp }],
    ]) {
      const res = await attempt(fields);
      assert.equal(res.status, 401, name);
      assert.equal(res.body.error, "ticket_required", name);
    }
    assert.equal(await worker.count("records"), 0);
    assert.deepEqual(await worker.totals(), { bytes: 0, count: 0 });
    assert.equal(await worker.remaining(usedUp), 0);
    assert.equal(await worker.remaining(expired), limits.TICKET_USES, "the expired ticket's row was gone");
  });

  test("a token siteverify does not accept creates no ticket", async () => {
    const pass = { success: true, hostname: TURNSTILE.HOSTNAME, action: TURNSTILE.ACTION };
    const answers = {
      "failed": { ...pass, success: false },
      "other hostname": { ...pass, hostname: "evil.test" },
      "other action": { ...pass, action: "login" },
      // Matching hostname and action, so only the testing-key mark can refuse it.
      "testing key": { ...pass, metadata: { result_with_testing_key: true } },
      "unreachable": new Error("network down"),
    };
    const ticketsBefore = await worker.count("tickets");
    for (const [name, verdict] of Object.entries(answers)) {
      worker.siteverify.answer = () => verdict;
      const ticket = newTicket();
      const h = secretHash(ticket).toString("hex");
      const res = await answer(worker.post("/api/tickets", { h, token: "turnstile-token" }));
      assert.equal(res.status, 403, name);
      assert.equal(res.body.error, "verification_failed", name);
      const publish = await answer(worker.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() }));
      assert.equal(publish.status, 401, name);
    }
    assert.equal(await worker.count("tickets"), ticketsBefore);
    assert.equal(await worker.count("records"), 0);
    const call = worker.siteverify.calls.at(-1);
    assert.equal(call.form.get("secret"), TURNSTILE.SECRET);
    assert.equal(call.form.get("response"), "turnstile-token");
    assert.equal(call.form.has("remoteip"), false, "the visitor's IP reached siteverify");
  });

  test("an environment declaring the testing key issues tickets on the testing secret's answers", async () => {
    const staging = await startWorker({ vars: { TURNSTILE_TESTING_KEY: "true" } });
    try {
      // What siteverify answers for the always-passing testing secret.
      const testing = {
        "success": true,
        "error-codes": [],
        "hostname": "example.com",
        "metadata": { result_with_testing_key: true },
        "challenge_ts": "2026-10-05T00:00:00.000Z",
      };
      staging.siteverify.answer = () => testing;
      const ticket = await staging.issueTicket();
      const publish = await answer(staging.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() }));
      assert.equal(publish.status, 201, JSON.stringify(publish.body));

      // Answers without the mark are still held to this environment's hostname and action.
      const refused = {
        "failed": { ...testing, success: false },
        "unmarked, other hostname": { success: true, hostname: "example.com", action: TURNSTILE.ACTION },
      };
      for (const [name, verdict] of Object.entries(refused)) {
        staging.siteverify.answer = () => verdict;
        const h = secretHash(newTicket()).toString("hex");
        const res = await answer(staging.post("/api/tickets", { h, token: "turnstile-token" }));
        assert.equal(res.status, 403, name);
      }
    } finally {
      await staging.dispose();
    }
  });
});

describe("limits", () => {
  test("the daily limit answers 429 and the storage budget 503, without using the ticket", async () => {
    const worker = await startWorker();
    try {
      const ticket = await worker.issueTicket();
      const first = await answer(worker.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() }));
      assert.equal(first.status, 201);
      // The same form compresses to the same bytes, so every publish below carries this charge.
      const charge = (await worker.db.prepare("SELECT charge FROM records").first()).charge;
      const remaining = await worker.remaining(ticket);
      const publish = () => answer(worker.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() }));

      await worker.db
        .prepare("UPDATE daily SET publish_bytes = ? WHERE day = ?")
        .bind(limits.DAILY_LIMIT - charge + 1, today())
        .run();
      const daily = await publish();
      assert.equal(daily.status, 429);
      assert.equal(daily.body.error, "daily_limit");
      const retryAfter = Number(daily.headers.get("retry-after"));
      assert.ok(retryAfter > 0 && retryAfter <= 86_400, `Retry-After ${retryAfter}`);

      await worker.db.prepare("UPDATE daily SET publish_bytes = 0").run();
      await worker.db.prepare("UPDATE totals SET bytes = ?").bind(limits.STORAGE_BUDGET - charge + 1).run();
      const full = await publish();
      assert.equal(full.status, 503);
      assert.equal(full.body.error, "storage_full");

      assert.equal(await worker.count("records"), 1);
      assert.equal(await worker.remaining(ticket), remaining, "a refused publish used the ticket");

      await worker.db.prepare("UPDATE daily SET tickets = ? WHERE day = ?").bind(limits.TICKET_LIMIT, today()).run();
      const h = secretHash(newTicket()).toString("hex");
      const tickets = await answer(worker.post("/api/tickets", { h, token: "turnstile-token" }));
      assert.equal(tickets.status, 429);
      assert.equal(tickets.body.error, "daily_limit");
    } finally {
      await worker.dispose();
    }
  });

  test("a failure after the batch's first statement consumes neither the ticket nor the counters", async () => {
    const worker = await startWorker();
    try {
      const ticket = await worker.issueTicket();
      const dailyBefore = await worker.daily();
      // The third statement (the totals update) fails after the record was inserted and the ticket
      // decremented.
      await worker.db
        .prepare("CREATE TRIGGER fail_totals BEFORE UPDATE ON totals BEGIN SELECT RAISE(ABORT, 'injected'); END")
        .run();
      const key = newDeleteKey();
      const failed = await answer(worker.publish({ ticket, delete_key: key, record: postedForm() }));
      assert.equal(failed.status, 503);
      assert.equal(failed.body.error, "temporarily_unavailable");
      assert.equal(await worker.count("records"), 0);
      assert.equal(await worker.remaining(ticket), limits.TICKET_USES);
      assert.deepEqual(await worker.totals(), { bytes: 0, count: 0 });
      assert.deepEqual(await worker.daily(), dailyBefore);

      // Nothing was left half-done: the same key and ticket publish once the failure is gone.
      await worker.db.prepare("DROP TRIGGER fail_totals").run();
      const retried = await answer(worker.publish({ ticket, delete_key: key, record: postedForm() }));
      assert.equal(retried.status, 201);
    } finally {
      await worker.dispose();
    }
  });

  test("a refused publish whose candidate id is already taken changes nothing", async () => {
    const worker = await startWorker({ testEntry: true });
    try {
      const ticket = await worker.issueTicket();
      const seed = await answer(worker.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() }));
      assert.equal(seed.status, 201);
      const charge = (await worker.db.prepare("SELECT charge FROM records").first()).charge;
      // No room for another record, and the next publish draws the stored record's id first.
      await worker.db.prepare("UPDATE totals SET bytes = ?").bind(limits.STORAGE_BUDGET - charge + 1).run();
      const state = async () => ({
        totals: await worker.totals(),
        daily: await worker.daily(),
        remaining: await worker.remaining(ticket),
      });
      const before = await state();
      await worker.forcePublicIds([seed.body.id]);

      const refused = await answer(worker.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() }));
      assert.equal(refused.status, 503, JSON.stringify(refused.body));
      assert.equal(refused.body.error, "storage_full");
      assert.deepEqual(await worker.forcedPublicIdsLeft(), [], "the publish did not draw the taken id");
      assert.deepEqual(await state(), before, "a refused publish changed the counters or the ticket");
      assert.equal(await worker.count("records"), 1);
    } finally {
      await worker.dispose();
    }
  });
});

describe("concurrent writes", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());
  beforeEach(async () => {
    await worker.db.batch([
      worker.db.prepare("DELETE FROM records"),
      worker.db.prepare("UPDATE totals SET bytes = 0, count = 0"),
      worker.db.prepare("DELETE FROM daily"),
    ]);
  });

  /** Sends `requests` with the batch gate armed for all of them, and checks they all reached it. */
  async function race(requests) {
    await worker.armGate(requests.length);
    const results = await Promise.all(requests.map((send) => answer(send())));
    assert.deepEqual(await worker.gate(), { expected: requests.length, arrived: requests.length }, "the requests did not overlap");
    return results.sort((a, b) => a.status - b.status);
  }

  test("two publishes racing for the last of the budget commit one, and the refused one leaves the ticket alone", async () => {
    const ticket = await worker.issueTicket();
    const seed = await answer(worker.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() }));
    assert.equal(seed.status, 201);
    const charge = (await worker.db.prepare("SELECT charge FROM records").first()).charge;
    // Room for one more record, not two.
    const start = limits.STORAGE_BUDGET - charge - Math.floor(charge / 2);
    await worker.db.prepare("UPDATE totals SET bytes = ?").bind(start).run();
    const before = await worker.remaining(ticket);

    const publish = () => worker.publish({ ticket, delete_key: newDeleteKey(), record: postedForm() });
    const [won, lost] = await race([publish, publish]);
    assert.deepEqual([won.status, lost.status], [201, 503]);
    assert.equal(lost.body.error, "storage_full");
    const totals = await worker.totals();
    assert.equal(totals.bytes, start + charge);
    assert.ok(totals.bytes <= limits.STORAGE_BUDGET);
    assert.equal(await worker.count("records"), 2);
    assert.equal(await worker.remaining(ticket), before - 1);
  });

  test("concurrent resends with one key converge on one id even when the first uses the ticket's last publish", async () => {
    const ticket = await worker.issueTicket();
    await worker.db.prepare("UPDATE tickets SET remaining = 1 WHERE hash = ?").bind(secretHash(ticket)).run();
    const key = newDeleteKey();

    const resend = () => worker.publish({ ticket, delete_key: key, record: postedForm() });
    const [second, first] = await race([resend, resend]);
    assert.deepEqual([second.status, first.status], [200, 201], JSON.stringify([second.body, first.body]));
    assert.deepEqual(second.body, first.body);
    assert.equal(await worker.count("records"), 1);
    assert.equal(await worker.remaining(ticket), 0);
  });

  test("two concurrent withdrawals with the right key give the charge back once", async () => {
    const ticket = await worker.issueTicket();
    const key = newDeleteKey();
    const published = await answer(worker.publish({ ticket, delete_key: key, record: postedForm() }));
    assert.equal(published.status, 201);
    const { id } = published.body;
    const charge = (await worker.db.prepare("SELECT charge FROM records WHERE id = ?").bind(id).first()).charge;
    const before = await worker.totals();

    const withdraw = () => worker.withdraw(id, key);
    const [done, gone] = await race([withdraw, withdraw]);
    assert.deepEqual([done.status, gone.status], [204, 404]);
    assert.deepEqual(await worker.totals(), { bytes: before.bytes - charge, count: before.count - 1 });
  });
});
