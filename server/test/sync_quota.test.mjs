// File sync's daily limits and capacity (sync_quota.mjs): the reserve each daily limit keeps for one
// replacement, the generation that no limit stops, the put of a name already held that no limit or cap
// stops, an account exactly at its caps, the hidden bytes that do not count against an account's cap
// but have a cap of their own, the service's budget that counts them, and the D1 database's room,
// which keeps a reserve too, leaves sharing its part and does not stop what only reads or takes rows
// away. Driven over HTTP against a
// real (local) D1 and the in-memory B2 bucket of the harness; the counters and usage a test starts from
// are written into D1 directly, as a day of earlier requests would have left them.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import { Unavailable } from "../src/store.mjs";
import { admitDatabase } from "../src/sync_quota.mjs";
import { named, STATEMENT } from "../src/sync_refs.mjs";
import { archived, bodyOf, newImage, newRecord, recordPart, root, sha256, syncClient } from "./support/sync_fixtures.mjs";
import { newClientKey, postedForm, startWorker } from "./support/worker_harness.mjs";

const DAY = 86_400;
/** A replacement's first statement after its commit (`showReferenced`), by its name: failing it cuts the replacement off there. */
const SHOW_REFERENCED = named(STATEMENT.SHOW_REFERENCED);
const R = limits.SYNC_REPLACE_RESERVE;
const S = limits.SYNC_PARTS_PER_REPLACE;
const LIMITS = {
  account: { requests: limits.ACCOUNT_SYNC_REQUESTS_PER_DAY, rows_read: limits.ACCOUNT_SYNC_READ_ROWS_PER_DAY, rows_written: limits.ACCOUNT_SYNC_ROWS_PER_DAY },
  service: { requests: limits.SYNC_DAILY_REQUESTS, rows_read: limits.SYNC_DAILY_READ_ROWS, rows_written: limits.SYNC_DAILY_ROWS },
};

