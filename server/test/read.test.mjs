// The read side of the sharing Worker, driven over HTTP against a real (local) D1.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { newClientKey, OG_ORIGIN, ORIGIN, postedForm, startWorker } from "./support/worker_harness.mjs";

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
    assert.equal(json.shared_on, "2026-09-29");
    assert.equal("published_on" in json, false, "the share day is still named published_on");
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
    assert.ok(html.includes("<tr><th>共有日</th><td>2026-09-29</td></tr>"), "share day row missing");
    assert.equal(html.includes("公開日"), false, "the share day is still labelled 公開日");
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
        ["GET", "/u/"],
        ["GET", "/u/012345678901234"], // 15 characters
        ["GET", "/u/01234567890123456"], // 17 characters
        ["GET", "/u/0123456789012345/"],
        ["GET", "/u/0123456789"], // a record id
        ["POST", "/u/0123456789012345"],
        // The endpoints of publishing with a ticket and a delete key, replaced by sharing under an account.
        ["GET", "/api/verify?h=" + "0".repeat(64)],
        ["POST", "/api/tickets"],
        ["POST", "/api/records"],
        ["POST", "/api/records/lookup"],
        ["DELETE", "/api/records/0123456789"],
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

describe("account list", () => {
  let worker;
  before(async () => {
    worker = await startWorker({ testEntry: true });
  });
  after(() => worker.dispose());

  /** Shares the fixture's form once under `token` and returns its id. */
  async function shareOne(token) {
    const res = await worker.share(token, [{ client_key: newClientKey(), record: postedForm() }]);
    const [result] = (await res.json()).results;
    assert.equal(result.status, "created", JSON.stringify(result));
    return result.id;
  }

  test("/u/<id> lists the account's own shares newest day first, without a session, and names nothing but its id", async () => {
    const token = await worker.signIn("100000000000000000021");
    const other = await worker.signIn("100000000000000000022");
    const owner = await worker.accountOf(token);
    const older = await shareOne(token);
    const theirs = await shareOne(other);
    await worker.advanceClock(86_400);
    await worker.forcePublicIds(["b000000000", "a000000000"]);
    const later = [await shareOne(token), await shareOne(token)];
    assert.deepEqual(later, ["b000000000", "a000000000"]);
    const today = Math.floor((await worker.now()) / 86_400);
    const day = (offset) => new Date((today + offset) * 86_400_000).toISOString().slice(0, 10);

    // Reading needs no session: none is sent, and none is left in D1.
    await worker.db.prepare("DELETE FROM sessions").run();
    const res = await worker.fetch(`/u/${owner}.json`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(res.headers.get("cache-control"), "public, max-age=60");
    assert.equal(res.headers.get("x-robots-tag"), "noindex");
    const json = await res.json();
    assert.deepEqual(Object.keys(json).sort(), ["count", "id", "records", "schema", "url"]);
    assert.deepEqual(
      { schema: json.schema, id: json.id, url: json.url, count: json.count },
      { schema: 1, id: owner, url: `${ORIGIN}/u/${owner}`, count: 3 },
    );
    assert.deepEqual(
      json.records.map((r) => [r.id, r.shared_on]),
      [
        ["a000000000", day(0)],
        ["b000000000", day(0)],
        [older, day(-1)],
      ],
    );
    assert.equal(json.records.some((r) => r.id === theirs), false, "another account's share is listed");
    for (const record of json.records) {
      assert.deepEqual(Object.keys(record).sort(), ["evaluation", "id", "record_type", "shared_on", "trainee", "url"]);
    }
    assert.deepEqual(json.records[0], {
      id: "a000000000",
      url: `${ORIGIN}/r/a000000000`,
      shared_on: day(0),
      record_type: "standard",
      trainee: { card: { gid: 1004, name: HOSTILE_CARD }, character: { name: "chara 3" }, rank: { name: "rank 2" } },
      evaluation: 12345,
    });

    const page = await worker.fetch(`/u/${owner}`);
    assert.equal(page.status, 200);
    assert.equal(page.headers.get("content-type"), "text/html; charset=utf-8");
    assert.equal(page.headers.get("cache-control"), "public, max-age=60");
    assert.equal(page.headers.get("x-robots-tag"), "noindex");
    assert.match(page.headers.get("content-security-policy"), /default-src 'none'/);
    const html = await page.text();
    assert.ok(html.includes('<meta name="robots" content="noindex">'));
    assert.ok(html.includes(`<meta property="og:image" content="${ORIGIN}/og/default.png">`));
    assert.ok(html.includes('<meta name="twitter:card" content="summary">'));
    assert.ok(html.includes(`<a href="${ORIGIN}/r/${older}">`), "a listed record links to its page");
    assert.equal(html.includes("<b>"), false, "a raw table name reached the markup");

    // The records of the list read without a session too.
    for (const path of [`/r/${older}`, `/r/${older}.json`]) {
      const read = await worker.fetch(path);
      assert.equal(read.status, 200, path);
      await read.arrayBuffer();
    }
  });

  test("an account sharing nothing has an empty list, and an id no account holds answers 404", async () => {
    const owner = await worker.accountOf(await worker.signIn("100000000000000000023"));
    const empty = await worker.fetch(`/u/${owner}.json`);
    assert.equal(empty.status, 200);
    assert.deepEqual(await empty.json(), { schema: 1, id: owner, url: `${ORIGIN}/u/${owner}`, count: 0, records: [] });
    for (const path of [`/u/${"0".repeat(16)}`, `/u/${"0".repeat(16)}.json`]) {
      const res = await worker.fetch(path);
      assert.equal(res.status, 404, path);
      await res.arrayBuffer();
    }
  });
});
