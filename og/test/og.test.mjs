// The OGP image function, driven through its handler with real HTTP requests. The upstream (the
// public JSON, the fonts and the logo) is a local HTTP server; nothing leaves the machine. Any other
// fetch — @vercel/og looks up glyphs the given fonts lack on Google Fonts — is refused and logged.

import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { after, before, beforeEach, describe, test } from "node:test";

import { buildFallbackCard, pngDataUri } from "../src/card.mjs";
import {
  CACHE_NONE,
  CACHE_NOT_FOUND,
  CACHE_SUCCESS,
  FALLBACK_PATH,
  FONT_FILES,
  LOGO_PATH,
  createHandler,
} from "../src/handler.mjs";

const realFetch = globalThis.fetch;
const externalFetches = [];
globalThis.fetch = async (url) => {
  externalFetches.push(String(url));
  throw new Error(`external fetch refused in tests: ${url}`);
};

const ID = "0123456789";
const record = await readFile(new URL("./fixtures/record.json", import.meta.url));
// A small Latin font stands in for the multi-megabyte Japanese fonts under web/og/fonts/; the card's
// Japanese labels render as missing glyphs, which these tests do not look at.
const font = await readFile(new URL("../node_modules/@vercel/og/dist/Geist-Regular.ttf", import.meta.url));
const web = new URL("../../web/", import.meta.url);
const logo = await readFile(new URL(`.${LOGO_PATH}`, web));

/** What the local upstream answers, per path; a test replaces entries. Every request is logged. */
let routes;
const requests = [];
const server = createServer((req, res) => {
  requests.push(req.url);
  const route = routes[req.url];
  if (!route) {
    res.writeHead(404).end();
    return;
  }
  route(res);
});
const send = (body, type) => (res) => res.writeHead(200, { "content-type": type }).end(body);
const status = (code) => (res) => res.writeHead(code).end();

let origin;
before(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
after(() => {
  server.closeAllConnections();
  server.close();
});
beforeEach(() => {
  requests.length = 0;
  externalFetches.length = 0;
  routes = {
    [`/r/${ID}.json`]: send(record, "application/json"),
    [LOGO_PATH]: send(logo, "image/png"),
    ...Object.fromEntries(FONT_FILES.map(({ path }) => [path, send(font, "font/ttf")])),
  };
});

const handler = (limits) => createHandler({ origin, fetch: realFetch, limits, log: () => {} });
const get = (handle, path, method = "GET") => handle(new Request(`https://og.example${path}`, { method }));

describe("OGP image", () => {
  test("a drawn image carries the one-hour cache, not @vercel/og's one-year immutable default", async () => {
    const response = await get(handler(), `/r/${ID}.png`);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/png");
    assert.equal(response.headers.get("cache-control"), CACHE_SUCCESS);
    assert.equal(CACHE_SUCCESS, "public, max-age=3600, s-maxage=3600");
    const png = Buffer.from(await response.arrayBuffer());
    assert.equal(png.subarray(1, 4).toString("latin1"), "PNG");
    assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [1200, 630]);
  });

  test("a malformed path or any query string is 404 without fetching the upstream", async () => {
    const handle = handler();
    const paths = [
      `/r/${ID}.png?a=1`,
      `/r/${ID}.png?`,
      `/r/${ID}.json`,
      "/r/012345678.png",
      "/r/0123456789A.png",
      "/r/012345678i.png",
      "/api/og",
      "/",
    ];
    for (const path of paths) {
      const response = await get(handle, path);
      assert.equal(response.status, 404, path);
      assert.equal(response.headers.get("cache-control"), CACHE_NOT_FOUND, path);
    }
    assert.equal((await get(handle, `/r/${ID}.png`, "POST")).status, 405);
    assert.deepEqual(requests, []);
  });

  describe("upstream outcomes", () => {
    test("upstream 404 is 404", async () => {
      delete routes[`/r/${ID}.json`];
      const response = await get(handler(), `/r/${ID}.png`);
      assert.equal(response.status, 404);
      assert.equal(response.headers.get("cache-control"), CACHE_NOT_FOUND);
      assert.deepEqual(requests, [`/r/${ID}.json`]);
    });

    const temporary = {
      "upstream 429": () => (routes[`/r/${ID}.json`] = status(429)),
      "upstream 503": () => (routes[`/r/${ID}.json`] = status(503)),
      "upstream redirect": () =>
        (routes[`/r/${ID}.json`] = (res) => res.writeHead(302, { location: "/elsewhere" }).end()),
      "upstream timeout": () => (routes[`/r/${ID}.json`] = () => {}),
      "upstream body over the cap": () => (routes[`/r/${ID}.json`] = send("x".repeat(70 * 1024), "application/json")),
      "upstream body is not public JSON v1": () =>
        (routes[`/r/${ID}.json`] = send(JSON.stringify({ schema: 2 }), "application/json")),
      // The bytes arrive, so ImageResponse is constructed; the font only fails to parse inside the
      // render, which runs while the body is read.
      "render fails inside the body": () => {
        routes[FONT_FILES[0].path] = send("not a font", "font/ttf");
      },
    };
    for (const [name, arrange] of Object.entries(temporary)) {
      test(`${name} is a 302 to the fallback image that is not cached`, async () => {
        arrange();
        const response = await get(handler({ upstreamTimeoutMs: 300 }), `/r/${ID}.png`);
        assert.equal(response.status, 302);
        assert.equal(response.headers.get("location"), `${origin}${FALLBACK_PATH}`);
        assert.equal(response.headers.get("cache-control"), CACHE_NONE);
      });
    }
  });
});