describe("sync daily limits and capacity", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());
  // The service's counters are shared by every test of the suite.
  beforeEach(async () => {
    await worker.db.prepare("DELETE FROM sync_daily").run();
  });

  async function account(sub) {
    const token = await worker.signIn(sub);
    const client = syncClient(worker, token);
    const id = await worker.accountOf(token);
    // A counted request makes the account's row, which the counters below are written into.
    assert.equal((await client.settings()).status, 200);
    return { id, client, token };
  }

  const today = async () => Math.floor((await worker.now()) / DAY);

  /** Sets what account `id` (scope "account") or the service has used today of each counter in `used`. */
  async function setUsed(scope, id, used) {
    const day = await today();
    const v = { requests: 0, rows_read: 0, rows_written: 0, ...used };
    if (scope === "account") {
      await worker.db
        .prepare("UPDATE sync_accounts SET daily_day = ?, daily_requests = ?, daily_rows_read = ?, daily_rows_written = ? WHERE account_id = ?")
        .bind(day, v.requests, v.rows_read, v.rows_written, id)
        .run();
    } else {
      await worker.db
        .prepare(
          `INSERT INTO sync_daily (day, requests, rows_read, rows_written) VALUES (?1, ?2, ?3, ?4)
           ON CONFLICT (day) DO UPDATE SET requests = ?2, rows_read = ?3, rows_written = ?4`,
        )
        .bind(day, v.requests, v.rows_read, v.rows_written)
        .run();
    }
  }

  const accountRow = (id) =>
    worker.db.prepare("SELECT stored_bytes, hidden_bytes, record_count FROM sync_accounts WHERE account_id = ?").bind(id).first();

  /** Adds `bytes` to the bytes account `id` (and so the service) holds referenced. */
  async function addStored(id, bytes) {
    await worker.db.prepare("UPDATE sync_accounts SET stored_bytes = stored_bytes + ? WHERE account_id = ?").bind(bytes, id).run();
    await worker.db.prepare("UPDATE sync_totals SET stored_bytes = stored_bytes + ? WHERE id = 1").bind(bytes).run();
  }

  /** Adds `bytes` to what account `id` hid today. */
  async function addHiddenToday(id, bytes) {
    const path = `$."${await today()}"`;
    await worker.db
      .prepare("UPDATE sync_accounts SET hidden_bytes = json_set(hidden_bytes, ?, coalesce(json_extract(hidden_bytes, ?), 0) + ?) WHERE account_id = ?")
      .bind(path, path, bytes, id)
      .run();
  }

  /** Records `n` (one per part 0..n-1, each with a fresh PNG named) whose bodies are put, and their parts, not put. */
  async function prepared(client, n) {
    const out = [];
    for (let slot = 0; slot < n; slot++) {
      const record = newRecord(slot);
      assert.equal((await client.putBodies([record.body])).status, 200);
      out.push({ slot, record, part: recordPart(slot, [record.row]) });
    }
    return out;
  }

  const isDailyLimit = (res, scope) => {
    assert.deepEqual([res.status, res.body], [429, { error: "daily_limit", scope }], res.text);
    assert.ok(Number(res.headers.get("Retry-After")) > 0);
  };

  for (const scope of ["account", "service"]) {
    for (const counter of ["requests", "rows_read", "rows_written"]) {
      test(`with the ${scope}'s ${counter} nearly used up, bodies are refused and ${S} part puts and the replacement still go through`, async () => {
        const { id, client } = await account(`reserve-${scope}-${counter}`);
        const records = await prepared(client, S);
        await setUsed(scope, id, { [counter]: LIMITS[scope][counter] - R[counter] - 1 });

        // Normal requests run until what is left of the limit would not exceed the reserve.
        let refused = null;
        for (let i = 0; i < 5 && refused === null; i++) {
          const body = bodyOf({ skill_png: sha256(`${counter}-${i}`) });
          const puts = worker.b2.count("PUT");
          const res = await client.putBodies([body]);
          if (res.status === 429) {
            refused = res;
            assert.equal(worker.b2.count("PUT"), puts, "a refused body reaches no B2");
          } else assert.equal(res.status, 200, res.text);
        }
        assert.notEqual(refused, null, "a normal request was refused before the limit was used up");
        isDailyLimit(refused, scope);
        isDailyLimit(await client.getBodies([records[0].record.body.name]), scope);

        for (const { part } of records) {
          const res = await client.putPart(part);
          assert.deepEqual([res.status, res.body], [200, { name: part.name, status: "stored" }], res.text);
        }
        const full = root(Object.fromEntries(records.map(({ slot, part }) => [String(slot), part.name])));
        const res = await client.replace(0, full);
        assert.deepEqual([res.status, res.body], [200, { generation: 1, root: full.name }], res.text);
      });
    }
  }

  test("with every daily limit used up, parts and replacements are refused too and the generation still answers", async () => {
    const { id, client } = await account("all-used");
    const [{ part }] = await prepared(client, 1);
    await setUsed("account", id, LIMITS.account);
    await setUsed("service", null, LIMITS.service);
    isDailyLimit(await client.putPart(part), "account");
    isDailyLimit(await client.replace(0, root({ 0: part.name })), "account");
    isDailyLimit(await client.settings(), "account");
    const generation = await client.generation();
    assert.deepEqual([generation.status, generation.body], [200, { generation: 0, root: null }]);
  });

  test("a put of a name the account holds answers exists with every limit used up and the caps full, and reaches no B2", async () => {
    const { id, client } = await account("exists");
    await client.setImageForm("png");
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    assert.equal((await client.putBodies([record.body])).status, 200);
    const part = recordPart(0, [record.row]);
    assert.equal((await client.putPart(part)).status, 200);
    assert.equal((await client.replace(0, root({ 0: part.name }))).status, 200);
    assert.equal((await client.putImage(image.name, image.bytes)).status, 200);

    await setUsed("account", id, LIMITS.account);
    await setUsed("service", null, LIMITS.service);
    await addStored(id, limits.ACCOUNT_SYNC_BYTES_CAP);
    await addHiddenToday(id, limits.ACCOUNT_SYNC_HIDDEN_BYTES_CAP + 1);
    const puts = worker.b2.count("PUT");
    const body = await client.putBodies([record.body]);
    assert.deepEqual([body.status, body.body], [200, { results: [{ name: record.body.name, status: "exists" }] }]);
    const img = await client.putImage(image.name, image.bytes);
    assert.deepEqual([img.status, img.body], [200, { name: image.name, status: "exists" }]);
    const again = await client.putPart(part);
    assert.deepEqual([again.status, again.body], [200, { name: part.name, status: "exists" }]);
    assert.equal(worker.b2.count("PUT"), puts);
  });

  test("an account at its records cap may change and delete records but not add one", async () => {
    const { id, client } = await account("records-cap");
    const records = await prepared(client, 2);
    for (const { part } of records) assert.equal((await client.putPart(part)).status, 200);
    assert.equal((await client.replace(0, root({ 0: records[0].part.name }))).status, 200);
    await worker.db.prepare("UPDATE sync_accounts SET record_count = ? WHERE account_id = ?").bind(limits.ACCOUNT_SYNC_RECORDS_CAP, id).run();

    const adding = root({ 0: records[0].part.name, 1: records[1].part.name });
    const refused = await client.replace(1, adding);
    assert.deepEqual([refused.status, refused.body], [507, { error: "account_limit", limit: "records" }]);
    assert.deepEqual((await client.generation()).body, { generation: 1, root: root({ 0: records[0].part.name }).name });

    const rated = recordPart(0, [{ ...records[0].record.row, ratings: { a: 1 } }]);
    assert.equal((await client.putPart(rated)).status, 200);
    assert.equal((await client.replace(1, root({ 0: rated.name }))).status, 200);
    assert.equal((await client.replace(2, root({}))).status, 200);
    assert.equal((await accountRow(id)).record_count, limits.ACCOUNT_SYNC_RECORDS_CAP - 1);
  });

  test("an account one record below its records cap may add one, and at the cap may not", async () => {
    const { id, client } = await account("records-cap-edge");
    const records = await prepared(client, 3);
    for (const { part } of records) assert.equal((await client.putPart(part)).status, 200);
    assert.equal((await client.replace(0, root({ 0: records[0].part.name }))).status, 200);
    await worker.db.prepare("UPDATE sync_accounts SET record_count = ? WHERE account_id = ?").bind(limits.ACCOUNT_SYNC_RECORDS_CAP - 1, id).run();

    const two = root({ 0: records[0].part.name, 1: records[1].part.name });
    const added = await client.replace(1, two);
    assert.equal(added.status, 200, added.text);
    assert.equal((await accountRow(id)).record_count, limits.ACCOUNT_SYNC_RECORDS_CAP);

    const refused = await client.replace(2, root({ 0: records[0].part.name, 1: records[1].part.name, 2: records[2].part.name }));
    assert.deepEqual([refused.status, refused.body], [507, { error: "account_limit", limit: "records" }]);
    assert.deepEqual((await client.generation()).body, { generation: 2, root: two.name });
  });

  test("an account whose referenced bytes are exactly at the cap may change and delete records, is refused new bytes, and gets them back by deleting", async () => {
    const { id, client } = await account("bytes-cap");
    await client.setImageForm("png");
    const images = [newImage(), newImage()];
    const records = images.map((image, slot) => newRecord(slot, { binding: { skill_png: image.name } }));
    const parts = records.map((r, slot) => recordPart(slot, [r.row]));
    for (const r of records) assert.equal((await client.putBodies([r.body])).status, 200);
    for (const p of parts) assert.equal((await client.putPart(p)).status, 200);
    assert.equal((await client.replace(0, root({ 0: parts[0].name, 1: parts[1].name }))).status, 200);
    for (const image of images) assert.equal((await client.putImage(image.name, image.bytes)).status, 200);
    const { stored_bytes: stored } = await accountRow(id);
    await addStored(id, limits.ACCOUNT_SYNC_BYTES_CAP - stored);
    assert.equal((await accountRow(id)).stored_bytes, limits.ACCOUNT_SYNC_BYTES_CAP);

    // Changing a rating stores a new part and a new root: neither is checked against the cap.
    const rated = recordPart(0, [{ ...records[0].row, ratings: { a: 1 } }]);
    assert.equal((await client.putPart(rated)).status, 200);
    assert.equal((await client.replace(1, root({ 0: rated.name, 1: parts[1].name }))).status, 200);

    const fresh = bodyOf({ skill_png: sha256("bytes-cap-fresh") });
    const puts = worker.b2.count("PUT");
    const full = await client.putBodies([fresh]);
    assert.deepEqual([full.status, full.body], [507, { error: "account_limit", limit: "bytes" }]);
    const freshImage = newImage();
    const fullImage = await client.putImage(freshImage.name, freshImage.bytes);
    assert.deepEqual([fullImage.status, fullImage.body], [507, { error: "account_limit", limit: "bytes" }]);
    assert.equal(worker.b2.count("PUT"), puts, "nothing refused reached B2");

    // Deleting a record frees its bytes at once, though B2 keeps them hidden for six days.
    assert.equal((await client.replace(2, root({ 0: rated.name }))).status, 200);
    const freed = await client.putBodies([fresh]);
    assert.deepEqual([freed.status, freed.body], [200, { results: [{ name: fresh.name, status: "stored" }] }]);
  });

  test("the service's budget counts what accounts deleted until B2 may have deleted it", async () => {
    const { client } = await account("budget");
    const [{ part }] = await prepared(client, 1);
    assert.equal((await client.putPart(part)).status, 200);
    assert.equal((await client.replace(0, root({ 0: part.name }))).status, 200);
    const fresh = bodyOf({ skill_png: sha256("budget-fresh") });
    const size = Buffer.byteLength(fresh.body, "utf8");
    // Room in the budget for less than the fresh body, wherever the other tests left the totals.
    const totals = await worker.db.prepare("SELECT stored_bytes, hidden_bytes FROM sync_totals WHERE id = 1").first();
    const goneBy = (await worker.now()) - (limits.B2_DAYS_FROM_HIDING_TO_DELETING * DAY - limits.RESTORE_MARGIN_SECONDS);
    const hidden = Object.entries(JSON.parse(totals.hidden_bytes))
      .filter(([day]) => Number(day) >= Math.floor(goneBy / DAY))
      .reduce((sum, [, bytes]) => sum + bytes, 0);
    const room = limits.SYNC_BUDGET - totals.stored_bytes - hidden;
    await worker.db.prepare("UPDATE sync_totals SET stored_bytes = stored_bytes + ? WHERE id = 1").bind(room - size + 1).run();
    try {
      assert.deepEqual((await client.putBodies([fresh])).body, { error: "storage_full" });
      // Deleting the record frees the account's bytes, not the budget's.
      assert.equal((await client.replace(1, root({}))).status, 200);
      const still = await client.putBodies([fresh]);
      assert.deepEqual([still.status, still.body], [507, { error: "storage_full" }]);

      await worker.advanceClock(limits.B2_DAYS_FROM_HIDING_TO_DELETING * DAY + DAY);
      const after = await client.putBodies([fresh]);
      assert.deepEqual([after.status, after.body], [200, { results: [{ name: fresh.name, status: "stored" }] }]);
    } finally {
      await worker.db.prepare("UPDATE sync_totals SET stored_bytes = stored_bytes - ? WHERE id = 1").bind(room - size + 1).run();
    }
  });

  test("past the hidden cap, new bytes wait for B2 to delete what was hidden while deletions and archives go on", async () => {
    const { id, client } = await account("hidden-cap");
    const records = await prepared(client, 3);
    for (const { part } of records) assert.equal((await client.putPart(part)).status, 200);
    const all = Object.fromEntries(records.map(({ slot, part }) => [String(slot), part.name]));
    assert.equal((await client.replace(0, root(all))).status, 200);
    await addHiddenToday(id, limits.ACCOUNT_SYNC_HIDDEN_BYTES_CAP);

    // Deleting a record hides its body and part: the hidden bytes pass the cap.
    const { 2: _, ...two } = all;
    assert.equal((await client.replace(1, root(two))).status, 200);
    const fresh = bodyOf({ skill_png: sha256("hidden-cap-fresh") });
    const puts = worker.b2.count("PUT");
    const waiting = await client.putBodies([fresh]);
    assert.deepEqual([waiting.status, waiting.body], [507, { error: "hidden_limit" }]);
    const retryAfter = Number(waiting.headers.get("Retry-After"));
    assert.ok(retryAfter > (limits.B2_DAYS_FROM_HIDING_TO_DELETING - 1) * DAY && retryAfter <= (limits.B2_DAYS_FROM_HIDING_TO_DELETING + 1) * DAY, String(retryAfter));
    assert.equal(worker.b2.count("PUT"), puts);

    // An archive (the row keeps no image) and a deletion change nothing the cap guards.
    const archivedPart = recordPart(0, [archived(records[0].record.row, "none")]);
    assert.equal((await client.putPart(archivedPart)).status, 200);
    assert.equal((await client.replace(2, root({ ...two, 0: archivedPart.name }))).status, 200);
    assert.equal((await client.replace(3, root({ 0: archivedPart.name }))).status, 200);
    assert.equal((await client.putBodies([fresh])).status, 507);

    await worker.advanceClock(retryAfter);
    const resumed = await client.putBodies([fresh]);
    assert.deepEqual([resumed.status, resumed.body], [200, { results: [{ name: fresh.name, status: "stored" }] }]);
  });

  test("a name referenced and left hidden counts as referenced, not against the hidden cap", async () => {
    const { id, client } = await account("to-show");
    const records = await prepared(client, 2);
    for (const { part } of records) assert.equal((await client.putPart(part)).status, 200);
    assert.equal((await client.replace(0, root({ 0: records[0].part.name, 1: records[1].part.name }))).status, 200);
    const before = await accountRow(id);
    // What a request cut off between its commit and its show leaves: referenced names hidden.
    const at = await worker.now();
    await worker.db.prepare("UPDATE sync_objects SET hidden_at = ?, hidden_since = ? WHERE account_id = ? AND ref_count > 0").bind(at, at, id).run();
    assert.equal((await accountRow(id)).stored_bytes, before.stored_bytes);
    await addHiddenToday(id, limits.ACCOUNT_SYNC_HIDDEN_BYTES_CAP - Object.values(JSON.parse(before.hidden_bytes)).reduce((a, b) => a + b, 0));

    const fresh = bodyOf({ skill_png: sha256("to-show-fresh") });
    const res = await client.putBodies([fresh]);
    assert.deepEqual([res.status, res.body], [200, { results: [{ name: fresh.name, status: "stored" }] }]);
  });

  test("a name a replacement cut off after its commit left referenced and hidden stops counting against the hidden cap", async () => {
    const { id, client } = await account("to-show-cut");
    await client.setImageForm("png");
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    assert.equal((await client.putImage(image.name, image.bytes)).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER - 60);
    assert.equal((await client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await client.putPart(p0)).status, 200);
    // The replacement looks while nothing is hidden and stops at storing its root; the image is then
    // old enough for the account's next write to hide it.
    const key = (name) => `a/${id}/${name}`;
    const r = root({ 0: p0.name });
    const show = worker.b2.hold("PUT", key(r.name));
    const replaced = client.replace(0, r);
    await show.entered;
    await worker.advanceClock(60);
    assert.equal((await client.putBodies([bodyOf({ skill_png: sha256("to-show-cut-next") })])).status, 200);
    assert.equal(worker.b2.versions(key(image.name)).at(-1), "m");
    // Hidden and nothing references it yet: the image counts, and the account is one byte past the cap.
    const hidden = Object.values(JSON.parse((await accountRow(id)).hidden_bytes)).reduce((a, b) => a + b, 0);
    await addHiddenToday(id, limits.ACCOUNT_SYNC_HIDDEN_BYTES_CAP - hidden + 1);

    // The replacement commits the reference to the image and is cut off before it shows it.
    await worker.cutD1At(SHOW_REFERENCED);
    show.release();
    const cut = await replaced;
    await worker.restoreD1();
    assert.equal(cut.status, 503);
    assert.equal((await client.generation()).body.generation, 1, "the replacement committed");
    const left = await worker.db
      .prepare("SELECT ref_count > 0 AND hidden_at IS NOT NULL AS to_show FROM sync_objects WHERE account_id = ? AND name = ?")
      .bind(id, image.name)
      .first();
    assert.equal(left.to_show, 1, "the image is referenced and hidden");

    const fresh = bodyOf({ skill_png: sha256("to-show-cut-fresh") });
    const res = await client.putBodies([fresh]);
    assert.deepEqual([res.status, res.body], [200, { results: [{ name: fresh.name, status: "stored" }] }]);
  });

  /**
   * Makes the room `admitDatabase` reads for sync `room` bytes: DATABASE_BUDGET less the size D1 reports
   * less what sharing has not used of STORAGE_BUDGET. The size is read with the statement the check
   * runs; reading changes nothing, so the next request's check reads the same size until it writes.
   */
  async function leaveDatabaseRoom(room) {
    await worker.addToDatabaseSize(0);
    const result = await worker.db.prepare("SELECT bytes FROM totals WHERE id = 1").all();
    const sharingRoom = Math.max(0, limits.STORAGE_BUDGET - result.results[0].bytes);
    await worker.addToDatabaseSize(limits.DATABASE_BUDGET - result.meta.size_after - sharingRoom - room);
  }

  const isDatabaseFull = (res) => assert.deepEqual([res.status, res.body], [507, { error: "database_full" }], res.text);

  test("a put of new bodies is refused database_full once the database's room is not more than the reserve, and reaches no B2", async () => {
    const { client } = await account("database-normal");
    try {
      await leaveDatabaseRoom(R.database_bytes + 1);
      const before = bodyOf({ skill_png: sha256("database-normal-before") });
      const stored = await client.putBodies([before]);
      assert.deepEqual([stored.status, stored.body], [200, { results: [{ name: before.name, status: "stored" }] }], stored.text);

      for (const room of [R.database_bytes, -1]) {
        await leaveDatabaseRoom(room);
        const puts = worker.b2.count("PUT");
        isDatabaseFull(await client.putBodies([bodyOf({ skill_png: sha256(`database-normal-${room}`) })]));
        assert.equal(worker.b2.count("PUT"), puts, `room ${room}: a refused body reaches no B2`);
        // A name the account holds stores nothing, so it is not checked.
        const again = await client.putBodies([before]);
        assert.deepEqual([again.status, again.body], [200, { results: [{ name: before.name, status: "exists" }] }]);
      }
    } finally {
      await worker.addToDatabaseSize(0);
    }
  });

  test("part puts and replacements use the database's reserve and are refused database_full once no room is left", async () => {
    const { client } = await account("database-reserve");
    const records = await prepared(client, 3);
    try {
      // Within the reserve: bodies are refused, a part and its replacement go through.
      await leaveDatabaseRoom(R.database_bytes);
      isDatabaseFull(await client.putBodies([bodyOf({ skill_png: sha256("database-reserve") })]));
      assert.equal((await client.putPart(records[0].part)).status, 200);
      const one = root({ 0: records[0].part.name });
      assert.equal((await client.replace(0, one)).status, 200);

      await leaveDatabaseRoom(1);
      assert.equal((await client.putPart(records[1].part)).status, 200);
      await leaveDatabaseRoom(0);
      isDatabaseFull(await client.replace(1, root({ 0: records[0].part.name, 1: records[1].part.name })));
      isDatabaseFull(await client.putPart(records[2].part));
      await leaveDatabaseRoom(-1);
      isDatabaseFull(await client.replace(1, root({ 0: records[0].part.name, 1: records[1].part.name })));
      assert.deepEqual((await client.generation()).body, { generation: 1, root: one.name }, "a refused replacement changed nothing");

      await leaveDatabaseRoom(1);
      const two = root({ 0: records[0].part.name, 1: records[1].part.name });
      const res = await client.replace(1, two);
      assert.deepEqual([res.status, res.body], [200, { generation: 2, root: two.name }], res.text);
    } finally {
      await worker.addToDatabaseSize(0);
    }
  });

  test("a database sync has filled still takes shares into sharing's own part", async () => {
    const token = await worker.signIn("database-share");
    const client = syncClient(worker, token);
    try {
      await leaveDatabaseRoom(-1);
      isDatabaseFull(await client.putBodies([bodyOf({ skill_png: sha256("database-share") })]));
      const res = await worker.share(token, [{ client_key: newClientKey(), record: postedForm() }]);
      assert.equal(res.status, 200);
      assert.equal((await res.json()).results[0].status, "created");
    } finally {
      await worker.addToDatabaseSize(0);
    }
  });

  test("with no room left in the database, fetches, the hourly run's hides and an account's deletion go on", async () => {
    const { id, client, token } = await account("database-shrink");
    const [{ record, part }] = await prepared(client, 1);
    assert.equal((await client.putPart(part)).status, 200);
    assert.equal((await client.replace(0, root({ 0: part.name }))).status, 200);
    // A body put and referenced by nothing, old enough to hide.
    const left = bodyOf({ skill_png: sha256("database-shrink-left") });
    assert.equal((await client.putBodies([left])).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    try {
      await leaveDatabaseRoom(-limits.DATABASE_BUDGET);
      const fetched = await client.getBodies([record.body.name]);
      assert.deepEqual([fetched.status, fetched.body], [200, { bodies: [record.body] }], fetched.text);
      assert.equal(await worker.scheduled(), "ok");
      assert.equal(worker.b2.versions(`a/${id}/${left.name}`).at(-1), "m", "the hourly run hid what nothing referenced");

      const answers = [];
      for (let i = 0; i < 10 && answers.at(-1)?.status !== 204; i++) {
        answers.push(await worker.fetch("/api/me", { method: "DELETE", headers: { Authorization: `Bearer ${token}` } }));
      }
      assert.equal(answers.at(-1).status, 204, `answered ${answers.map((r) => r.status)}`);
      const rows = await worker.db.prepare("SELECT count(*) AS n FROM sync_objects WHERE account_id = ?").bind(id).first();
      assert.equal(rows.n, 0);
    } finally {
      await worker.addToDatabaseSize(0);
    }
  });

  test("the rows the hourly run deletes a day past the boundary give their room back to the database", async () => {
    const { id, client } = await account("database-forget");
    // What a sync hid nine days ago leaves, as the rows are then: gone, referenced by nothing, a marker
    // recorded. Parts, whose rows are the largest: 2,000 parts of 40 bodies each, a few megabytes.
    const refs = JSON.stringify({ always: Object.fromEntries(Array.from({ length: 40 }, (_, i) => [sha256(`database-forget-${i}`), "body"])), pending: [] });
    const then = (await worker.now()) - 9 * DAY;
    await worker.db
      .prepare(
        `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
         INSERT INTO sync_objects (account_id, name, kind, size, slot, record_count, refs, stored_at, ref_count, hidden_at, hidden_since, marker)
         SELECT ?1, lower(hex(randomblob(32))), 'part', 2000, '0', 40, ?2, ?3, 0, ?3, ?3, 'marker' FROM n`,
      )
      .bind(id, refs, then)
      .run();
    try {
      await leaveDatabaseRoom(R.database_bytes);
      isDatabaseFull(await client.putBodies([bodyOf({ skill_png: sha256("database-forget-before") })]));
      assert.equal(await worker.scheduled(), "ok");
      const rows = await worker.db.prepare("SELECT count(*) AS n FROM sync_objects WHERE account_id = ?").bind(id).first();
      assert.equal(rows.n, 0);
      const fresh = bodyOf({ skill_png: sha256("database-forget-after") });
      const res = await client.putBodies([fresh]);
      assert.deepEqual([res.status, res.body], [200, { results: [{ name: fresh.name, status: "stored" }] }], res.text);
    } finally {
      await worker.addToDatabaseSize(0);
    }
  });

  // Called directly: the harness's D1 always reports a size, so no request can reach a D1 that does not.
  test("a D1 that reports no database size refuses every write the database's room checks, rather than admitting it", async () => {
    const db = { prepare: () => ({ all: async () => ({ results: [{ bytes: 0 }], meta: {} }) }) };
    for (const use of ["normal", "reserve"]) {
      await assert.rejects(admitDatabase(db, use), (error) => error instanceof Unavailable, use);
    }
  });

  test("the rows a sync write is charged for do not grow with the rows its account holds", async () => {
    // 20,000 rows: about what a 5,000-record account holds. Stored and referenced, so no leftover state.
    const extra = 20_000;
    const charged = async (sub, rows) => {
      const { id, client } = await account(sub);
      await worker.db
        .prepare(
          `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?2)
           INSERT INTO sync_objects (account_id, name, kind, size, stored_at, ref_count)
           SELECT ?1, lower(hex(randomblob(32))), 'body', 1, 1, 1 FROM n WHERE ?2 > 0`,
        )
        .bind(id, rows)
        .run();
      await setUsed("account", id, {});
      const res = await client.putBodies(Array.from({ length: limits.MAX_SYNC_BODIES_PER_REQUEST }, () => newRecord(0).body));
      assert.equal(res.status, 200, res.text);
      return (await worker.db.prepare("SELECT daily_rows_read r, daily_rows_written w FROM sync_accounts WHERE account_id = ?").bind(id).first());
    };
    const small = await charged("rows-small", 0);
    const large = await charged("rows-large", extra);
    assert.ok(large.r - small.r < extra / 100, `read ${large.r} with ${extra} rows more, ${small.r} without`);
    assert.ok(large.w - small.w < extra / 100, `written ${large.w} with ${extra} rows more, ${small.w} without`);
  });

  test("the hourly run deletes the service's daily counters before yesterday, and today's goes on counting", async () => {
    const { client } = await account("daily-forget");
    const first = await today();
    for (let i = 0; i < 2; i++) {
      await worker.advanceClock(DAY);
      assert.equal((await client.settings()).status, 200);
    }
    const days = async () => (await worker.db.prepare("SELECT day FROM sync_daily ORDER BY day").all()).results.map((r) => r.day);
    assert.deepEqual(await days(), [first, first + 1, first + 2]);
    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual(await days(), [first + 1, first + 2]);
    const requests = async () => (await worker.db.prepare("SELECT requests FROM sync_daily WHERE day = ?").bind(first + 2).first()).requests;
    const counted = await requests();
    assert.equal((await client.settings()).status, 200);
    assert.equal(await requests(), counted + 1);
  });
});
