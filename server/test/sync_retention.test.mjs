// File sync's references and retention: an object the account's current root references nothing of
// is hidden in B2 (a delete marker over its version, for B2's lifecycle to delete), and shown again
// when a replacement references it; what a put stores is hidden only once it is SYNC_ABANDONED_AFTER
// old, by the account's next write or the hourly run, so a test moves the Worker's clock on to have it
// hidden. Read through HTTP and the in-memory bucket's versions, never through the reference counts.
// The concurrent cases stop B2's side with the bucket's hold, a replacement at storing its root. A request
// cut off between a reference falling and its hide is made by failing D1 at the hide's first
// statement; what it leaves is read from the rows sync_objects_to_hide indexes, the record the next
// write and the hourly run hide from. One left inside a hide or a show is made by cutting D1 off right
// after that statement, or by failing B2's DeleteObjects.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import * as limits from "../src/limits.mjs";
import { usage } from "../src/sync_quota.mjs";
import { named, STATEMENT, tidyLeftoversOf } from "../src/sync_refs.mjs";
import { archived, newImage, newRecord, recordPart, root, syncClient } from "./support/sync_fixtures.mjs";
import { startWorker } from "./support/worker_harness.mjs";

/** A hide's first statement (`settle`'s intent), by its name: failing it cuts a request off before it hides. */
const HIDE_INTENT = named(STATEMENT.HIDE_INTENT);

/** A hide's (c), recording its markers, by its name: cutting D1 off after it stops a hide before it gives any back. */
const HIDE_RECORD = named(STATEMENT.HIDE_RECORD);

/** A replacement's first statement after its commit (`showReferenced`), by its name: failing it cuts the replacement off there. */
const SHOW_REFERENCED = named(STATEMENT.SHOW_REFERENCED);

/** A put's record of what B2 stored, by its name: cutting D1 off there leaves the object in B2 with no row. */
const PUT_RECORD = named(STATEMENT.PUT_RECORD);

/** The names of account `id` (every account when null) whose hide is still to do, through their index. */
async function toHide(worker, id = null) {
  const where = "ref_count = 0 AND hidden_at IS NULL AND stored_at IS NOT NULL";
  const rows =
    id === null
      ? await worker.db.prepare(`SELECT name FROM sync_objects INDEXED BY sync_objects_to_hide WHERE ${where}`).all()
      : await worker.db.prepare(`SELECT name FROM sync_objects INDEXED BY sync_objects_to_hide WHERE account_id = ?1 AND ${where}`).bind(id).all();
  return rows.results.map((r) => r.name).sort();
}