// The fonts are gitignored and placed by tool/fetch_web_deps.py, so they are not in this checkout.
// Lying under a provisioned root is what makes the web build stop when one is missing.
test("the fonts, the logo and the fallback image the function fetches are shipped under web/ and pinned", async () => {
  const manifest = JSON.parse(await readFile(new URL("../../tool/web_deps.json", import.meta.url), "utf8"));
  for (const { path } of FONT_FILES) {
    const key = path.slice(1);
    assert.ok(manifest.files[key], `${key} is not pinned in tool/web_deps.json`);
    assert.ok(
      manifest.provisioned_roots.some((root) => key.startsWith(root)),
      `${key} is not under a provisioned root`,
    );
  }
  assert.ok(manifest.first_party.files.includes(LOGO_PATH.slice(1)), `${LOGO_PATH} is not listed as first-party`);
  const fallback = FALLBACK_PATH.slice(1);
  assert.ok(manifest.first_party.files.includes(fallback), `${fallback} is not listed as first-party`);
  const png = await readFile(new URL(`../../web/${fallback}`, import.meta.url));
  assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [1200, 630]);
});

test("the fallback card names what it stands for as 共有レコード", () => {
  const strings = [];
  const walk = (node) => {
    if (typeof node === "string") strings.push(node);
    else if (Array.isArray(node)) node.forEach(walk);
    else if (node?.props) walk(node.props.children);
  };
  walk(buildFallbackCard(pngDataUri(logo)));
  assert.ok(strings.includes("共有レコード"), JSON.stringify(strings));
  assert.equal(strings.includes("公開レコード"), false);
});

// A character the card's font lacks must be drawn from a font the function was given. Otherwise
// @vercel/og asks Google Fonts for it, which sends the record's text off this origin. Needs the
// real fonts, which tool/fetch_web_deps.py places under web/og/fonts/; skipped where they are absent.
const realFontsPresent = await Promise.all(FONT_FILES.map(({ path }) => access(new URL(`.${path}`, web))))
  .then(() => true)
  .catch(() => false);
test(
  "a record with characters M PLUS Rounded 1c lacks is drawn without fetching anything off the origin",
  { skip: !realFontsPresent && "the fonts under web/og/fonts/ are not provisioned" },
  async () => {
    for (const { path } of FONT_FILES) routes[path] = send(await readFile(new URL(`.${path}`, web)), "font/ttf");
    const rare = JSON.parse(record.toString("utf8"));
    rare.trainee.card.name = "[総攬]オルフェーヴル";
    rare.factor_totals.push(
      { gid: 3, name: "滾る想い", star: 2, color: "green" },
      { gid: 4, name: "夢寐に見る銀世界", star: 1, color: "white" },
      { gid: 5, name: "晴・稍重 驀逍悧迸濘", star: 1, color: "white" },
    );
    routes[`/r/${ID}.json`] = send(JSON.stringify(rare), "application/json");

    const response = await get(handler(), `/r/${ID}.png`);

    assert.equal(response.status, 200);
    await response.arrayBuffer();
    assert.deepEqual(externalFetches, []);
  },
);
