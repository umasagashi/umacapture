// The read side of the sharing Worker, driven over HTTP against a real (local) D1.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { OG_ORIGIN, ORIGIN, postedForm, startWorker } from "./support/worker_harness.mjs";

const ID = "0123456789";
const HOSTILE_CARD = "card <b>&\"'";

describe("published record", () => {
  let worker;
  before(async () => {
    worker = await startWorker();
    await worker.insertRecord(ID, postedForm(), 20_725);
  });
  after(() => worker.dispose());

  test("JSON resolves gids and names from the server tables", async () => {
    const res = await worker.fetch(`/r/${ID}.json`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(res.headers.get("access-control-allow-origin"), "*");
    const json = await res.json();
    assert.equal(json.schema, 1);
    assert.equal(json.id, ID);
    assert.equal(json.url, `${ORIGIN}/r/${ID}`);
    assert.equal(json.published_on, "2026-09-29");
    assert.equal(json.tables_version, "2026-01-01T00:00:00Z");
    assert.deepEqual(json.trainee, {
      card: { gid: 1004, name: HOSTILE_CARD },
      character: { name: "chara 3" },
      rank: { name: "rank 2" },
    });
    assert.deepEqual(json.skills, [
      { gid: 2003, name: "skill 2", level: 3 },
      { gid: 2001, name: "skill 0" },
    ]);
    assert.deepEqual(json.factors.self, [{ gid: 3002, name: "factor 1", star: 3 }]);
    assert.deepEqual(json.support_cards, [{ name: "support 1", limit_break: 4, level: 50 }]);
    assert.deepEqual(json.aptitudes.distance.middle, { name: "A", value: 6 });
    assert.deepEqual(json.family.parent1.self, { card: { gid: 1002, name: "card 1" }, character: { name: "chara 1" } });
    assert.equal(json.family.parent2.rental, false);
    assert.deepEqual(json.scenario, { name: "scenario 1" });
    assert.equal(json.trained_on, "2026-09-30");
    assert.equal(json.evaluation, 12345);
    assert.deepEqual(json.races[0].title, { gid: 4003, name: "race 2" });
    assert.equal(json.races[0].distance, 2400);
    for (const key of ["trainer_id", "module_version", "evaluation_value"]) assert.equal(key in json, false, key);
  });

  test('JSON names finishing positions 1st and 18th as "1" and "18"', async () => {
    const json = await (await worker.fetch(`/r/${ID}.json`)).json();
    assert.deepEqual(
      json.races.map((r) => r.position.name),
      ["1", "18"],
    );
  });

  test("page escapes table names in the HTML and shows the items of public JSON beyond the headline", async () => {
    const res = await worker.fetch(`/r/${ID}`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
    assert.match(res.headers.get("content-security-policy"), /default-src 'none'/);
    const html = await res.text();
    assert.equal(html.includes("<b>"), false, "a raw table name reached the markup");
    assert.ok(html.includes("<h1>card &lt;b&gt;&amp;&quot;&#39;</h1>"), "escaped heading missing");
    assert.ok(html.includes("<title>card &lt;b&gt;&amp;&quot;&#39; rank 2 12345 | umacapture</title>"), "escaped title missing");
    assert.ok(html.includes("<li>support 1 4凸 Lv50</li>"), "support cards missing");
  });
});

describe("og:image", () => {
  const metas = (html) => ({
    image: /<meta property="og:image" content="([^"]*)">/.exec(html)?.[1],
    width: /<meta property="og:image:width" content="([^"]*)">/.exec(html)?.[1],
    card: /<meta name="twitter:card" content="([^"]*)">/.exec(html)?.[1],
  });

  test("OG_IMAGE_MODE switches og:image and twitter:card", async () => {
    const seen = {};
    for (const mode of ["static", "vercel"]) {
      const worker = await startWorker({ ogImageMode: mode });
      try {
        await worker.insertRecord(ID, postedForm());
        seen[mode] = metas(await (await worker.fetch(`/r/${ID}`)).text());
      } finally {
        await worker.dispose();
      }
    }
    assert.deepEqual(seen.static, { image: `${ORIGIN}/og/default.png`, width: undefined, card: "summary" });
    assert.deepEqual(seen.vercel, { image: `${OG_ORIGIN}/r/${ID}.png`, width: "1200", card: "summary_large_image" });
  });
});

describe("paths", () => {
  test("unknown paths and malformed ids answer 404 without reaching D1", async () => {
    // This D1 has no table: any query throws, so a 404 here was answered before D1.
    const worker = await startWorker({ migrate: false });
    try {
      const requests = [
        ["GET", "/"],
        ["GET", "/anything"],
        ["GET", "/r/"],
        ["GET", "/r/012345678"], // 9 characters
        ["GET", "/r/01234567890"], // 11 characters
        ["GET", "/r/012345678A"], // upper case
        ["GET", "/r/012345678i"], // not Crockford base32
        ["GET", "/r/0123456789.png"],
        ["GET", "/r/0123456789/"],
        ["POST", "/r/0123456789"],
        ["OPTIONS", "/r/0123456789.json"],
      ];
      for (const [method, path] of requests) {
        const res = await worker.fetch(path, { method });
        assert.equal(res.status, 404, `${method} ${path}`);
        await res.arrayBuffer();
      }
      // Control: a well-formed id does query D1, which fails here.
      const control = await worker.fetch(`/r/${ID}.json`);
      assert.equal(control.status, 500, "a well-formed id should have queried D1");
      await control.arrayBuffer();
    } finally {
      await worker.dispose();
    }
  });

  test("a well-formed id with no row answers 404", async () => {
    const worker = await startWorker();
    try {
      for (const path of [`/r/${ID}`, `/r/${ID}.json`]) {
        const res = await worker.fetch(path);
        assert.equal(res.status, 404, path);
        await res.arrayBuffer();
      }
    } finally {
      await worker.dispose();
    }
  });
});