describe("sync retention", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  /** A fresh account: `{id, client, key, shown, versions, replace}`. */
  async function account(sub) {
    const token = await worker.signIn(sub);
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    const key = (name) => `a/${id}/${name}`;
    let generation = 0;
    return {
      id,
      client,
      key,
      /** Whether B2's latest version of `name` is an object, not a delete marker. */
      shown: (name) => worker.b2.visible(key(name)) !== null,
      versions: (name) => worker.b2.versions(key(name)),
      /** Replaces the root with `parts` (slot → part) from the generation it last reached. */
      async replace(parts) {
        const r = root(Object.fromEntries(Object.entries(parts).map(([s, p]) => [s, p.name])));
        const res = await client.replace(generation, r);
        assert.equal(res.status, 200, res.text);
        generation++;
        return r;
      },
    };
  }

  /** Puts the bodies of `records` and part `n` of their rows; returns the part. */
  async function putPart(client, n, records) {
    assert.equal((await client.putBodies(records.map((r) => r.body))).status, 200);
    const p = recordPart(n, records.map((r) => r.row));
    assert.equal((await client.putPart(p)).status, 200);
    return p;
  }

  const getStatus = async (client, kind, name) =>
    kind === "image"
      ? (await client.getImage(name)).status
      : kind === "body"
        ? (await client.getBodies([name])).status
        : kind === "part"
          ? (await client.getPart(name)).status
          : (await client.getRoot(name)).status;

  test("what a put stores stays shown and answers 404 until the replacement that references it, and the one that stops referencing it hides it, the replaced root too", async () => {
    const a = await account("retention-cycle");
    const png = newImage();
    const late = newImage();
    const record = newRecord(0, { binding: { skill_png: png.name, factor_png: late.name } });
    assert.equal((await a.client.putImage(png.name, png.bytes)).status, 200);
    const p0 = await putPart(a.client, 0, [record]);
    for (const name of [png.name, record.body.name, p0.name]) assert.deepEqual(a.versions(name), ["v"]);
    assert.equal(await getStatus(a.client, "body", record.body.name), 404);
    assert.equal(await getStatus(a.client, "image", png.name), 404);
    assert.equal(await getStatus(a.client, "part", p0.name), 404);

    const first = await a.replace({ 0: p0 });
    for (const [kind, name] of [["image", png.name], ["body", record.body.name], ["part", p0.name], ["root", first.name]]) {
      assert.ok(a.shown(name), name);
      assert.equal(await getStatus(a.client, kind, name), 200, kind);
    }
    // An image the list names already is not hidden when it is put.
    assert.equal((await a.client.putImage(late.name, late.bytes)).status, 200);
    assert.deepEqual(a.versions(late.name), ["v"]);
    assert.equal(await getStatus(a.client, "image", late.name), 200);

    const other = await putPart(a.client, 0, [newRecord(0)]);
    const second = await a.replace({ 0: other });
    const dropped = [["image", png.name], ["image", late.name], ["body", record.body.name], ["part", p0.name], ["root", first.name]];
    for (const [kind, name] of dropped) {
      assert.equal(a.versions(name).at(-1), "m", name);
      assert.equal(await getStatus(a.client, kind, name), 404, kind);
    }
    assert.equal(await getStatus(a.client, "root", second.name), 200);

    assert.equal((await a.replace({ 0: p0 })).name, first.name);
    for (const [kind, name] of dropped) assert.equal(await getStatus(a.client, kind, name), 200, kind);
    assert.equal(a.versions(second.name).at(-1), "m");
  });

  test("what a put stored and nothing referenced is hidden by the account's next write once SYNC_ABANDONED_AFTER old, and not before", async () => {
    const a = await account("retention-put-later");
    const record = newRecord(0);
    const image = newImage();
    assert.equal((await a.client.putBodies([record.body])).status, 200);
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    const put = [record.body.name, image.name, p0.name];

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER - 60);
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    for (const name of put) assert.deepEqual(a.versions(name), ["v"], name);
    await worker.advanceClock(60);
    assert.equal((await a.client.putBodies([newRecord(2).body])).status, 200);
    for (const name of put) assert.deepEqual(a.versions(name), ["v", "m"], name);
    assert.equal(await getStatus(a.client, "body", record.body.name), 404);

    // Referenced later, it is shown again, as anything hidden is.
    await a.replace({ 0: p0 });
    for (const name of [record.body.name, p0.name]) assert.deepEqual(a.versions(name), ["v"], name);
    assert.equal(await getStatus(a.client, "body", record.body.name), 200);
  });

  test("what a put stored and a replacement referenced in time is never hidden, by the next write or the hourly run, and leaves no record of its write", async () => {
    const a = await account("retention-put-taken");
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    const p0 = await putPart(a.client, 0, [record]);
    const first = await a.replace({ 0: p0 });
    const records = await worker.db.prepare("SELECT count(*) AS n FROM sync_writes WHERE account_id = ?1").bind(a.id).first();
    assert.equal(records.n, 0, "every put recorded what it stored and cleared the record of its write");
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    assert.equal(await worker.scheduled(), "ok");
    for (const [kind, name] of [["image", image.name], ["body", record.body.name], ["part", p0.name], ["root", first.name]]) {
      assert.deepEqual(a.versions(name), ["v"], name);
      assert.equal(await getStatus(a.client, kind, name), 200, kind);
    }
  });

  test("a part no root took, and the root of a replacement that lost to another, stay shown and answer 404, and are hidden once SYNC_ABANDONED_AFTER old", async () => {
    const a = await account("retention-lost");
    const parts = [];
    for (const n of [0, 1, 2]) parts.push(await putPart(a.client, n, [newRecord(n)]));
    assert.equal(a.shown(parts[2].name), true);
    assert.equal(await getStatus(a.client, "part", parts[2].name), 404);

    await a.replace({ 0: parts[0] });
    const roots = [root({ 0: parts[0].name, 1: parts[1].name }), root({ 0: parts[0].name, 2: parts[2].name })];
    await worker.armGate(2);
    const results = await Promise.all(roots.map((r) => a.client.replace(1, r)));
    assert.deepEqual(results.map((r) => r.status).sort(), [200, 409]);
    const won = results.findIndex((r) => r.status === 200);
    const lost = [roots[1 - won].name, parts[1 + (1 - won)].name];
    assert.ok(a.shown(roots[won].name));
    for (const name of lost) assert.deepEqual(a.versions(name), ["v"], name);
    assert.equal(await getStatus(a.client, "root", roots[1 - won].name), 404);
    assert.equal(await getStatus(a.client, "part", parts[1 + (1 - won)].name), 404, "the losing root's own part");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal((await a.client.putBodies([newRecord(3).body])).status, 200);
    for (const name of lost) assert.deepEqual(a.versions(name), ["v", "m"], name);
    assert.ok(a.shown(roots[won].name));
  });

  test("a row archived as reduced JPEG references its PNG only until the JPEG is stored, before or after the replacement, and a row archived without images references none", async () => {
    const a = await account("retention-jpeg");
    const [png1, jpeg1, png2, jpeg2, png3] = Array.from({ length: 5 }, newImage);
    const later = newRecord(0, { state: "jpeg", binding: { skill_png: png1.name, skill_jpeg: jpeg1.name } });
    const earlier = newRecord(1, { state: "jpeg", binding: { skill_png: png2.name, skill_jpeg: jpeg2.name } });
    const none = newRecord(2, { state: "none", binding: { skill_png: png3.name } });
    for (const image of [png1, png2, png3]) assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    assert.equal((await a.client.putImage(jpeg2.name, jpeg2.bytes, "image/jpeg")).status, 200);

    await a.replace({ 0: await putPart(a.client, 0, [later]), 1: await putPart(a.client, 1, [earlier]), 2: await putPart(a.client, 2, [none]) });
    assert.equal(await getStatus(a.client, "image", png1.name), 200, "no JPEG yet: the PNG");
    assert.equal(await getStatus(a.client, "image", jpeg2.name), 200);
    assert.equal(await getStatus(a.client, "image", png2.name), 404, "JPEG stored before the replacement");
    assert.equal(await getStatus(a.client, "image", png3.name), 404, "archived without images");
    assert.equal(await getStatus(a.client, "body", none.body.name), 200);

    assert.equal((await a.client.putImage(jpeg1.name, jpeg1.bytes, "image/jpeg")).status, 200);
    assert.equal(await getStatus(a.client, "image", jpeg1.name), 200);
    assert.deepEqual(a.versions(jpeg1.name), ["v"]);
    assert.equal(await getStatus(a.client, "image", png1.name), 404, "JPEG stored after the replacement");
    assert.equal(a.versions(png1.name).at(-1), "m");
  });

  test("a PNG a normal row and a reduced-JPEG row reference from different parts stays shown when the JPEG is stored, until the normal row goes", async () => {
    const a = await account("retention-shared-png");
    const png = newImage();
    const jpeg = newImage();
    const binding = { skill_png: png.name, skill_jpeg: jpeg.name };
    const normal = newRecord(0, { binding });
    const reduced = newRecord(1, { state: "jpeg", binding });
    assert.equal((await a.client.putImage(png.name, png.bytes)).status, 200);
    const p0 = await putPart(a.client, 0, [normal]);
    const p1 = await putPart(a.client, 1, [reduced]);
    await a.replace({ 0: p0, 1: p1 });
    assert.equal(await getStatus(a.client, "image", png.name), 200);

    assert.equal((await a.client.putImage(jpeg.name, jpeg.bytes, "image/jpeg")).status, 200);
    assert.equal(await getStatus(a.client, "image", jpeg.name), 200);
    assert.equal(await getStatus(a.client, "image", png.name), 200, "the normal row in part 0 references it");
    assert.equal(a.versions(png.name).at(-1), "v");

    await a.replace({ 1: p1 });
    assert.equal(await getStatus(a.client, "image", png.name), 404);
    assert.equal(a.versions(png.name).at(-1), "m");
    assert.equal(await getStatus(a.client, "image", jpeg.name), 200);
  });

  test("a record's icon is referenced as a JPEG by a normal and a reduced-JPEG row, counts as the account's bytes, and is hidden only when the last row naming it goes", async () => {
    const a = await account("retention-icon");
    const icon = newImage();
    const normal = newRecord(0, { icon: icon.name });
    const reduced = newRecord(1, { state: "jpeg", icon: icon.name });
    const p0 = await putPart(a.client, 0, [normal]);
    const p1 = await putPart(a.client, 1, [reduced]);
    await a.replace({ 0: p0, 1: p1 });
    const stored = async () => (await usage(worker.db, a.id, await worker.now())).stored;
    const before = await stored();
    assert.equal((await a.client.putImage(icon.name, icon.bytes, "image/jpeg")).body.status, "stored");
    assert.equal(await stored(), before + icon.bytes.length, "the referenced icon is the account's bytes");
    const got = await a.client.getImage(icon.name);
    assert.deepEqual([got.status, got.type, got.bytes.equals(icon.bytes)], [200, "image/jpeg", true]);

    await a.replace({ 1: p1 });
    assert.equal(await getStatus(a.client, "image", icon.name), 200, "the reduced-JPEG row still names it");
    assert.equal(a.versions(icon.name).at(-1), "v");

    const none = await putPart(a.client, 1, [{ body: reduced.body, row: archived(reduced.row, "none") }]);
    await a.replace({ 1: none });
    assert.equal(await getStatus(a.client, "image", icon.name), 404, "archived without images");
    assert.equal(a.versions(icon.name).at(-1), "m");

    await a.replace({ 0: p0 });
    assert.equal(await getStatus(a.client, "image", icon.name), 200, "referenced again before the boundary");
  });

  test("a replacement that stops referencing more objects than one request may make B2 requests hides every one of them before it answers", async () => {
    const a = await account("retention-many");
    const records = Array.from({ length: limits.B2_REQUESTS_PER_INVOCATION + limits.MAX_SYNC_BODIES_PER_REQUEST }, () => newRecord(0));
    for (let i = 0; i < records.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      const sent = worker.b2.requests.length;
      assert.equal((await a.client.putBodies(records.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body))).status, 200);
      assert.deepEqual(worker.b2.requests.slice(sent).map((r) => r.method), Array(10).fill("PUT"));
    }
    const p0 = recordPart(0, records.map((r) => r.row));
    assert.equal((await a.client.putPart(p0)).status, 200);
    await a.replace({ 0: p0 });
    const bodies = records.map((r) => r.body.name);
    assert.ok(bodies.every(a.shown));

    const sent = worker.b2.requests.length;
    await a.replace({});
    assert.deepEqual(bodies.filter(a.shown), []);
    assert.equal(a.shown(p0.name), false);
    // The new root's put and one DeleteObjects for every name it stopped referencing.
    assert.deepEqual(worker.b2.requests.slice(sent).map((r) => r.method), ["PUT", "POST"]);
  });

  test("a replacement whose shows and hides need more B2 requests than one request may make is refused before it changes anything, and goes through once they fit", async () => {
    const a = await account("retention-too-many");
    // 50 bodies put, and their hide by the account's next write once they are old enough held in B2:
    // 50 hidden bodies whose markers no hide has recorded yet, which a replacement showing them must
    // list in B2, over a page or two each while a page holds one version.
    const records = Array.from({ length: 50 }, () => newRecord(0));
    for (let i = 0; i < records.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      assert.equal((await a.client.putBodies(records.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body))).status, 200);
    }
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    const hold = worker.b2.hold("DELETE_OBJECTS", a.key(records[0].body.name));
    const write = a.client.putBodies([newRecord(1).body]);
    await hold.entered;
    const p0 = recordPart(0, records.map((r) => r.row));
    assert.equal((await a.client.putPart(p0)).status, 200);
    const r = root({ 0: p0.name });

    const sent = worker.b2.requests.length;
    worker.b2.pageSize = 1;
    let refused;
    try {
      refused = await a.client.replace(0, r);
    } finally {
      worker.b2.pageSize = 1000;
    }
    assert.deepEqual([refused.status, refused.body], [409, { error: "too_many_objects" }]);
    assert.ok(
      worker.b2.requests.slice(sent).every((q) => q.method === "GET" && "versions" in q.query),
      "no B2 request but the listing",
    );
    assert.deepEqual((await a.client.generation()).body, { generation: 0, root: null });
    assert.deepEqual(a.versions(r.name), []);
    assert.deepEqual(a.versions(p0.name), ["v"]);

    hold.release();
    assert.equal((await write).status, 200);
    for (const record of records) assert.deepEqual(a.versions(record.body.name), ["v", "m"]);
    const replaced = await a.client.replace(0, r);
    assert.equal(replaced.status, 200, replaced.text);
    for (const record of records) assert.equal(await getStatus(a.client, "body", record.body.name), 200);
  });

  test("a root that pairs one reduced JPEG with more PNGs than a JPEG put can hide at once is refused", async () => {
    const a = await account("retention-jpeg-pngs");
    const jpeg = newImage().name;
    const records = Array.from({ length: Math.ceil((limits.SYNC_PNGS_PER_JPEG + 1) / 3) }, () => {
      const [c, f, s] = Array.from({ length: 3 }, () => newImage().name);
      return newRecord(0, { state: "jpeg", binding: { campaign_png: c, campaign_jpeg: jpeg, factor_png: f, factor_jpeg: jpeg, skill_png: s, skill_jpeg: jpeg } });
    });
    for (let i = 0; i < records.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      assert.equal((await a.client.putBodies(records.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body))).status, 200);
    }
    const p0 = recordPart(0, records.map((r) => r.row));
    assert.equal((await a.client.putPart(p0)).status, 200);
    const res = await a.client.replace(0, root({ 0: p0.name }));
    assert.deepEqual([res.status, res.body], [400, { error: "too_many_pngs_per_jpeg", limit: limits.SYNC_PNGS_PER_JPEG }]);
    assert.deepEqual((await a.client.generation()).body, { generation: 0, root: null });
  });

  test("a replacement cut off after its commit leaves what it stopped referencing recorded to hide, and the account's next write once it is SYNC_ABANDONED_AFTER old hides it, apart from what that write references again", async () => {
    const a = await account("retention-cut-replace");
    const kept = newRecord(0);
    const dropped = newRecord(1);
    const p0 = await putPart(a.client, 0, [kept]);
    const p1 = await putPart(a.client, 1, [dropped]);
    const first = await a.replace({ 0: p0, 1: p1 });

    const empty = root({});
    await worker.failD1At(HIDE_INTENT);
    const cut = await a.client.replace(1, empty);
    assert.deepEqual([cut.status, cut.body], [503, { error: "temporarily_unavailable" }]);
    assert.equal(await worker.d1FaultLeft(), null);
    assert.deepEqual((await a.client.generation()).body, { generation: 2, root: empty.name }, "the replacement committed");
    const left = [kept.body.name, dropped.body.name, p0.name, p1.name, first.name];
    assert.deepEqual(await toHide(worker, a.id), [...left].sort());
    assert.ok(left.every(a.shown), "nothing was hidden");

    // The next write once they are SYNC_ABANDONED_AFTER old references part 0 again, so only the rest
    // is hidden.
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    const again = root({ 0: p0.name });
    const res = await a.client.replace(2, again);
    assert.equal(res.status, 200, res.text);
    assert.deepEqual(await toHide(worker, a.id), []);
    for (const [kind, name] of [["part", p0.name], ["body", kept.body.name]]) {
      assert.equal(await getStatus(a.client, kind, name), 200, kind);
      assert.equal(a.versions(name).at(-1), "v");
    }
    for (const name of [dropped.body.name, p1.name, first.name, empty.name]) assert.equal(a.versions(name).at(-1), "m", name);
  });

  test("of two puts of one name that both found it missing, the reference that follows leaves it shown", async () => {
    const a = await account("retention-race-put");
    const image = newImage();
    const holds = [worker.b2.hold("PUT", a.key(image.name)), worker.b2.hold("PUT", a.key(image.name))];
    const puts = [a.client.putImage(image.name, image.bytes), a.client.putImage(image.name, image.bytes)];
    await Promise.all(holds.map((h) => h.entered));
    for (const h of holds) h.release();
    const results = await Promise.all(puts);
    assert.deepEqual(results.map((r) => r.body.status), ["stored", "stored"]);

    await a.replace({ 0: await putPart(a.client, 0, [newRecord(0, { binding: { skill_png: image.name } })]) });
    assert.equal(await getStatus(a.client, "image", image.name), 200);
    assert.equal(a.versions(image.name).at(-1), "v");
  });

  /**
   * Puts `image` and moves the clock SYNC_ABANDONED_AFTER on, then begins the account's next write (a
   * put of `body`), whose request hides the image after its own work, held in B2 adding the marker:
   * `{hide, write}`, hide the hold, write the put's answer to come.
   */
  async function hideHeld(a, image, body) {
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    const hide = worker.b2.hold("DELETE_OBJECTS", a.key(image.name));
    const write = a.client.putBodies([body]);
    await hide.entered;
    return { hide, write };
  }

  test("a replacement that references a name while its hide is held in B2 leaves it shown", async () => {
    const a = await account("retention-race-hide");
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    const { hide, write } = await hideHeld(a, image, record.body);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    await a.replace({ 0: p0 });
    hide.release();
    assert.equal((await write).status, 200);
    assert.equal(await getStatus(a.client, "image", image.name), 200);
    assert.equal(a.versions(image.name).at(-1), "v");
  });

  test("a hide that finishes after a replacement took its name over and before the commit gives its marker back", async () => {
    const a = await account("retention-race-record");
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    const { hide, write } = await hideHeld(a, image, record.body);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    // The replacement looks and takes the image's row over (the hide's marker is not in B2 yet), and
    // stops at storing its root.
    const r = root({ 0: p0.name });
    const store = worker.b2.hold("PUT", a.key(r.name));
    const replaced = a.client.replace(0, r);
    await store.entered;
    hide.release();
    assert.equal((await write).status, 200);
    assert.equal(a.versions(image.name).at(-1), "v", "the hide found the row taken and gave its marker back");
    store.release();
    assert.equal((await replaced).status, 200);
    assert.equal(await getStatus(a.client, "image", image.name), 200);
    assert.equal(a.versions(image.name).at(-1), "v");
  });

  /**
   * An account of `sub` with an image, a body naming it and part 0 put SYNC_ABANDONED_AFTER ago, and a
   * replacement taking part 0 that has looked and stops at storing its root: `{a, image, store,
   * replaced}`, store the hold, replaced its answer to come.
   */
  async function lookedBeforeHide(sub) {
    const a = await account(sub);
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    const p0 = await putPart(a.client, 0, [record]);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    const r = root({ 0: p0.name });
    const store = worker.b2.hold("PUT", a.key(r.name));
    const replaced = a.client.replace(0, r);
    await store.entered;
    return { a, image, store, replaced };
  }

  test("a hide still adding its marker when a replacement that references the name commits gives the marker back itself", async () => {
    const { a, image, store, replaced } = await lookedBeforeHide("retention-race-unrecorded");
    // The account's next write hides the image, nothing referencing it when it looks, held in B2.
    const hide = worker.b2.hold("DELETE_OBJECTS", a.key(image.name));
    const write = a.client.putBodies([newRecord(1).body]);
    await hide.entered;
    store.release();
    assert.equal((await replaced).status, 200);
    hide.release();
    assert.equal((await write).status, 200);
    assert.equal(await getStatus(a.client, "image", image.name), 200);
    assert.equal(a.versions(image.name).at(-1), "v");
  });

  test("a hide that begins between a replacement's look and its commit is undone after the commit", async () => {
    const { a, image, store, replaced } = await lookedBeforeHide("retention-race-begin");
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    assert.equal(a.versions(image.name).at(-1), "m", "hidden by the account's next write, nothing referencing it yet");
    store.release();
    assert.equal((await replaced).status, 200);
    assert.equal(await getStatus(a.client, "image", image.name), 200);
    assert.equal(a.versions(image.name).at(-1), "v");
  });
});

