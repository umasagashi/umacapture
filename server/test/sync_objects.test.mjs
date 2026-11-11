// File sync's objects (GET /api/sync/generation, POST /api/sync/bodies, POST /api/sync/bodies/get,
// PUT and GET /api/sync/images/<name>), the account's image form (GET and PUT /api/sync/settings)
// and the sync switch, driven over HTTP against a real (local)
// D1 and the in-memory B2 bucket of the harness, with sessions claimed through the login. An object
// is fetched once the list references it: until then it is hidden (sync_retention.test.mjs).

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import * as limits from "../src/limits.mjs";
import { answer, archived, bodyOf, idIn, newImage, newRecord, recordPart, root, sha256, syncClient } from "./support/sync_fixtures.mjs";
import { migrationStatements, startWorker } from "./support/worker_harness.mjs";

/** A fresh body text carrying an image binding (by default to a fresh PNG name), and its name. */
const newBody = (skillPng = sha256(randomBytes(8))) => bodyOf({ skill_png: skillPng, skill_jpeg: null });

/** Makes `bodies` (stored) the whole list of `client`'s account, as records in part 0. */
async function reference(client, bodies) {
  const rows = bodies.map(({ name, body }) => ({
    id: idIn(0),
    body: { name },
    archive: { state: "normal" },
    image: JSON.parse(body).metadata.binding,
  }));
  const p = recordPart(0, rows);
  assert.equal((await client.putPart(p)).status, 200);
  const { generation } = (await client.generation()).body;
  const res = await client.replace(generation, root({ 0: p.name }));
  assert.equal(res.status, 200, res.text);
}

/** The sync_objects rows of `accountId` as `name kind`, sorted. */
async function rows(worker, accountId) {
  const result = await worker.db
    .prepare("SELECT name, kind FROM sync_objects WHERE account_id = ? ORDER BY name")
    .bind(accountId)
    .all();
  return result.results.map((r) => `${r.name} ${r.kind}`);
}

