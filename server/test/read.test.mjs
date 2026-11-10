// The read side of the sharing Worker, driven over HTTP against a real (local) D1.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { REPORT_DAILY_LIMIT } from "../src/limits.mjs";
import { PAGE_CSP } from "../src/page.mjs";
import { imageBundle, newClientKey, OG_ORIGIN, ORIGIN, postedForm, SENTRY, startWorker, TURNSTILE } from "./support/worker_harness.mjs";

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
    assert.deepEqual(json.factors.self, [{ gid: 3002, name: "factor 1", color: "red", star: 3 }]);
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

  test("JSON colours each factor by its tags and totals the factors of the three slots", async () => {
    const id = "2123456789";
    const f = (id, star) => ({ id, star });
    const factors = {
      self: [f(4, 1), f(0, 3), f(3, 1)],
      parent1: [f(1, 2), f(5, 3), f(2, 1), f(4, 2)],
      parent2: [f(3, 2), f(0, 2), f(2, 3), f(5, 1)],
    };
    await worker.insertRecord(id, postedForm({ factors }), 20_725);
    const json = await (await worker.fetch(`/r/${id}.json`)).json();
    // Tagged factor_status, factor_aptitude, factor_unique_skill, factor_normal_skill,
    // factor_status_gene, and factor_scenario with other (test/fixtures/tables.json).
    const factor = (n, color, star) => ({ gid: 3001 + n, name: `factor ${n}`, color, star });
    assert.deepEqual(json.factors.parent1, [
      factor(1, "red", 2),
      factor(5, "white", 3),
      factor(2, "green", 1),
      factor(4, "white", 2),
    ]);
    // Blue, red, green, white; most stars first; equal stars (factors 4 and 3) in the order they
    // first occur, self before the parents.
    assert.deepEqual(json.factor_totals, [
      factor(0, "blue", 5),
      factor(1, "red", 2),
      factor(2, "green", 4),
      factor(5, "white", 4),
      factor(4, "white", 3),
      factor(3, "white", 3),
    ]);
    assert.deepEqual(json.view, { focus: "training" });
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
    assert.ok(html.includes('<div class="rec-support">support 1<span class="rec-k">Lv50</span></div>'), "support cards missing");
    // The recognizer misreads limit breaks, so the page leaves them out; public JSON still has them.
    assert.equal(html.includes("凸"), false, "a limit break reached the page");
    assert.ok(html.includes("<dt>共有日</dt><dd>2026-09-29</dd>"), "share day row missing");
    assert.equal(html.includes("公開日"), false, "the share day is still labelled 公開日");
    assert.ok(html.includes('<a href="/privacy/">'), "the footer does not link the privacy policy");
  });

  test("page of an inheritance-only record is served and names both parents", async () => {
    const id = "1123456789";
    await worker.insertRecord(id, postedForm({ record_type: "InheritanceOnly" }), 20_725);
    const res = await worker.fetch(`/r/${id}`);
    assert.equal(res.status, 200);
    const html = await res.text();
    for (const parent of ["chara 1", "chara 2"]) {
      assert.ok(html.includes(`<strong>${parent}</strong>`), `parent ${parent} missing`);
    }
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
    assert.ok(html.includes('<a href="/privacy/">'), "the footer does not link the privacy policy");

    // The sort query reorders the same records, and an unknown value falls back to the default.
    for (const query of ["?sort=evaluation", "?sort=bogus"]) {
      const sorted = await worker.fetch(`/u/${owner}${query}`);
      assert.equal(sorted.status, 200, query);
      const listed = [...(await sorted.text()).matchAll(/<a href="[^"]*\/r\/([0-9a-z]{10})">/g)].map((m) => m[1]);
      assert.deepEqual(listed.sort(), ["a000000000", "b000000000", older].sort(), query);
      assert.equal(listed.includes(theirs), false, `another account's share is listed under ${query}`);
    }

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

describe("import endpoint", () => {
  let worker;
  before(async () => {
    worker = await startWorker();
  });
  after(() => worker.dispose());

  test("tells a share without images, with its bundle pending and with it stored apart, serves the bundle only once stored, and neither once unshared", async () => {
    const token = await worker.signIn();
    const bundle = imageBundle({ seed: 7, trainee: false });
    const res = await worker.share(token, [
      { client_key: newClientKey(), record: postedForm(), images: bundle.images },
      { client_key: newClientKey(), record: postedForm() },
    ]);
    const [shared, plain] = (await res.json()).results;
    const imported = async (id) => (await (await worker.fetch(`/api/shares/${id}`)).json()).images;
    const bundleStatus = async (id) => {
      const got = await worker.getImages(id);
      await got.arrayBuffer();
      return got.status;
    };

    assert.equal(await imported(plain.id), null);
    assert.deepEqual(await imported(shared.id), { state: "pending" });
    assert.equal(await bundleStatus(shared.id), 404);

    assert.equal((await worker.putImages(token, shared.id, bundle.bytes)).status, 200);
    assert.deepEqual(await imported(shared.id), { state: "stored", ...bundle.images });
    const served = await worker.getImages(shared.id);
    assert.deepEqual(Buffer.from(await served.arrayBuffer()), Buffer.from(bundle.bytes));

    // The public JSON and page carry nothing of the images: they are those of the share without them.
    const publicOf = async (id) => {
      const { id: _id, url: _url, ...rest } = await (await worker.fetch(`/r/${id}.json`)).json();
      return rest;
    };
    assert.deepEqual(await publicOf(shared.id), await publicOf(plain.id));
    assert.equal((await (await worker.fetch(`/r/${shared.id}`)).text()).includes(bundle.images.name), false);

    assert.equal((await worker.unshare(token, shared.id)).status, 204);
    const gone = await worker.fetch(`/api/shares/${shared.id}`);
    assert.deepEqual([gone.status, await gone.json()], [404, { error: "not_found" }]);
    assert.equal(await bundleStatus(shared.id), 404);
  });
});

describe("share report", () => {
  const REPORT_TOKEN = "turnstile-report-token";
  const passingReport = () => ({ success: true, hostname: TURNSTILE.HOSTNAME, action: "report" });
  const today = () => Math.floor(Date.now() / 86_400_000);
  /** POST /api/reports as the report page's form sends it; `fields` and `headers` override. */
  const report = (worker, fields = {}, headers = {}) =>
    worker.fetch("/api/reports", {
      method: "POST",
      headers: { Origin: ORIGIN, "Content-Type": "application/x-www-form-urlencoded", ...headers },
      body: new URLSearchParams({ id: ID, reason: "personal_info", text: "", token: REPORT_TOKEN, ...fields }).toString(),
    });
  /** The outcome a report's answer page names, after its status. */
  const outcome = async (res) => `${res.status} ${/data-outcome="([a-z]+)"/.exec(await res.text())?.[1] ?? "none"}`;

  test("a report of a share reaches Sentry as one event naming the share, the reason and the text, and nothing of the reporter, and is accepted only when Sentry takes it", async () => {
    const worker = await startWorker();
    try {
      await worker.insertRecord(ID, postedForm(), 20_725);
      worker.siteverify.answer = passingReport;

      // The share page stays without a script, keeps its CSP and cache, and links to the report page.
      const shared = await worker.fetch(`/r/${ID}`);
      const html = await shared.text();
      assert.equal(shared.headers.get("content-security-policy"), PAGE_CSP);
      assert.equal(shared.headers.get("cache-control"), "public, max-age=300");
      assert.equal(html.includes("<script"), false);
      assert.match(html, new RegExp(`href="${ORIGIN}/r/${ID}/report"`));
      const form = await worker.fetch(`/r/${ID}/report`);
      assert.equal(form.status, 200);
      assert.match(await form.text(), /data-action="report"[^>]*data-response-field-name="token"/);
      const missing = await worker.fetch("/r/9999999999/report");
      assert.equal(missing.status, 404);
      await missing.arrayBuffer();

      const text = "二枚目の画像に名前が写っています";
      const accepted = await report(worker, { text }, { Cookie: "uc_session=reporter-cookie", "CF-Connecting-IP": "203.0.113.9" });
      assert.equal(await outcome(accepted), "200 accepted");
      assert.equal(worker.sentry.calls.length, 1);
      const [call] = worker.sentry.calls;
      assert.equal(call.url, SENTRY.ENDPOINT);
      for (const sent of [call.body, JSON.stringify(call.headers)]) {
        for (const value of ["reporter-cookie", "203.0.113.9"]) assert.equal(sent.includes(value), false, value);
      }
      const event = JSON.parse(call.body.split("\n")[2]);
      assert.deepEqual(event.extra, { share_id: ID, text, shared_on: "2026-09-29" });
      assert.deepEqual(event.tags, { kind: "share_report", reason: "personal_info" });
      for (const key of ["user", "request"]) assert.equal(key in event, false, key);
      const daily = await worker.db.prepare("SELECT reports FROM daily WHERE day = ?").bind(today()).first();
      assert.equal(daily.reports, 1);

      // Sentry failing is told as a failure; a report of no share and one Turnstile did not pass for
      // this page are not sent.
      worker.sentry.status = 500;
      assert.equal(await outcome(await report(worker)), "502 unsent");
      worker.sentry.status = 200;
      assert.equal((await report(worker, { id: "9999999999" })).status, 404);
      worker.siteverify.answer = () => ({ ...passingReport(), action: "login" });
      assert.equal(await outcome(await report(worker)), "403 unverified");
      worker.siteverify.answer = passingReport;

      // The day's limit refuses the next report without sending it.
      await worker.db.prepare("UPDATE daily SET reports = ? WHERE day = ?").bind(REPORT_DAILY_LIMIT, today()).run();
      assert.equal(await outcome(await report(worker)), "429 limit");
      assert.equal(worker.sentry.calls.length, 2);
    } finally {
      await worker.dispose();
    }
  });

  test("reports are accepted while sharing, sync and shared images are paused, and refused unsent where no DSN is set", async () => {
    const paused = await startWorker({ vars: { SHARING_ENABLED: "false", SYNC_ENABLED: "false", SHARE_IMAGES_ENABLED: "false" } });
    const off = await startWorker({ vars: { REPORT_SENTRY_DSN: "" } });
    try {
      for (const worker of [paused, off]) {
        await worker.insertRecord(ID, postedForm(), 20_725);
        worker.siteverify.answer = passingReport;
      }
      assert.equal(await outcome(await report(paused)), "200 accepted");
      assert.equal(paused.sentry.calls.length, 1);
      assert.equal(await outcome(await off.fetch(`/r/${ID}/report`)), "503 off");
      assert.equal(await outcome(await report(off)), "503 off");
      assert.equal(off.sentry.calls.length, 0);
    } finally {
      await Promise.all([paused.dispose(), off.dispose()]);
    }
  });
});