describe("sync hourly run", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  /** The account of session `token` after it put a body nothing references: `{id, key, body}`, the body stored and shown. */
  async function putOnly(token) {
    const id = await worker.accountOf(token);
    const { body } = newRecord(0);
    assert.equal((await syncClient(worker, token).putBodies([body])).status, 200);
    const key = `a/${id}/${body.name}`;
    assert.deepEqual(worker.b2.versions(key), ["v"]);
    return { id, key, body };
  }

  test("a run hides what a replacement cut off after its commit left, of an account that never asks again", async () => {
    const token = await worker.signIn("daily-cut-replace");
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    const record = newRecord(0);
    assert.equal((await client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await client.putPart(p0)).status, 200);
    const first = root({ 0: p0.name });
    assert.equal((await client.replace(0, first)).status, 200);
    await worker.failD1At(HIDE_INTENT);
    assert.equal((await client.replace(1, root({}))).status, 503);
    const left = [record.body.name, p0.name, first.name];
    assert.deepEqual(await toHide(worker, id), [...left].sort());

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual(await toHide(worker, id), []);
    for (const name of left) assert.equal(worker.b2.versions(`a/${id}/${name}`).at(-1), "m", name);
  });

  test("a run takes on the accounts its B2 requests have room for and leaves the rest recorded for the next run", async () => {
    // Each account's hide sends one DeleteObjects, and is begun only with room for a second (giving
    // markers back), so a run takes on all but the last of B2_REQUESTS_PER_INVOCATION such accounts.
    const tokens = await Promise.all(Array.from({ length: limits.B2_REQUESTS_PER_INVOCATION }, (_, i) => worker.signIn(`daily-many-${i}`)));
    const accounts = [];
    for (const token of tokens) accounts.push(await putOnly(token));
    assert.equal((await toHide(worker)).length, accounts.length);
    assert.equal(await worker.scheduled(), "ok");
    assert.ok(accounts.every((a) => worker.b2.versions(a.key).at(-1) === "v"), "not before SYNC_ABANDONED_AFTER");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    const sent = worker.b2.requests.length;
    assert.equal(await worker.scheduled(), "ok");
    assert.equal(worker.b2.requests.length - sent, limits.B2_REQUESTS_PER_INVOCATION - 1);
    const rest = await toHide(worker);
    assert.equal(rest.length, 1);
    const hidden = accounts.filter((a) => worker.b2.versions(a.key).at(-1) === "m");
    assert.equal(hidden.length, accounts.length - 1);
    assert.deepEqual(accounts.filter((a) => !hidden.includes(a)).map((a) => a.body.name), rest);

    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual(await toHide(worker), []);
    assert.ok(accounts.every((a) => worker.b2.versions(a.key).at(-1) === "m"));
  });
});