describe("sync objects", () => {
  let worker;
  let account;
  let client;
  before(async () => {
    worker = await startWorker();
    const token = await worker.signIn("sync-owner");
    account = await worker.accountOf(token);
    client = syncClient(worker, token);
    // Images are put under the PNG form: these tests are about storing, not about the form.
    assert.equal((await client.setImageForm("png")).status, 200);
  });
  after(() => worker.dispose());

  test("an account that never synced is at generation 0 with no root", async () => {
    const res = await client.generation();
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { generation: 0, root: null });
  });

  test("ten bodies are put and fetched in one request each, and eleven are refused either way", async () => {
    const bodies = Array.from({ length: limits.MAX_SYNC_BODIES_PER_REQUEST }, newBody);
    const put = await client.putBodies(bodies);
    assert.equal(put.status, 200, put.text);
    assert.deepEqual(put.body.results, bodies.map(({ name }) => ({ name, status: "stored" })));
    const stored = await rows(worker, account);
    for (const { name } of bodies) assert.ok(stored.includes(`${name} body`));

    await reference(client, bodies);
    for (const { name, body } of bodies) {
      assert.equal(Buffer.from(worker.b2.visible(`a/${account}/${name}`)).toString("utf8"), body);
    }
    const got = await client.getBodies(bodies.map((b) => b.name));
    assert.equal(got.status, 200, got.text);
    assert.deepEqual(got.body.bodies, bodies);

    const eleven = [...bodies, newBody()];
    const putEleven = await client.putBodies(eleven);
    assert.deepEqual([putEleven.status, putEleven.body], [400, { error: "invalid_payload", field: "bodies" }]);
    assert.equal(worker.b2.visible(`a/${account}/${eleven[10].name}`), null);
    const getEleven = await client.getBodies(eleven.map((b) => b.name));
    assert.deepEqual([getEleven.status, getEleven.body], [400, { error: "invalid_payload", field: "names" }]);
  });

  test("a body whose name is not the SHA-256 of its bytes is refused with 400, and nothing of the request is stored", async () => {
    const good = newBody();
    const bad = { name: newBody().name, body: newBody().body };
    const before = [await rows(worker, account), worker.b2.count("PUT")];
    const res = await client.putBodies([good, bad]);
    assert.deepEqual([res.status, res.body], [400, { error: "invalid_payload", field: "bodies[1].name" }]);
    assert.deepEqual([await rows(worker, account), worker.b2.count("PUT")], before);
    assert.deepEqual(worker.b2.keys(`a/${account}/${good.name}`), []);
    assert.deepEqual(worker.b2.keys(`a/${account}/${bad.name}`), []);
  });

  test("an image is stored only when its bytes hash to its name; B2's refusal is 502 storage_refused", async () => {
    const bytes = randomBytes(2048);
    const name = sha256(bytes);
    const put = await client.putImage(name, bytes);
    assert.deepEqual([put.status, put.body], [200, { name, status: "stored" }]);
    const body = newBody(name);
    assert.equal((await client.putBodies([body])).status, 200);
    await reference(client, [body]);
    assert.deepEqual(await client.getImage(name), { status: 200, type: "image/png", bytes });

    const claimed = sha256(randomBytes(2048));
    const refused = await client.putImage(claimed, randomBytes(2048), "image/jpeg");
    assert.deepEqual([refused.status, refused.body], [502, { error: "storage_refused" }]);
    assert.equal(worker.b2.count("PUT", `a/${account}/${claimed}`), 1, "a 403 is not retried");
    assert.equal(worker.b2.visible(`a/${account}/${claimed}`), null);
    assert.ok(!(await rows(worker, account)).some((r) => r.startsWith(claimed)));
    assert.equal((await client.getImage(claimed)).status, 404);
  });

  test("an image put B2 answers 503 SlowDown once is stored by the Worker's retry", async () => {
    const { name, bytes } = newImage();
    // No Retry-After: the Worker waits B2_RETRY_FIRST_WAIT before the retry.
    worker.b2.failPuts(`a/${account}/${name}`, [{ status: 503, code: "SlowDown" }]);
    const put = await client.putImage(name, bytes);
    assert.deepEqual([put.status, put.body], [200, { name, status: "stored" }]);
    assert.equal(worker.b2.count("PUT", `a/${account}/${name}`), 2);
    assert.deepEqual(Buffer.from(worker.b2.visible(`a/${account}/${name}`)), bytes);
  });

  test("an image put whose 503 is cut off while its error arrives is stored by the Worker's retry, and the log says the error went unread", async () => {
    const { name, bytes } = newImage();
    worker.b2.failPuts(`a/${account}/${name}`, [{ status: 503, cut: true }]);
    const put = await client.putImage(name, bytes);
    assert.deepEqual([put.status, put.body], [200, { name, status: "stored" }]);
    assert.equal(worker.b2.count("PUT", `a/${account}/${name}`), 2);
    assert.deepEqual(Buffer.from(worker.b2.visible(`a/${account}/${name}`)), bytes);
    const line = `B2 PUT answered 503 (error unread), attempt 1 of ${limits.B2_ATTEMPTS}, retrying in`;
    const deadline = Date.now() + 5_000;
    while (!worker.logs().includes(line) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    assert.ok(worker.logs().includes(line), worker.logs());
  });

  test("a body put B2 answers 503 on every attempt fails its whole request 502 storage_unavailable, and the log names B2's answer and nothing of the account", async () => {
    const bodies = Array.from({ length: limits.MAX_SYNC_BODIES_PER_REQUEST }, newBody);
    const key = `a/${account}/${bodies[3].name}`;
    worker.b2.failPuts(key, Array(limits.B2_ATTEMPTS).fill({ status: 503, code: "SlowDown", retryAfter: "0" }));
    const put = await client.putBodies(bodies);
    assert.deepEqual([put.status, put.body], [502, { error: "storage_unavailable" }]);
    assert.equal(worker.b2.count("PUT", key), limits.B2_ATTEMPTS);
    const stored = await rows(worker, account);
    assert.ok(bodies.every(({ name }) => !stored.some((r) => r.startsWith(name))), "no body of the request recorded");

    const line = `B2 PUT answered 503 SlowDown (Retry-After "0"), attempt ${limits.B2_ATTEMPTS} of ${limits.B2_ATTEMPTS}`;
    const deadline = Date.now() + 5_000;
    while (!worker.logs().includes(line) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    const logs = worker.logs();
    assert.ok(logs.includes(line), logs);
    assert.ok(!logs.includes(account) && !logs.includes(bodies[3].name), "neither the account id nor a name");
  });

  test("a put B2 asks to wait longer than B2_RETRY_WAIT_MAX is not retried", async () => {
    const body = newBody();
    const key = `a/${account}/${body.name}`;
    worker.b2.failPuts(key, [{ status: 503, code: "SlowDown", retryAfter: String(limits.B2_RETRY_WAIT_MAX + 1) }]);
    const put = await client.putBodies([body]);
    assert.deepEqual([put.status, put.body], [502, { error: "storage_unavailable" }]);
    assert.equal(worker.b2.count("PUT", key), 1);
  });

  test("a name the account holds answers exists, and no PUT reaches B2", async () => {
    const body = newBody();
    assert.equal((await client.putBodies([body])).status, 200);
    const again = await client.putBodies([body]);
    assert.deepEqual(again.body.results, [{ name: body.name, status: "exists" }]);
    assert.equal(worker.b2.count("PUT", `a/${account}/${body.name}`), 1);

    const bytes = randomBytes(512);
    const name = sha256(bytes);
    assert.equal((await client.putImage(name, bytes)).status, 200);
    const image = await client.putImage(name, bytes);
    assert.deepEqual([image.status, image.body], [200, { name, status: "exists" }]);
    assert.equal(worker.b2.count("PUT", `a/${account}/${name}`), 1);
  });

  test("a request without a session is 401", async () => {
    const anonymous = syncClient(worker, null);
    assert.equal((await anonymous.generation()).status, 401);
    assert.equal((await anonymous.putBodies([newBody()])).status, 401);
    assert.equal((await anonymous.getImage(sha256("x"))).status, 401);
  });
});

describe("sync isolation between accounts", () => {
  let worker;
  let owner;
  let other;
  let otherAccount;
  before(async () => {
    worker = await startWorker();
    owner = syncClient(worker, await worker.signIn("sync-owner"));
    const otherToken = await worker.signIn("sync-other");
    otherAccount = await worker.accountOf(otherToken);
    other = syncClient(worker, otherToken);
    // Images are put under the PNG form: these tests are about storing, not about the form.
    for (const c of [owner, other]) assert.equal((await c.setImageForm("png")).status, 200);
  });
  after(() => worker.dispose());

  test("another account's session can fetch none of the account's objects, and a put of the same name stores its own copy", async () => {
    const bytes = randomBytes(1024);
    const image = sha256(bytes);
    const body = newBody(image);
    assert.equal((await owner.putBodies([body])).status, 200);
    assert.equal((await owner.putImage(image, bytes)).status, 200);
    await reference(owner, [body]);
    assert.deepEqual((await owner.getImage(image)).bytes, bytes);

    const bodies = await other.getBodies([body.name]);
    assert.deepEqual([bodies.status, bodies.body], [404, { error: "not_found", names: [body.name] }]);
    assert.equal((await other.getImage(image)).status, 404);

    const put = await other.putBodies([body]);
    assert.deepEqual(put.body.results, [{ name: body.name, status: "stored" }]);
    assert.equal(worker.b2.count("PUT", `a/${otherAccount}/${body.name}`), 1);
    const putImage = await other.putImage(image, bytes);
    assert.deepEqual(putImage.body, { name: image, status: "stored" });
    await reference(other, [body]);
    assert.deepEqual((await other.getBodies([body.name])).body.bodies, [body]);
    assert.deepEqual((await other.getImage(image)).bytes, bytes);
  });
});

describe("the sync switch", () => {
  let worker;
  let token;
  before(async () => {
    worker = await startWorker({ vars: { SYNC_ENABLED: "false" } });
    token = await worker.signIn("sync-paused");
  });
  after(() => worker.dispose());

  test("SYNC_ENABLED=false answers every /api/sync/ endpoint 503 sync_paused, while logins and the account go on", async () => {
    const client = syncClient(worker, token);
    const bytes = randomBytes(64);
    for (const res of [
      await client.generation(),
      await client.putBodies([newBody()]),
      await client.getBodies([sha256("x")]),
      await client.putImage(sha256(bytes), bytes),
    ]) {
      assert.deepEqual([res.status, res.body], [503, { error: "sync_paused" }]);
    }
    assert.equal((await client.getImage(sha256("x"))).status, 503);
    assert.deepEqual(worker.b2.requests, []);
    assert.equal((await answer(worker.fetch("/api/me", { headers: { Authorization: `Bearer ${token}` } }))).status, 200);
    assert.equal((await answer(worker.myShares(token))).status, 200);
  });
});

describe("sync image form", () => {
  // The account's image form (PNG, reduced JPEG or none, reduced JPEG until it chooses) decides which new
  // images it may put. Under none, the one image taken is the reduced JPEG an archive puts in place of
  // its PNG, and only once the current root says so.
  let worker;
  before(async () => {
    worker = await startWorker();
  });
  after(() => worker.dispose());

  /** A fresh account: `{id, client, key, replace}`, replace(parts) from the generation it last reached. */
  async function account(sub) {
    const token = await worker.signIn(sub);
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    let generation = 0;
    return {
      id,
      client,
      key: (name) => `a/${id}/${name}`,
      async replace(parts) {
        const res = await client.replace(generation, root(Object.fromEntries(Object.entries(parts).map(([s, p]) => [s, p.name]))));
        assert.equal(res.status, 200, res.text);
        generation++;
      },
    };
  }

  /** Puts `records`' bodies and part `n` of their rows; returns the part. */
  async function putPart(client, n, records) {
    assert.equal((await client.putBodies(records.map((r) => r.body))).status, 200);
    const p = recordPart(n, records.map((r) => r.row));
    assert.equal((await client.putPart(p)).status, 200);
    return p;
  }

  const refused = (res) => assert.deepEqual([res.status, res.body], [409, { error: "images_not_synced" }]);

  test("a new account syncs reduced JPEGs, before its row is made and after", async () => {
    const a = await account("form-new");
    const hasRow = async () =>
      (await worker.db.prepare("SELECT 1 FROM sync_accounts WHERE account_id = ?").bind(a.id).first()) !== null;
    assert.equal(await hasRow(), false);
    assert.deepEqual((await a.client.settings()).body, { image_form: "jpeg" }, "the answer for an account with no row");
    assert.equal(await hasRow(), true, "the request's charge made the row, with the column's default");
    assert.deepEqual((await a.client.settings()).body, { image_form: "jpeg" }, "the form the row was made with");
    const jpeg = newImage();
    assert.equal((await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg")).body.status, "stored");
  });

  test("a change of the form takes effect from the next request", async () => {
    const a = await account("form-switch");
    assert.equal((await a.client.setImageForm("none")).status, 200);
    const [png, jpeg] = [newImage(), newImage()];
    refused(await a.client.putImage(png.name, png.bytes));
    refused(await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg"));
    assert.deepEqual(worker.b2.versions(a.key(png.name)), [], "nothing reached B2");
    assert.deepEqual(worker.b2.versions(a.key(jpeg.name)), []);

    assert.deepEqual((await a.client.setImageForm("png")).body, { image_form: "png" });
    assert.deepEqual((await a.client.settings()).body, { image_form: "png" });
    assert.equal((await a.client.putImage(png.name, png.bytes)).body.status, "stored");

    assert.equal((await a.client.setImageForm("none")).status, 200);
    refused(await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg"));
    assert.equal((await a.client.putImage(png.name, png.bytes)).body.status, "exists", "a name held is no new image");
    assert.equal((await a.client.setImageForm("jpeg")).status, 200);
    assert.equal((await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg")).body.status, "stored");

    const bad = await a.client.setImageForm("webp");
    assert.deepEqual([bad.status, bad.body], [400, { error: "invalid_payload", field: "image_form" }]);
    assert.deepEqual((await a.client.settings()).body, { image_form: "jpeg" });
  });

  test("under none, a record's icon is refused though the root references it", async () => {
    const a = await account("form-icon");
    assert.equal((await a.client.setImageForm("none")).status, 200);
    const icon = newImage();
    await a.replace({ 0: await putPart(a.client, 0, [newRecord(0, { icon: icon.name })]) });
    refused(await a.client.putImage(icon.name, icon.bytes, "image/jpeg"));
    assert.deepEqual(worker.b2.versions(a.key(icon.name)), []);
  });

  test("under none, an archive's reduced JPEG is refused while only its part is put, and taken once the root names that part, the PNG's references moving to it", async () => {
    const a = await account("form-archive");
    const [png, jpeg] = [newImage(), newImage()];
    const binding = { skill_png: png.name, skill_jpeg: jpeg.name };
    const record = newRecord(0, { binding });
    assert.equal((await a.client.setImageForm("png")).status, 200);
    assert.equal((await a.client.putImage(png.name, png.bytes)).status, 200);
    await a.replace({ 0: await putPart(a.client, 0, [record]) });
    assert.equal((await a.client.setImageForm("none")).status, 200);

    // Archived on the device: the part with the row's state reduced JPEG is put, the root is still normal.
    const p0 = recordPart(0, [archived(record.row, "jpeg")]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    refused(await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg"));
    assert.deepEqual(worker.b2.versions(a.key(jpeg.name)), []);

    await a.replace({ 0: p0 });
    assert.equal((await a.client.getImage(png.name)).status, 200, "until the JPEG is stored, the PNG is referenced");
    assert.equal((await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg")).body.status, "stored");
    assert.equal((await a.client.getImage(jpeg.name)).status, 200);
    assert.equal((await a.client.getImage(png.name)).status, 404, "the references moved off the PNG");
    assert.equal(worker.b2.versions(a.key(png.name)).at(-1), "m");
  });

  test("under none, an archive's reduced JPEG is refused once a later root takes the archive back", async () => {
    const a = await account("form-archive-undone");
    const [png, jpeg] = [newImage(), newImage()];
    const record = newRecord(0, { binding: { skill_png: png.name, skill_jpeg: jpeg.name } });
    assert.equal((await a.client.setImageForm("png")).status, 200);
    assert.equal((await a.client.putImage(png.name, png.bytes)).status, 200);
    const normal = await putPart(a.client, 0, [record]);
    await a.replace({ 0: normal });
    assert.equal((await a.client.setImageForm("none")).status, 200);

    const p0 = recordPart(0, [archived(record.row, "jpeg")]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    await a.replace({ 0: p0 });
    // Undone on the device before the JPEG was sent: the root names the normal row again.
    await a.replace({ 0: normal });
    refused(await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg"));
    assert.deepEqual(worker.b2.versions(a.key(jpeg.name)), [], "nothing reached B2");
  });

  test("under none, a JPEG the root does not reference in place of a held PNG is refused", async () => {
    const a = await account("form-not-archive");
    const [png, normalJpeg, absent, absentJpeg] = Array.from({ length: 4 }, newImage);
    // A normal row naming a JPEG: the root references it, but not in a PNG's place.
    const normal = newRecord(0, { binding: { skill_png: png.name, skill_jpeg: normalJpeg.name } });
    // A reduced-JPEG row whose PNG the server never stored.
    const reduced = newRecord(1, { state: "jpeg", binding: { skill_png: absent.name, skill_jpeg: absentJpeg.name } });
    assert.equal((await a.client.setImageForm("png")).status, 200);
    assert.equal((await a.client.putImage(png.name, png.bytes)).status, 200);
    assert.equal((await a.client.setImageForm("none")).status, 200);
    await a.replace({ 0: await putPart(a.client, 0, [normal]), 1: await putPart(a.client, 1, [reduced]) });
    refused(await a.client.putImage(normalJpeg.name, normalJpeg.bytes, "image/jpeg"));
    refused(await a.client.putImage(absentJpeg.name, absentJpeg.bytes, "image/jpeg"));
    refused(await a.client.putImage(absent.name, absent.bytes));
    for (const image of [normalJpeg, absentJpeg, absent]) assert.deepEqual(worker.b2.versions(a.key(image.name)), []);
  });
});

describe("the reduced-JPEG default across its migration", () => {
  // 0011_sync_image_form_default.sql makes sync_accounts anew with the default 'jpeg'. An account that
  // has a row before it keeps the form the row holds, the old default 'none' included: it cannot be
  // told apart from a 'none' chosen.
  const MIGRATION = "0011_sync_image_form_default.sql";
  let worker;
  before(async () => {
    worker = await startWorker({ migrate: false });
    await worker.db.batch(migrationStatements(undefined, (f) => f < MIGRATION).map((s) => worker.db.prepare(s)));
  });
  after(() => worker.dispose());

  test("an account with a row keeps its form and its generation, and only a new account takes reduced JPEGs", async () => {
    const defaulted = syncClient(worker, await worker.signIn("before-default"));
    assert.equal((await defaulted.settings()).status, 200, "its charge makes the row, with the old default");
    assert.deepEqual((await defaulted.settings()).body, { image_form: "none" });

    const chose = syncClient(worker, await worker.signIn("before-png"));
    assert.equal((await chose.setImageForm("png")).status, 200);
    const record = newRecord(0);
    assert.equal((await chose.putBodies([record.body])).status, 200);
    const p = recordPart(0, [record.row]);
    assert.equal((await chose.putPart(p)).status, 200);
    assert.equal((await chose.replace(0, root({ 0: p.name }))).status, 200);

    // Every column of this row holds a value no other column holds, so a copy that moves a value to
    // another column changes the row.
    const distinct = await worker.accountOf(await worker.signIn("before-every-column"));
    await worker.db
      .prepare(
        `INSERT INTO sync_accounts (account_id, generation, root_name, image_form, stored_bytes, hidden_bytes, record_count,
           last_synced_day, daily_day, daily_requests, daily_rows_read, daily_rows_written)
         VALUES (?1, 17, 'root-17', 'png', 1000, '{"20000":5}', 29, 20001, 20002, 3, 41, 53)`,
      )
      .bind(distinct)
      .run();
    const table = async () => (await worker.db.prepare("SELECT * FROM sync_accounts ORDER BY account_id").all()).results;
    const before = await table();

    await worker.db.batch(migrationStatements(undefined, (f) => f >= MIGRATION).map((s) => worker.db.prepare(s)));
    assert.deepEqual(await table(), before, "every row keeps every column, the nullable ones included");

    // The usage triggers of 0003_sync.sql add to and take off the migrated table.
    const usage = async () =>
      await worker.db.prepare("SELECT stored_bytes, hidden_bytes FROM sync_accounts WHERE account_id = ?1").bind(distinct).first();
    const object = (name, refCount) =>
      worker.db
        .prepare(
          `INSERT INTO sync_objects (account_id, name, kind, size, stored_at, ref_count) VALUES (?1, ?2, 'png', 7, ?3, ?4)`,
        )
        .bind(distinct, name, 20003 * 86400, refCount)
        .run();
    await object("a".repeat(64), 1);
    await object("b".repeat(64), 0);
    assert.deepEqual(await usage(), { stored_bytes: 1007, hidden_bytes: '{"20000":5,"20003":7}' });
    await worker.db.prepare("DELETE FROM sync_objects WHERE account_id = ?1").bind(distinct).run();
    assert.deepEqual(await usage(), { stored_bytes: 1000, hidden_bytes: '{"20000":5,"20003":0}' });

    assert.deepEqual((await defaulted.settings()).body, { image_form: "none" });
    assert.deepEqual((await chose.settings()).body, { image_form: "png" });
    assert.deepEqual((await chose.generation()).body, { generation: 1, root: root({ 0: p.name }).name });
    const image = newImage();
    assert.equal((await chose.putImage(image.name, image.bytes)).body.status, "stored", "the usage triggers reach the new table");

    const fresh = syncClient(worker, await worker.signIn("after"));
    assert.deepEqual((await fresh.settings()).body, { image_form: "jpeg" }, "the answer for an account with no row");
    assert.deepEqual((await fresh.settings()).body, { image_form: "jpeg" }, "the row made after the migration");
  });
});
