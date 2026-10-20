// File sync's list (POST /api/sync/parts, POST /api/sync/root, GET /api/sync/parts/<name> and
// /api/sync/roots/<name>): the checks a part passes when it is put, the generation that orders
// replacements of the root, and the number of parts one replacement may change. Driven over HTTP
// against a real (local) D1 and the in-memory B2 bucket of the harness.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import { newRecord, part, PARTS, recordPart, root, sha256, syncClient as listClient } from "./support/sync_fixtures.mjs";
import { startWorker } from "./support/worker_harness.mjs";

describe("sync list", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  /** A fresh account: its id, client, and a stored record part per slot of `slots` (`{slot → {part, rows}}`). */
  async function account(sub, slots = []) {
    const token = await worker.signIn(sub);
    const client = listClient(worker, token);
    const parts = {};
    for (const n of slots) {
      const record = newRecord(n);
      assert.equal((await client.putBodies([record.body])).status, 200);
      parts[n] = recordPart(n, [record.row]);
      assert.equal((await client.putPart(parts[n])).status, 200);
    }
    return { id: await worker.accountOf(token), client, parts };
  }

  const syncRow = (accountId) =>
    worker.db.prepare("SELECT generation, root_name, record_count FROM sync_accounts WHERE account_id = ?").bind(accountId).first();
  /** The list of an account no replacement committed for (its row holds the daily counters and usage of its puts). */
  const NEVER_REPLACED = { generation: 0, root_name: null, record_count: 0 };
  const objectRow = (accountId, name) =>
    worker.db.prepare("SELECT kind FROM sync_objects WHERE account_id = ? AND name = ?").bind(accountId, name).first();

  test(`a first sync of 128 record parts and both opaque parts is built by replacements of ${limits.SYNC_PARTS_PER_REPLACE} parts`, async () => {
    const token = await worker.signIn("list-first-sync");
    const client = listClient(worker, token);
    const accountId = await worker.accountOf(token);
    const records = Array.from({ length: PARTS }, (_, n) => newRecord(n));
    for (let i = 0; i < records.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      const put = await client.putBodies(records.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body));
      assert.equal(put.status, 200, put.text);
    }
    const slots = {};
    for (const [n, r] of records.entries()) slots[String(n)] = recordPart(n, [r.row]);
    slots.columns = part({ part: "columns", content: [{ id: "c0", title: "列", written_at: 1 }] });
    slots.dismissed = part({ part: "dismissed", content: [[records[0].row.id, records[1].row.id]] });
    for (const p of Object.values(slots)) {
      const put = await client.putPart(p);
      assert.deepEqual([put.status, put.body], [200, { name: p.name, status: "stored" }], put.text);
    }

    const entries = Object.entries(slots);
    const current = {};
    let generation = 0;
    let last;
    for (let i = 0; i < entries.length; i += limits.SYNC_PARTS_PER_REPLACE) {
      for (const [slot, p] of entries.slice(i, i + limits.SYNC_PARTS_PER_REPLACE)) current[slot] = p.name;
      last = root(current);
      const res = await client.replace(generation, last);
      assert.deepEqual([res.status, res.body], [200, { generation: generation + 1, root: last.name }], res.text);
      generation++;
    }
    assert.equal(generation, Math.ceil((PARTS + 2) / limits.SYNC_PARTS_PER_REPLACE));
    assert.deepEqual((await client.generation()).body, { generation, root: last.name });
    assert.deepEqual(await syncRow(accountId), { generation, root_name: last.name, record_count: PARTS });

    const fetchedRoot = await client.getRoot(last.name);
    assert.deepEqual([fetchedRoot.status, fetchedRoot.text], [200, last.text]);
    for (const p of Object.values(slots)) assert.equal((await client.getPart(p.name)).text, p.text);
  });

  test("a replacement from another generation is 409 and changes nothing", async () => {
    const { id, client, parts } = await account("list-stale", [0, 1]);
    const first = root({ 0: parts[0].name });
    assert.equal((await client.replace(0, first)).status, 200);
    const before = [await syncRow(id), worker.b2.count("PUT")];

    for (const generation of [0, 2]) {
      const res = await client.replace(generation, root({ 0: parts[0].name, 1: parts[1].name }));
      assert.deepEqual([res.status, res.body], [409, { error: "stale_generation", generation: 1 }]);
    }
    assert.deepEqual([await syncRow(id), worker.b2.count("PUT")], before);
  });

  test("of two replacements from the same generation, only one goes through", async () => {
    const { id, client, parts } = await account("list-race", [0, 1, 2]);
    assert.equal((await client.replace(0, root({ 0: parts[0].name }))).status, 200);
    const roots = [root({ 0: parts[0].name, 1: parts[1].name }), root({ 0: parts[0].name, 2: parts[2].name })];

    await worker.armGate(2);
    const results = await Promise.all(roots.map((r) => client.replace(1, r)));
    assert.deepEqual(await worker.gate(), { expected: 2, arrived: 2 });
    assert.deepEqual(results.map((r) => r.status).sort(), [200, 409]);
    const winner = roots[results.findIndex((r) => r.status === 200)];
    assert.deepEqual(results.find((r) => r.status === 409).body, { error: "stale_generation", generation: 2 });
    assert.deepEqual(await syncRow(id), { generation: 2, root_name: winner.name, record_count: 2 });
  });

  test("a root naming a part the account does not hold is 409 and changes nothing", async () => {
    const { id, client, parts } = await account("list-missing", [0]);
    assert.equal((await client.replace(0, root({ 0: parts[0].name }))).status, 200);
    const before = await syncRow(id);
    const unstored = recordPart(1, [newRecord(1).row]);

    const res = await client.replace(1, root({ 0: parts[0].name, 1: unstored.name }));
    assert.deepEqual([res.status, res.body], [409, { error: "missing_objects", names: [unstored.name] }]);
    assert.deepEqual(await syncRow(id), before);
  });

  test("a part whose row's image is not its body's binding is 400, one naming a body not stored is 409, and neither is stored", async () => {
    const { id, client } = await account("list-image");
    const record = newRecord(5);
    assert.equal((await client.putBodies([record.body])).status, 200);
    const wrong = recordPart(5, [{ ...record.row, image: { ...record.row.image, skill_jpeg: sha256("other") } }]);

    const res = await client.putPart(wrong);
    assert.deepEqual([res.status, res.body], [400, { error: "invalid_payload", field: "part.records[0].image" }]);
    assert.equal(await objectRow(id, wrong.name), null);
    assert.deepEqual(worker.b2.keys(`a/${id}/${wrong.name}`), []);

    const unstored = newRecord(5);
    const bodiless = recordPart(5, [unstored.row]);
    const missing = await client.putPart(bodiless);
    assert.deepEqual([missing.status, missing.body], [409, { error: "missing_objects", names: [unstored.body.name] }]);
    assert.equal(await objectRow(id, bodiless.name), null);
  });

  test("a part holding an id of another part, or one id twice, is 400 and not stored, and a root may name a part only in its own slot", async () => {
    const { id, client } = await account("list-number");
    const own = newRecord(7);
    const foreign = newRecord(8);
    assert.equal((await client.putBodies([own.body, foreign.body])).status, 200);

    for (const rows of [[own.row, foreign.row], [own.row, own.row]]) {
      const p = recordPart(7, rows);
      const res = await client.putPart(p);
      assert.deepEqual([res.status, res.body], [400, { error: "invalid_payload", field: "part.records[1].id" }]);
      assert.equal(await objectRow(id, p.name), null);
      assert.deepEqual(worker.b2.keys(`a/${id}/${p.name}`), []);
    }

    const stored = recordPart(7, [own.row]);
    assert.equal((await client.putPart(stored)).status, 200);
    const misplaced = await client.replace(0, root({ 8: stored.name }));
    assert.deepEqual([misplaced.status, misplaced.body], [400, { error: "invalid_payload", field: "root.parts.8" }]);
    assert.deepEqual(await syncRow(id), NEVER_REPLACED);
  });

  test(`a replacement changing more than ${limits.SYNC_PARTS_PER_REPLACE} parts is refused and changes nothing, opaque parts counted`, async () => {
    const S = limits.SYNC_PARTS_PER_REPLACE;
    const slots = Array.from({ length: S + 1 }, (_, n) => n);
    const { id, client, parts } = await account("list-step", slots);
    const columns = part({ part: "columns", content: [] });
    assert.equal((await client.putPart(columns)).status, 200);
    const recordParts = (ns) => Object.fromEntries(ns.map((n) => [String(n), parts[n].name]));

    const tooMany = [
      root({ ...recordParts(slots.slice(0, S)), columns: columns.name }),
      root(recordParts(slots)),
    ];
    for (const r of tooMany) {
      const res = await client.replace(0, r);
      assert.deepEqual([res.status, res.body], [400, { error: "too_many_parts", limit: S }]);
      assert.deepEqual(await syncRow(id), NEVER_REPLACED);
      assert.equal(await objectRow(id, r.name), null);
    }

    const full = root(recordParts(slots.slice(0, S)));
    assert.equal((await client.replace(0, full)).status, 200);
    const emptied = await client.replace(1, root({ columns: columns.name }));
    assert.deepEqual([emptied.status, emptied.body], [400, { error: "too_many_parts", limit: S }]);
    assert.deepEqual(await syncRow(id), { generation: 1, root_name: full.name, record_count: S });
  });
});