describe("sync hides and shows a cut-off request left mid-way", () => {
  // A request stopped inside a hide or a show leaves the row hidden with no marker recorded and B2 in
  // either state. Once that hide is older than SYNC_ABANDONED_AFTER, the account's next write or a run
  // hides the name again.
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  /** A fresh account of `sub`: `{id, client, latest}`, latest(name) "v" or "m" for B2's latest version of name. */
  async function account(sub) {
    const token = await worker.signIn(sub);
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    return { id, client, key: (name) => `a/${id}/${name}`, latest: (name) => worker.b2.versions(`a/${id}/${name}`).at(-1) };
  }

  /**
   * Puts body `body` and moves the clock SYNC_ABANDONED_AFTER on, so that the account's next write
   * hides it after its own work: what a test then cuts off or fails is that write's hide.
   */
  async function putToHide(a, body) {
    assert.equal((await a.client.putBodies([body])).status, 200);
    assert.equal(a.latest(body.name), "v");
    assert.equal((await a.client.getBodies([body.name])).status, 404, "nothing references it");
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
  }

  test("a hide cut off between recording its intent and hiding in B2 is left for the account's next write once abandoned, and the write it was part of still answers", async () => {
    const a = await account("abandoned-cut-hide");
    const { body } = newRecord(0);
    await putToHide(a, body);
    await worker.cutD1After(HIDE_INTENT);
    const cut = await a.client.putBodies([newRecord(1).body]);
    await worker.restoreD1();
    assert.equal(cut.status, 200);
    assert.equal(a.latest(body.name), "v");
    // Its request may still be running: a write before then leaves the hide alone.
    assert.equal((await a.client.putBodies([newRecord(2).body])).status, 200);
    assert.equal(a.latest(body.name), "v");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal((await a.client.putBodies([newRecord(3).body])).status, 200);
    assert.equal(a.latest(body.name), "m");
    assert.equal((await a.client.getBodies([body.name])).status, 404);
  });

  test("a hide B2 failed is left for the next run once abandoned, and the write it was part of still answers", async () => {
    const a = await account("abandoned-b2-failed");
    const { body } = newRecord(0);
    await putToHide(a, body);
    worker.b2.fail(a.key(body.name));
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    assert.equal(a.latest(body.name), "v");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    assert.equal(a.latest(body.name), "m");
    assert.equal((await a.client.getBodies([body.name])).status, 404);
  });

  test("a hide cut off after B2 hid the object and before it recorded the marker is hidden again once abandoned, and a later replacement shows it", async () => {
    const a = await account("abandoned-cut-record");
    const record = newRecord(0);
    await putToHide(a, record.body);
    await worker.cutD1At(HIDE_RECORD);
    const cut = await a.client.putBodies([newRecord(1).body]);
    await worker.restoreD1();
    assert.equal(cut.status, 200);
    assert.equal(a.latest(record.body.name), "m");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    // Hidden again over the marker no row names: what shows it has to delete both.
    assert.deepEqual(worker.b2.versions(a.key(record.body.name)), ["v", "m", "m"]);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    assert.equal((await a.client.replace(0, root({ 0: p0.name }))).status, 200);
    assert.equal((await a.client.getBodies([record.body.name])).status, 200);
  });

  test("a replacement cut off after it showed what it references again and before its commit leaves them for the next run once abandoned", async () => {
    const a = await account("abandoned-cut-show");
    const record = newRecord(0);
    assert.equal((await a.client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    const first = root({ 0: p0.name });
    const empty = root({});
    assert.equal((await a.client.replace(0, first)).status, 200);
    assert.equal((await a.client.replace(1, empty)).status, 200);
    const again = [record.body.name, p0.name, first.name];
    for (const name of again) assert.equal(a.latest(name), "m", name);

    await worker.cutD1At("INSERT INTO sync_accounts");
    const cut = await a.client.replace(2, first);
    await worker.restoreD1();
    assert.equal(cut.status, 503);
    assert.equal((await a.client.generation()).body.generation, 2);
    for (const name of again) assert.equal(a.latest(name), "v", name);
    assert.equal((await a.client.getPart(p0.name)).status, 404, "shown in B2, and 404 since the current root does not reference it");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    for (const name of again) assert.equal(a.latest(name), "m", name);
    assert.equal((await a.client.getPart(p0.name)).status, 404);
    assert.equal((await a.client.getRoot(empty.name)).status, 200, "the current root stays fetchable");
  });

  test("a replacement still running when what it took over is hidden again as abandoned does not commit", async () => {
    const a = await account("abandoned-slow-show");
    const record = newRecord(0);
    assert.equal((await a.client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    const first = root({ 0: p0.name });
    const empty = root({});
    assert.equal((await a.client.replace(0, first)).status, 200);
    assert.equal((await a.client.replace(1, empty)).status, 200);

    // It took the rows over and stops at showing them while a run hides them again.
    const held = worker.b2.hold("DELETE_OBJECTS", a.key(p0.name));
    const replaced = a.client.replace(2, first);
    await held.entered;
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    held.release();
    assert.equal((await replaced).status, 503);
    const current = (await a.client.generation()).body;
    assert.deepEqual(current, { generation: 2, root: empty.name });
    for (const name of [record.body.name, p0.name, first.name]) assert.equal(a.latest(name), "m", name);
    assert.equal((await a.client.getRoot(empty.name)).status, 200, "the current root stays fetchable");
  });

  /**
   * An account of `sub` with image `image` put, then, once it is old enough to hide, a body naming it
   * and part 0 put: `{a, image, p0, record}`. The account's next write hides the image, and the body
   * and part only SYNC_ABANDONED_AFTER after them.
   */
  async function withOldImage(sub) {
    const a = await account(sub);
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    return { a, image, record, p0: recordPart(0, [record.row]) };
  }

  /** Begins replacement `r` of `a` from generation `generation` and waits until it stops at storing its root: `{store, replaced}`. */
  async function heldAtRoot(a, generation, r) {
    const store = worker.b2.hold("PUT", a.key(r.name));
    const replaced = a.client.replace(generation, r);
    await store.entered;
    return { store, replaced };
  }

  test("a replacement cut off after its commit and before it showed what a hide hid after its look leaves that for the account's next write once abandoned", async () => {
    const a = await account("abandoned-cut-show-referenced");
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER - 60);
    assert.equal((await a.client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    // The replacement looks while nothing is hidden and stops at storing its root; the image is then
    // old enough for the account's next write to hide it and record the marker.
    const { store, replaced } = await heldAtRoot(a, 0, root({ 0: p0.name }));
    await worker.advanceClock(60);
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    assert.equal(a.latest(image.name), "m");
    await worker.cutD1At(SHOW_REFERENCED);
    store.release();
    const cut = await replaced;
    await worker.restoreD1();
    assert.equal(cut.status, 503);
    assert.equal((await a.client.generation()).body.generation, 1, "the replacement committed");
    assert.equal((await a.client.getImage(image.name)).status, 404, "referenced and hidden");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal((await a.client.putBodies([newRecord(2).body])).status, 200);
    assert.equal(a.latest(image.name), "v");
    assert.equal((await a.client.getImage(image.name)).status, 200);
  });

  test("a hide cut off after a replacement took its name over and before it gave its marker back leaves the name for the next run once abandoned", async () => {
    const { a, image, record, p0 } = await withOldImage("abandoned-cut-give-back-taken");
    // The account's next write (putting the image's body) hides it, held in B2.
    const hide = worker.b2.hold("DELETE_OBJECTS", a.key(image.name));
    const write = a.client.putBodies([record.body]);
    await hide.entered;
    assert.equal((await a.client.putPart(p0)).status, 200);
    // The replacement takes the image's row over and lists its markers before the hide adds one, and
    // stops at storing its root.
    const { store, replaced } = await heldAtRoot(a, 0, root({ 0: p0.name }));
    await worker.cutD1After(HIDE_RECORD);
    hide.release();
    assert.equal((await write).status, 200);
    await worker.restoreD1();
    store.release();
    assert.equal((await replaced).status, 200);
    assert.equal(a.latest(image.name), "m", "the hide's marker is left over the image");
    assert.equal((await a.client.getImage(image.name)).status, 404, "referenced and hidden");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    assert.equal(a.latest(image.name), "v");
    assert.equal((await a.client.getImage(image.name)).status, 200);
  });

  test("a hide cut off after it found its name referenced by a replacement that committed and before it gave its marker back leaves the name for the next run once abandoned", async () => {
    const a = await account("abandoned-cut-give-back-referenced");
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    assert.equal((await a.client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    // The replacement looks while nothing is hidden and stops at storing its root; the account's next
    // write hides what is now old enough, held in B2 until the replacement commits.
    const { store, replaced } = await heldAtRoot(a, 0, root({ 0: p0.name }));
    const hide = worker.b2.hold("DELETE_OBJECTS", a.key(image.name));
    const write = a.client.putBodies([newRecord(1).body]);
    await hide.entered;
    store.release();
    assert.equal((await replaced).status, 200);
    await worker.cutD1After(HIDE_RECORD);
    hide.release();
    assert.equal((await write).status, 200);
    await worker.restoreD1();
    assert.equal(a.latest(image.name), "m", "the hide's marker is left over the image");
    assert.equal((await a.client.getImage(image.name)).status, 404, "referenced and hidden");

    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    assert.equal(a.latest(image.name), "v");
    assert.equal((await a.client.getImage(image.name)).status, 200);
  });

  test("a replacement that took a name over from a hide still running and lost to another leaves it for a later replacement to list, after that hide was cut off before giving its marker back", async () => {
    const { a, image, record, p0 } = await withOldImage("abandoned-rollback-taken");
    const hide = worker.b2.hold("DELETE_OBJECTS", a.key(image.name));
    const write = a.client.putBodies([record.body]);
    await hide.entered;
    assert.equal((await a.client.putPart(p0)).status, 200);
    const other = newRecord(1);
    assert.equal((await a.client.putBodies([other.body])).status, 200);
    const p1 = recordPart(1, [other.row]);
    assert.equal((await a.client.putPart(p1)).status, 200);
    // The replacement takes the image's row over and lists its markers before the hide adds one, and
    // stops at storing its root while another replacement commits first.
    const { store, replaced: lost } = await heldAtRoot(a, 0, root({ 0: p0.name }));
    assert.equal((await a.client.replace(0, root({ 1: p1.name }))).status, 200);
    await worker.cutD1After(HIDE_RECORD);
    hide.release();
    assert.equal((await write).status, 200);
    await worker.restoreD1();
    store.release();
    assert.equal((await lost).status, 409);
    assert.equal(a.latest(image.name), "m", "the hide's marker is left over the image");

    assert.equal((await a.client.replace(1, root({ 0: p0.name }))).status, 200);
    assert.equal((await a.client.getImage(image.name)).status, 200);
    assert.equal(a.latest(image.name), "v");
  });

  /**
   * An account of `sub` whose replacement was cut off after its commit and before it showed `n` images
   * that the account's next write hid, and recorded the markers of, after its look: `{a, images}`.
   */
  async function cutShowingImages(sub, n) {
    const a = await account(sub);
    const images = Array.from({ length: n }, () => newImage());
    const records = [];
    for (let i = 0; i < n; i += 3) {
      const [campaign, factor, skill] = images.slice(i, i + 3);
      records.push(newRecord(0, { binding: { campaign_png: campaign?.name ?? null, factor_png: factor?.name ?? null, skill_png: skill?.name ?? null } }));
    }
    for (const res of await Promise.all(images.map((image) => a.client.putImage(image.name, image.bytes)))) assert.equal(res.status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER - 60);
    for (let i = 0; i < records.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      assert.equal((await a.client.putBodies(records.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body))).status, 200);
    }
    const p0 = recordPart(0, records.map((r) => r.row));
    assert.equal((await a.client.putPart(p0)).status, 200);
    const { store, replaced } = await heldAtRoot(a, 0, root({ 0: p0.name }));
    await worker.advanceClock(60);
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    await worker.cutD1At(SHOW_REFERENCED);
    store.release();
    const cut = await replaced;
    await worker.restoreD1();
    assert.equal(cut.status, 503);
    assert.equal((await a.client.generation()).body.generation, 1, "the replacement committed");
    assert.ok(images.every((image) => a.latest(image.name) === "m"));
    return { a, images };
  }

  test("more names left referenced and hidden than a run has B2 requests to list one by one are shown by one run through their recorded markers, and by the next page by page when B2 failed to delete those", async () => {
    const n = limits.B2_REQUESTS_PER_INVOCATION + 10;
    const recorded = await cutShowingImages("abandoned-cut-show-many-recorded", n);
    const failing = await cutShowingImages("abandoned-cut-show-many-failing", n);
    for (const image of failing.images) worker.b2.failTarget(failing.a.key(image.name));
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);

    const outcome = await worker.scheduled();
    assert.equal(recorded.images.filter((image) => recorded.a.latest(image.name) === "v").length, n, "shown by one run");
    assert.equal(outcome, "ok");
    for (const image of recorded.images.slice(0, 3)) assert.equal((await recorded.a.client.getImage(image.name)).status, 200);
    assert.ok(failing.images.every((image) => failing.a.latest(image.name) === "m"), "B2 failed every one");

    // Pages shorter than the versions of a few keys, so that pages end inside a key and between names.
    worker.b2.pageSize = 7;
    try {
      const lists = worker.b2.count("GET");
      assert.equal(await worker.scheduled(), "ok");
      assert.ok(worker.b2.count("GET") - lists > 1, "listed page by page");
    } finally {
      worker.b2.pageSize = 1000;
    }
    assert.ok(failing.images.every((image) => failing.a.latest(image.name) === "v"));
    for (const image of failing.images.slice(0, 3)) assert.equal((await failing.a.client.getImage(image.name)).status, 200);
  });

  test("names left referenced and hidden whose listing takes more pages than a run has B2 requests for are shown over several runs, each within its B2 requests", async () => {
    const failing = await cutShowingImages("abandoned-cut-show-many-pages", limits.B2_REQUESTS_PER_INVOCATION + 10);
    for (const image of failing.images) worker.b2.failTarget(failing.a.key(image.name));
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    assert.ok(failing.images.every((image) => failing.a.latest(image.name) === "m"), "B2 failed every one");

    // Pages of two versions: listing every name takes more pages than one run has B2 requests for.
    worker.b2.pageSize = 2;
    try {
      let runs = 0;
      while (!failing.images.every((image) => failing.a.latest(image.name) === "v")) {
        assert.ok(++runs <= 10, "shown within ten runs");
        await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
        assert.equal(await worker.scheduled(), "ok");
      }
      assert.ok(runs > 1, "one run did not list them all");
    } finally {
      worker.b2.pageSize = 1000;
    }
    for (const image of failing.images.slice(0, 3)) assert.equal((await failing.a.client.getImage(image.name)).status, 200);
  });

  /**
   * Bodies `records` of account `a` put, their hide by the account's next write once they were old
   * enough cut off after B2 hid them and before the markers were recorded, then hidden again by a run
   * once abandoned: each row hidden by no request with no marker recorded, over two markers in B2 that
   * no row names.
   */
  async function rehidden(a, records) {
    for (let i = 0; i < records.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      assert.equal((await a.client.putBodies(records.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body))).status, 200);
    }
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    await worker.cutD1At(HIDE_RECORD);
    const cut = await a.client.putBodies([newRecord(3).body]);
    await worker.restoreD1();
    assert.equal(cut.status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    for (const r of records) assert.deepEqual(worker.b2.versions(a.key(r.body.name)), ["v", "m", "m"]);
  }

  /** Whether every body of `records` is fetchable from account `a`. */
  async function fetchable(a, records) {
    for (let i = 0; i < records.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      const res = await a.client.getBodies(records.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body.name));
      if (res.status !== 200) return false;
    }
    return records.every((r) => a.latest(r.body.name) === "v");
  }

  test("more names a run hid again with no marker recorded than a replacement could list one by one, over more than a page, are shown by one replacement that references them all again", async () => {
    const a = await account("abandoned-rehidden-many");
    const records = Array.from({ length: limits.B2_REQUESTS_PER_INVOCATION }, () => newRecord(0));
    await rehidden(a, records);
    const p0 = recordPart(0, records.map((r) => r.row));
    assert.equal((await a.client.putPart(p0)).status, 200);

    // Pages shorter than the versions of a few keys, so that pages end inside a key and between names.
    worker.b2.pageSize = 7;
    try {
      const lists = worker.b2.count("GET");
      const res = await a.client.replace(0, root({ 0: p0.name }));
      assert.equal(res.status, 200, JSON.stringify(res.body));
      assert.ok(worker.b2.count("GET") - lists > 1, "listed page by page");
    } finally {
      worker.b2.pageSize = 1000;
    }
    assert.ok(await fetchable(a, records));
  });

  test("a replacement whose names a run hid again with no marker recorded take more pages to list than one request has B2 requests for is refused before it changes anything, and goes through split into replacements of one part each", async () => {
    const a = await account("abandoned-rehidden-split");
    // Eight names in each of two parts, and names no part references between them in B2's key order.
    const records = [...Array.from({ length: 8 }, () => newRecord(0)), ...Array.from({ length: 8 }, () => newRecord(1))];
    const others = Array.from({ length: 3 * limits.MAX_SYNC_BODIES_PER_REQUEST }, () => newRecord(2));
    for (let i = 0; i < others.length; i += limits.MAX_SYNC_BODIES_PER_REQUEST) {
      assert.equal((await a.client.putBodies(others.slice(i, i + limits.MAX_SYNC_BODIES_PER_REQUEST).map((r) => r.body))).status, 200);
    }
    await rehidden(a, records);
    const p0 = recordPart(0, records.slice(0, 8).map((r) => r.row));
    const p1 = recordPart(1, records.slice(8).map((r) => r.row));
    assert.equal((await a.client.putPart(p0)).status, 200);
    assert.equal((await a.client.putPart(p1)).status, 200);
    const rowsOf = () =>
      worker.db
        .prepare("SELECT name, hidden_at, hide_by, marker FROM sync_objects WHERE account_id = ?1 AND kind = 'body' ORDER BY name")
        .bind(a.id)
        .all()
        .then((r) => r.results);
    const before = await rowsOf();

    // A page per version: a name takes three pages or four, so sixteen take more than one request has
    // room for, and eight do not.
    worker.b2.pageSize = 1;
    try {
      const both = await a.client.replace(0, root({ 0: p0.name, 1: p1.name }));
      assert.equal(both.status, 409);
      assert.equal(both.body.error, "too_many_objects");
      assert.equal((await a.client.generation()).body.generation, 0);
      assert.deepEqual(await rowsOf(), before, "every row as it was");
      assert.ok(records.every((r) => a.latest(r.body.name) === "m"), "nothing shown");

      assert.equal((await a.client.replace(0, root({ 0: p0.name }))).status, 200);
      assert.equal((await a.client.replace(1, root({ 0: p0.name, 1: p1.name }))).status, 200);
    } finally {
      worker.b2.pageSize = 1000;
    }
    assert.ok(await fetchable(a, records));
  });

  test("a write with no B2 request left shows nothing a cut-off request left, and takes over no row of it", async () => {
    // Called directly: a write that spends exactly its last B2 request before it tidies needs a
    // replacement shaped to the request, which no entry offers. The rows are the ones a hide cut off
    // after it found its names referenced and before it gave its markers back leaves, and one a
    // replacement cut off before it showed what a hide recorded leaves.
    const a = await account("abandoned-no-room-left");
    const at = (await worker.now()) - limits.SYNC_ABANDONED_AFTER - 1;
    for (const marker of [null, null, "recorded"]) {
      await worker.db
        .prepare(
          "INSERT INTO sync_objects (account_id, name, kind, size, stored_at, ref_count, hidden_at, hidden_since, hide_by, marker) VALUES (?1, ?2, 'png', 1, ?3, 1, ?3, ?3, 'cut', ?4)",
        )
        .bind(a.id, newImage().name, at, marker)
        .run();
    }
    const bucket = {
      now: () => Date.now(),
      sent: limits.B2_REQUESTS_PER_INVOCATION,
      async listVersions() {
        throw new Error(`more than ${limits.B2_REQUESTS_PER_INVOCATION} B2 requests in one invocation`);
      },
      async deleteObjects() {
        throw new Error(`more than ${limits.B2_REQUESTS_PER_INVOCATION} B2 requests in one invocation`);
      },
    };
    await tidyLeftoversOf(worker.db, bucket, a.id, await worker.now());
    const rows = await worker.db.prepare("SELECT hide_by, marker FROM sync_objects WHERE account_id = ?1 ORDER BY marker").bind(a.id).all();
    assert.deepEqual(
      rows.results.map((r) => [r.hide_by, r.marker]),
      [
        ["cut", null],
        ["cut", null],
        ["cut", "recorded"],
      ],
    );
  });

  /** Moves the Worker's clock on until what a write a request left records is taken: its request is abandoned, and B2's clock is past it. */
  const UNWRITTEN = limits.SYNC_ABANDONED_AFTER + 2 * limits.RESTORE_MARGIN_SECONDS;

  test("a put cut off after B2 stored the object and before D1 recorded it leaves no object once the account's next write took its write, and none is deleted before", async () => {
    const a = await account("unwritten-put");
    const { body } = newRecord(0);
    await worker.cutD1At(PUT_RECORD);
    const cut = await a.client.putBodies([body]);
    await worker.restoreD1();
    assert.equal(cut.status, 503);
    assert.deepEqual(worker.b2.versions(a.key(body.name)), ["v"], "stored, and no row records it");
    assert.deepEqual((await a.client.held([body.name])).body.held, []);

    // Its request may still be running: a write before then deletes nothing.
    await worker.advanceClock(UNWRITTEN - 60);
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    assert.deepEqual(worker.b2.versions(a.key(body.name)), ["v"]);
    await worker.advanceClock(60);
    assert.equal((await a.client.putBodies([newRecord(2).body])).status, 200);
    assert.deepEqual(worker.b2.versions(a.key(body.name)), []);
  });

  test("a root a replacement stored and failed to record after it lost to another is deleted by the hourly run once its write is taken", async () => {
    const a = await account("unwritten-root");
    const record = newRecord(0);
    assert.equal((await a.client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    // It stops at storing its root while another replacement commits first; its rollback is then cut
    // off where it records the root it stored.
    const r = root({ 0: p0.name });
    const store = worker.b2.hold("PUT", a.key(r.name));
    const lost = a.client.replace(0, r);
    await store.entered;
    assert.equal((await a.client.replace(0, root({}))).status, 200);
    await worker.cutD1At(PUT_RECORD);
    store.release();
    assert.equal((await lost).status, 503);
    await worker.restoreD1();
    assert.deepEqual(worker.b2.versions(a.key(r.name)), ["v"], "stored, and no row records it");

    await worker.advanceClock(UNWRITTEN);
    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual(worker.b2.versions(a.key(r.name)), []);
  });

  test("a put of a name the hourly run read as unwritten, stored before the run lists that account's versions, keeps what it stored", async () => {
    // The run reads every account's unwritten writes first and takes them account by account: it stops
    // at the first account's DeleteObjects while the second account puts its name again.
    const accounts = await Promise.all([account("unwritten-race-a"), account("unwritten-race-b")]);
    const [first, second] = accounts.sort((x, y) => (x.id < y.id ? -1 : 1));
    const [early, late] = [newRecord(0), newRecord(0)];
    for (const [acc, record] of [[first, early], [second, late]]) {
      await worker.cutD1At(PUT_RECORD);
      assert.equal((await acc.client.putBodies([record.body])).status, 503);
      await worker.restoreD1();
    }
    await worker.advanceClock(UNWRITTEN);
    const held = worker.b2.hold("DELETE_OBJECTS", first.key(early.body.name));
    const run = worker.scheduled();
    await held.entered;
    const again = await second.client.putBodies([late.body]);
    assert.deepEqual(again.body.results.map((r) => r.status), ["stored"]);
    held.release();
    assert.equal(await run, "ok");
    assert.deepEqual(worker.b2.versions(second.key(late.body.name)), ["v"], "the cut-off put's version deleted, the new put's kept");
    assert.deepEqual((await second.client.held([late.body.name])).body.held, [late.body.name]);
    assert.deepEqual(worker.b2.versions(first.key(early.body.name)), []);
  });

  test("a put cut off before D1 recorded it and put again in time keeps what the second put stored", async () => {
    const a = await account("unwritten-put-again");
    const record = newRecord(0);
    await worker.cutD1At(PUT_RECORD);
    assert.equal((await a.client.putBodies([record.body])).status, 503);
    await worker.restoreD1();
    const again = await a.client.putBodies([record.body]);
    assert.deepEqual(again.body.results.map((r) => r.status), ["stored"]);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    assert.equal((await a.client.replace(0, root({ 0: p0.name }))).status, 200);

    await worker.advanceClock(UNWRITTEN);
    assert.equal(await worker.scheduled(), "ok");
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    assert.equal(a.latest(record.body.name), "v");
    assert.equal((await a.client.getBodies([record.body.name])).status, 200);
  });

  /**
   * Puts `body` held in B2 while a second put of it stores it and `between(a)` runs, then lets the first
   * reach B2 and answer: returns that answer.
   */
  async function putLate(a, body, between) {
    const late = worker.b2.hold("PUT", a.key(body.name));
    const first = a.client.putBodies([body]);
    await late.entered;
    assert.equal((await a.client.putBodies([body])).status, 200);
    await between();
    late.release();
    return first;
  }

  /** Runs the hourly run and B2's lifecycle once a day for `days` days. */
  async function days(n) {
    for (let day = 0; day < n; day++) {
      await worker.advanceClock(86_400);
      assert.equal(await worker.scheduled(), "ok");
      worker.b2.pickExpired();
      worker.b2.deleteExpired();
    }
  }

  test("a put of a name that reaches B2 after another put stored it and a replacement hid it leaves nothing of it once B2's lifecycle has run", async () => {
    const a = await account("late-put-hidden");
    const record = newRecord(0);
    const late = await putLate(a, record.body, async () => {
      const p0 = recordPart(0, [record.row]);
      assert.equal((await a.client.putPart(p0)).status, 200);
      assert.equal((await a.client.replace(0, root({ 0: p0.name }))).status, 200);
      assert.equal((await a.client.replace(1, root({}))).status, 200);
      assert.deepEqual(worker.b2.versions(a.key(record.body.name)), ["v", "m"]);
    });
    assert.equal(late.status, 200);
    assert.deepEqual(worker.b2.versions(a.key(record.body.name)), ["v", "m", "v"], "what it stored is over the marker");

    await days(9);
    const versions = worker.b2.versions(a.key(record.body.name));
    assert.equal(versions.at(-1), "m", "hidden again");
    assert.deepEqual(versions.filter((v) => v === "v"), [], "every version deleted by B2's lifecycle");
    assert.equal((await a.client.getBodies([record.body.name])).status, 404);
  });

  test("a put of a name that reaches B2 after another put stored it and a replacement referenced it leaves it fetchable", async () => {
    const a = await account("late-put-referenced");
    const record = newRecord(0);
    const late = await putLate(a, record.body, async () => {
      const p0 = recordPart(0, [record.row]);
      assert.equal((await a.client.putPart(p0)).status, 200);
      assert.equal((await a.client.replace(0, root({ 0: p0.name }))).status, 200);
    });
    assert.equal(late.status, 200);
    assert.deepEqual(worker.b2.versions(a.key(record.body.name)), ["v", "v"]);

    await days(9);
    assert.equal(a.latest(record.body.name), "v");
    assert.equal((await a.client.getBodies([record.body.name])).status, 200);
  });
});

describe("sync six-day boundary", () => {
  // B2's lifecycle deletes what stays hidden from B2_DAYS_FROM_HIDING_TO_DELETING days on, so a name
  // hidden that long less RESTORE_MARGIN_SECONDS is gone. The bucket's lifecycle runs only when a test
  // runs it, picking and deleting apart (`pickExpired`, `deleteExpired`), with the clock moved forward.
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  /** Seconds after which a hidden name is gone. */
  const BOUNDARY = limits.B2_DAYS_FROM_HIDING_TO_DELETING * 86_400 - limits.RESTORE_MARGIN_SECONDS;
  /** Seconds after which B2's lifecycle may pick a hidden version. */
  const LIFECYCLE = limits.B2_DAYS_FROM_HIDING_TO_DELETING * 86_400;

  /**
   * An account of `sub` whose root referenced, then stopped referencing, a record with image `png`:
   * `{a, record, png, p0, first, empty}`, every one of them hidden by the last replacement, at generation 2.
   */
  async function hiddenRecord(sub) {
    const token = await worker.signIn(sub);
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    const a = { id, client, key: (name) => `a/${id}/${name}`, latest: (name) => worker.b2.versions(`a/${id}/${name}`).at(-1) };
    const png = newImage();
    const record = newRecord(0, { binding: { skill_png: png.name } });
    assert.equal((await client.putImage(png.name, png.bytes)).status, 200);
    assert.equal((await client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await client.putPart(p0)).status, 200);
    const first = root({ 0: p0.name });
    const empty = root({});
    assert.equal((await client.replace(0, first)).status, 200);
    assert.equal((await client.replace(1, empty)).status, 200);
    for (const name of [png.name, record.body.name, p0.name, first.name]) assert.equal(a.latest(name), "m", name);
    return { a, record, png, p0, first, empty };
  }

  /** The names of `names` the held endpoint answers held. */
  const held = async (a, names) => {
    const res = await a.client.held(names);
    assert.equal(res.status, 200, res.text);
    return res.body.held;
  };

  /** Whether every name the current root of `a` references (root, parts, bodies, images) answers GET 200. */
  async function currentAllFetchable(a) {
    const { root: rootName } = (await a.client.generation()).body;
    const r = await a.client.getRoot(rootName);
    if (r.status !== 200) return false;
    for (const partName of Object.values(JSON.parse(r.text).parts)) {
      const p = await a.client.getPart(partName);
      if (p.status !== 200) return false;
      for (const row of JSON.parse(p.text).records) {
        if ((await a.client.getBodies([row.body.name])).status !== 200) return false;
        for (const image of Object.values(row.image)) if (image !== null && (await a.client.getImage(image)).status !== 200) return false;
      }
    }
    return true;
  }

  /**
   * Puts image `image` of `a`, then, once it is nearly old enough to hide, `bodies` and part `p0`, and
   * replaces the root with part 0, cut off after its commit and before it showed the image that the
   * account's next write hid, and recorded the marker of, after its look: the image referenced and
   * left hidden.
   */
  async function referencedLeftHidden(a, image, bodies, p0) {
    assert.equal((await a.client.putImage(image.name, image.bytes)).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER - 60);
    assert.equal((await a.client.putBodies(bodies)).status, 200);
    assert.equal((await a.client.putPart(p0)).status, 200);
    const r = root({ 0: p0.name });
    const store = worker.b2.hold("PUT", a.key(r.name));
    const replaced = a.client.replace(0, r);
    await store.entered;
    await worker.advanceClock(60);
    assert.equal((await a.client.putBodies([newRecord(1).body])).status, 200);
    await worker.cutD1At(SHOW_REFERENCED);
    store.release();
    assert.equal((await replaced).status, 503);
    await worker.restoreD1();
    assert.equal(a.latest(image.name), "m");
  }

  test("a name hidden for six days less the margin is not held, a replacement that references it is refused, and a put stores it anew", async () => {
    const { a, record, png, p0, first, empty } = await hiddenRecord("boundary-held");
    const names = [png.name, record.body.name, p0.name, first.name];
    await worker.advanceClock(BOUNDARY - 60);
    assert.deepEqual(await held(a, names), names, "inside the boundary");
    assert.equal((await a.client.replace(2, first)).status, 200, "inside the boundary it is shown again");
    assert.ok(await currentAllFetchable(a));
    assert.equal((await a.client.replace(3, empty)).status, 200);

    await worker.advanceClock(BOUNDARY);
    assert.deepEqual(await held(a, names), [], "past the boundary");
    assert.equal((await a.client.getBodies([record.body.name])).status, 404);
    assert.equal((await a.client.getImage(png.name)).status, 404);
    assert.equal((await a.client.getPart(p0.name)).status, 404);
    assert.equal((await a.client.getRoot(first.name)).status, 404);
    const refused = await a.client.replace(4, first);
    assert.deepEqual([refused.status, refused.body], [409, { error: "missing_objects", names: [p0.name] }]);
    assert.equal(a.latest(p0.name), "m", "not shown");
    assert.deepEqual((await a.client.generation()).body, { generation: 4, root: empty.name });

    // A part of a new record naming the gone image: the replacement takes the image as never put.
    const other = newRecord(1, { binding: { skill_png: png.name } });
    assert.deepEqual((await a.client.putBodies([record.body, other.body])).body.results.map((r) => r.status), ["stored", "stored"]);
    const p1 = recordPart(1, [other.row]);
    assert.equal((await a.client.putPart(p1)).status, 200);
    assert.equal((await a.client.replace(4, root({ 1: p1.name }))).status, 200);
    assert.equal(a.latest(png.name), "m", "a gone image is not shown again");
    assert.deepEqual(await held(a, [png.name]), []);
    assert.equal((await a.client.putImage(png.name, png.bytes)).body.status, "stored");
    assert.equal(a.latest(png.name), "v");

    assert.equal((await a.client.putPart(p0)).body.status, "stored");
    assert.equal((await a.client.replace(5, first)).status, 200);
    assert.deepEqual(await held(a, names), names);
    assert.ok(await currentAllFetchable(a));
  });

  test("a reduced-JPEG row whose JPEG is gone references its PNG, as before the JPEG was stored", async () => {
    const token = await worker.signIn("boundary-jpeg");
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    const png = newImage();
    const jpeg = newImage();
    // A normal row references the PNG; nothing references the JPEG, so the account's next write once
    // it is old enough hides it.
    const normal = newRecord(0, { binding: { skill_png: png.name } });
    assert.equal((await client.putImage(png.name, png.bytes)).status, 200);
    assert.equal((await client.putImage(jpeg.name, jpeg.bytes, "image/jpeg")).status, 200);
    assert.equal(worker.b2.versions(`a/${id}/${jpeg.name}`).at(-1), "v");
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal((await client.putBodies([normal.body])).status, 200);
    assert.equal(worker.b2.versions(`a/${id}/${jpeg.name}`).at(-1), "m");
    const p0 = recordPart(0, [normal.row]);
    assert.equal((await client.putPart(p0)).status, 200);
    assert.equal((await client.replace(0, root({ 0: p0.name }))).status, 200);

    // Past the boundary, a reduced-JPEG row takes the normal row's place: the PNG stays referenced through it.
    await worker.advanceClock(BOUNDARY);
    const reduced = newRecord(1, { state: "jpeg", binding: { skill_png: png.name, skill_jpeg: jpeg.name } });
    assert.equal((await client.putBodies([reduced.body])).status, 200);
    const p1 = recordPart(1, [reduced.row]);
    assert.equal((await client.putPart(p1)).status, 200);
    assert.equal((await client.replace(1, root({ 1: p1.name }))).status, 200);
    assert.equal((await client.getImage(png.name)).status, 200, "the JPEG is gone, so the row references the PNG");
    assert.equal((await client.getImage(jpeg.name)).status, 404);

    assert.equal((await client.putImage(jpeg.name, jpeg.bytes, "image/jpeg")).body.status, "stored");
    assert.equal((await client.getImage(jpeg.name)).status, 200);
    assert.equal((await client.getImage(png.name)).status, 404, "stored again, the JPEG stands in for the PNG");
  });

  test("a referenced name a cut-off request left hidden and that went past the boundary meanwhile is shown neither by the hourly run nor by the next write", async () => {
    const token = await worker.signIn("boundary-left");
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    const a = { client, key: (name) => `a/${id}/${name}`, latest: (name) => worker.b2.versions(`a/${id}/${name}`).at(-1) };
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    await referencedLeftHidden(a, image, [record.body], recordPart(0, [record.row]));

    // Nothing came for it until it went past the boundary (sync switched off, say).
    await worker.advanceClock(BOUNDARY);
    assert.equal(await worker.scheduled(), "ok");
    assert.equal((await client.putBodies([newRecord(1).body])).status, 200);
    assert.equal(a.latest(image.name), "m", "not shown again");
    assert.deepEqual((await client.held([image.name])).body.held, []);
    assert.equal((await client.getImage(image.name)).status, 404);

    await worker.advanceClock(LIFECYCLE - BOUNDARY);
    assert.ok(worker.b2.pickExpired().includes(a.key(image.name)));
    worker.b2.deleteExpired();
    assert.equal((await client.putImage(image.name, image.bytes)).body.status, "stored");
    assert.equal((await client.getImage(image.name)).status, 200);
  });

  test("under the image form none, a reduced JPEG whose PNG went past the boundary while referenced is refused", async () => {
    const token = await worker.signIn("boundary-form-jpeg");
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    const a = { client, key: (name) => `a/${id}/${name}`, latest: (name) => worker.b2.versions(`a/${id}/${name}`).at(-1) };
    const png = newImage();
    const jpeg = newImage();
    const record = newRecord(0, { state: "jpeg", binding: { skill_png: png.name, skill_jpeg: jpeg.name } });
    // As in "a referenced name a cut-off request left hidden and that went past the boundary meanwhile":
    // the PNG the root references in the JPEG's place is left hidden.
    await referencedLeftHidden(a, png, [record.body], recordPart(0, [record.row]));
    assert.equal((await client.setImageForm("none")).status, 200);

    await worker.advanceClock(BOUNDARY);
    assert.deepEqual((await client.held([png.name])).body.held, [], "the PNG is gone");
    const res = await client.putImage(jpeg.name, jpeg.bytes, "image/jpeg");
    assert.deepEqual([res.status, res.body], [409, { error: "images_not_synced" }]);
    assert.deepEqual(worker.b2.versions(a.key(jpeg.name)), []);
  });

  test("a referenced name a cut-off request left hidden that goes past the boundary while the hourly run's show is held in B2 stays gone", async () => {
    const token = await worker.signIn("boundary-left-held-show");
    const id = await worker.accountOf(token);
    const client = syncClient(worker, token);
    assert.equal((await client.setImageForm("png")).status, 200);
    const a = { client, key: (name) => `a/${id}/${name}`, latest: (name) => worker.b2.versions(`a/${id}/${name}`).at(-1) };
    const image = newImage();
    const record = newRecord(0, { binding: { skill_png: image.name } });
    // As in "a referenced name a cut-off request left hidden and that went past the boundary meanwhile":
    // the image is referenced and left hidden, with its marker recorded.
    await referencedLeftHidden(a, image, [record.body], recordPart(0, [record.row]));

    // The hourly run reads it just inside the boundary, and B2 deletes it before its show answers.
    await worker.advanceClock(BOUNDARY - 60);
    const show = worker.b2.hold("DELETE_OBJECTS", a.key(image.name));
    const run = worker.scheduled();
    await show.entered;
    await worker.advanceClock(LIFECYCLE - BOUNDARY + 120);
    assert.ok(worker.b2.pickExpired().includes(a.key(image.name)));
    worker.b2.deleteExpired();
    show.release();
    assert.equal(await run, "ok");
    assert.deepEqual((await client.held([image.name])).body.held, []);
    assert.equal((await client.getImage(image.name)).status, 404);
  });

  test("a replacement held in B2 between its look and its show while what it shows goes past the boundary and B2 deletes it is refused, and leaves the root as it was", async () => {
    const { a, record, png, p0, first, empty } = await hiddenRecord("boundary-held-show");
    await worker.advanceClock(BOUNDARY - 60);
    const show = worker.b2.hold("DELETE_OBJECTS", a.key(p0.name));
    const replaced = a.client.replace(2, first);
    await show.entered;
    await worker.advanceClock(LIFECYCLE - BOUNDARY + 120);
    assert.ok(worker.b2.pickExpired().includes(a.key(record.body.name)));
    worker.b2.deleteExpired();
    show.release();
    const res = await replaced;

    const current = (await a.client.generation()).body;
    if (res.status === 200) {
      assert.ok(await currentAllFetchable(a), "committed, every name the root references is fetchable");
    } else {
      assert.equal(res.status, 409, res.text);
      assert.deepEqual(current, { generation: 2, root: empty.name }, "refused, the root is as it was");
      assert.ok(await currentAllFetchable(a));
    }
    // This server refuses: what it showed went past the boundary before its commit. It stays gone,
    // though the refusal hides it again.
    const names = [png.name, record.body.name, p0.name, first.name];
    assert.deepEqual([res.status, res.body.error, [...res.body.names].sort()], [409, "missing_objects", [...names].sort()]);
    assert.deepEqual(await held(a, names), []);
  });

  test("a replacement held at its commit while what it showed goes past the boundary either commits with everything fetchable or is refused", async () => {
    const { a, p0, first, empty } = await hiddenRecord("boundary-held-commit");
    await worker.advanceClock(BOUNDARY - 60);
    // Stop it at showing, then hold its commit, the next batch, at the gate.
    const show = worker.b2.hold("DELETE_OBJECTS", a.key(p0.name));
    const replaced = a.client.replace(2, first);
    await show.entered;
    await worker.armGate(2);
    show.release();
    while ((await worker.gate()).arrived < 1) await new Promise((resolve) => setTimeout(resolve, 5));
    await worker.advanceClock(LIFECYCLE);
    worker.b2.pickExpired();
    worker.b2.deleteExpired();
    // Another account's put is the second batch the gate waits for.
    const other = syncClient(worker, await worker.signIn("boundary-held-commit-other"));
    assert.equal((await other.setImageForm("png")).status, 200);
    const image = newImage();
    assert.equal((await other.putImage(image.name, image.bytes)).status, 200);
    const res = await replaced;

    if (res.status === 200) {
      assert.deepEqual((await a.client.generation()).body, { generation: 3, root: first.name });
    } else {
      assert.equal(res.status, 409, res.text);
      assert.deepEqual((await a.client.generation()).body, { generation: 2, root: empty.name });
    }
    assert.ok(await currentAllFetchable(a));
  });

  test("a name a replacement took over and a run hid again stays hidden since its first hide, and is gone at the boundary from it", async () => {
    const { a, record, png, p0, first } = await hiddenRecord("boundary-since");
    const names = [png.name, record.body.name, p0.name, first.name];
    await worker.advanceClock(BOUNDARY - limits.SYNC_ABANDONED_AFTER - 120);
    // The replacement takes the rows over and B2 fails its show: they are left to the hourly run.
    worker.b2.fail(a.key(p0.name));
    assert.deepEqual((await a.client.replace(2, first)).body, { error: "storage_unavailable" });
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual(worker.b2.versions(a.key(p0.name)), ["v", "m", "m"], "hidden again over the first marker");
    assert.deepEqual(await held(a, names), names);

    await worker.advanceClock(120);
    assert.deepEqual(await held(a, names), [], "gone six days less the margin after the first hide");
  });

  test("a name put again after B2's lifecycle picked its old version stays fetchable once that version is deleted", async () => {
    const { a, record, png, p0, first } = await hiddenRecord("boundary-put-again");
    const names = [png.name, record.body.name, p0.name, first.name];
    await worker.advanceClock(LIFECYCLE);
    assert.deepEqual(worker.b2.pickExpired().filter((k) => k.startsWith(a.key(""))), names.map(a.key).sort());
    assert.deepEqual(await held(a, names), []);

    assert.equal((await a.client.putImage(png.name, png.bytes)).body.status, "stored");
    assert.deepEqual((await a.client.putBodies([record.body])).body.results.map((r) => r.status), ["stored"]);
    assert.equal((await a.client.putPart(p0)).body.status, "stored");
    assert.equal((await a.client.replace(2, first)).status, 200, "the root is stored anew too");
    assert.deepEqual(await held(a, names), names);
    worker.b2.deleteExpired();
    for (const name of names) assert.equal(a.latest(name), "v", name);
    assert.ok(await currentAllFetchable(a));
  });

  const DAY = 86_400;

  /** The names of account `a`'s rows, sorted. */
  const rowsOf = async (a) =>
    (await worker.db.prepare("SELECT name FROM sync_objects WHERE account_id = ?").bind(a.id).all()).results.map((r) => r.name).sort();

  /** What `usage` (sync_quota.mjs) answers for account `a` at the Worker's clock now, its total apart: other suites' rows count there too. */
  const usageOf = async (a) => {
    const { stored, hidden, hiddenSince, records } = await usage(worker.db, a.id, await worker.now());
    return { stored, hidden, hiddenSince, records };
  };

  test("the hourly run deletes the rows of names gone past the boundary that nothing references, a day after it, and a replacement or a put of those names answers as before", async () => {
    const { a, record, png, p0, first, empty } = await hiddenRecord("forget-gone");
    const names = [png.name, record.body.name, p0.name, first.name];
    const all = [...names, empty.name].sort();
    await worker.advanceClock(BOUNDARY + limits.SYNC_ABANDONED_AFTER);
    assert.deepEqual(await held(a, names), [], "gone");
    const counted = await usageOf(a);
    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual(await rowsOf(a), all, "kept until the day of the boundary is one no count reads");
    assert.deepEqual(await usageOf(a), counted);

    await worker.advanceClock(DAY + limits.SYNC_ABANDONED_AFTER);
    const later = await usageOf(a);
    assert.equal(await worker.scheduled(), "ok");
    assert.deepEqual(await rowsOf(a), [empty.name], "the rows of the gone names deleted, the current root's kept");
    assert.deepEqual(await usageOf(a), later, "the counts read the same after the deletion");

    assert.deepEqual(await held(a, names), []);
    assert.equal((await a.client.getBodies([record.body.name])).status, 404);
    assert.equal((await a.client.getImage(png.name)).status, 404);
    const refused = await a.client.replace(2, first);
    assert.deepEqual([refused.status, refused.body], [409, { error: "missing_objects", names: [p0.name] }]);
    assert.equal((await a.client.putImage(png.name, png.bytes)).body.status, "stored");
    assert.deepEqual((await a.client.putBodies([record.body])).body.results.map((r) => r.status), ["stored"]);
    assert.equal((await a.client.putPart(p0)).body.status, "stored");
    assert.equal((await a.client.replace(2, first)).status, 200);
    assert.deepEqual(await held(a, names), names);
    assert.ok(await currentAllFetchable(a));
  });

  test("the row of an image a list named and nobody put goes with the replacement or the JPEG put that leaves it unreferenced", async () => {
    const { a } = await hiddenRecord("forget-unstored");
    const record = newRecord(0);
    const unput = [record.row.image.skill_png, record.row.image.factor_png];
    assert.equal((await a.client.putBodies([record.body])).status, 200);
    const p0 = recordPart(0, [record.row]);
    assert.equal((await a.client.putPart(p0)).status, 200);
    assert.equal((await a.client.replace(2, root({ 0: p0.name }))).status, 200);
    assert.deepEqual((await rowsOf(a)).filter((n) => unput.includes(n)), [...unput].sort(), "named, not put");
    assert.equal((await a.client.replace(3, root({}))).status, 200);
    assert.deepEqual((await rowsOf(a)).filter((n) => unput.includes(n)), [], "the replacement that stops naming them deletes their rows");

    const png = newImage();
    const jpeg = newImage();
    const reduced = newRecord(1, { state: "jpeg", binding: { skill_png: png.name, skill_jpeg: jpeg.name } });
    assert.equal((await a.client.putBodies([reduced.body])).status, 200);
    const p1 = recordPart(1, [reduced.row]);
    assert.equal((await a.client.putPart(p1)).status, 200);
    assert.equal((await a.client.replace(4, root({ 1: p1.name }))).status, 200);
    assert.ok((await rowsOf(a)).includes(png.name), "the PNG referenced in the JPEG's place");
    assert.equal((await a.client.putImage(jpeg.name, jpeg.bytes)).status, 200);
    assert.ok(!(await rowsOf(a)).includes(png.name), "the JPEG put that takes its references deletes the PNG's row");
    assert.equal((await a.client.getImage(jpeg.name)).status, 200);
    assert.equal((await a.client.getImage(png.name)).status, 404);
    assert.deepEqual(await held(a, [png.name, jpeg.name]), [jpeg.name]);
  });

  test("the row of a name whose hide B2 failed stays past the boundary until a hide takes it again, and goes once one has", async () => {
    const { a } = await hiddenRecord("forget-hiding");
    const { body } = newRecord(5);
    assert.equal((await a.client.putBodies([body])).status, 200);
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    worker.b2.fail(a.key(body.name));
    assert.equal((await a.client.putBodies([newRecord(6).body])).status, 200);
    assert.equal(a.latest(body.name), "v", "B2 failed the hide");

    await worker.advanceClock(BOUNDARY + DAY + limits.SYNC_ABANDONED_AFTER);
    worker.b2.fail(a.key(body.name));
    assert.equal(await worker.scheduled(), "ok");
    assert.equal(a.latest(body.name), "v", "B2 failed the hide again");
    assert.ok((await rowsOf(a)).includes(body.name), "kept while no hide has taken it again");
    // The run's hide that B2 failed is abandoned in its turn before a hide takes the row again.
    await worker.advanceClock(limits.SYNC_ABANDONED_AFTER);
    assert.equal(await worker.scheduled(), "ok");
    assert.equal(a.latest(body.name), "m");
    assert.ok(!(await rowsOf(a)).includes(body.name), "deleted by the run whose hide took it");
  });

  test("an account's rows once the hourly run has run a day past the boundary follow the records its root lists, not how many times it replaced the root", async () => {
    const RECORDS = 3;
    /** Syncs `RECORDS` records, each with a PNG put and one a list names and nobody puts, then changes record 0 `edits` times; returns the account's rows after the run. */
    async function edited(sub, edits) {
      const token = await worker.signIn(sub);
      const id = await worker.accountOf(token);
      const client = syncClient(worker, token);
      assert.equal((await client.setImageForm("png")).status, 200);
      const a = { id, client };
      const records = [];
      const parts = {};
      for (let n = 0; n < RECORDS; n++) {
        const png = newImage();
        assert.equal((await client.putImage(png.name, png.bytes)).status, 200);
        records.push(newRecord(n, { binding: { skill_png: png.name, factor_png: newImage().name } }));
        assert.equal((await client.putBodies([records[n].body])).status, 200);
        parts[n] = recordPart(n, [records[n].row]);
        assert.equal((await client.putPart(parts[n])).status, 200);
      }
      let generation = 0;
      const replace = async () => assert.equal((await client.replace(generation++, root(Object.fromEntries(Object.entries(parts).map(([s, p]) => [s, p.name]))))).status, 200);
      await replace();
      for (let i = 0; i < edits; i++) {
        const next = newRecord(0, { binding: records[0].row.image });
        assert.equal((await client.putBodies([next.body])).status, 200);
        parts[0] = recordPart(0, [next.row]);
        assert.equal((await client.putPart(parts[0])).status, 200);
        await replace();
      }
      await worker.advanceClock(BOUNDARY + DAY + limits.SYNC_ABANDONED_AFTER);
      assert.equal(await worker.scheduled(), "ok");
      const referenced = (await worker.db.prepare("SELECT count(*) AS n FROM sync_objects WHERE account_id = ? AND ref_count > 0").bind(id).first()).n;
      return { rows: (await rowsOf(a)).length, referenced };
    }
    // What the root lists: itself, and per record its part, its body and its two images.
    const listed = 1 + RECORDS * 4;
    const few = await edited("forget-few-edits", 2);
    const many = await edited("forget-many-edits", 8);
    assert.deepEqual(few, { rows: listed, referenced: listed });
    assert.deepEqual(many, few, "six more edits leave no more rows");
  });
});
