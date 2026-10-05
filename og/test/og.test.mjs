// The OGP image function, driven through its handler with real HTTP requests. The upstream (the
// public JSON and the fonts) is a local HTTP server; nothing leaves the machine. Any other fetch —
// @vercel/og looks up glyphs the given fonts lack on Google Fonts — is refused.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { after, before, beforeEach, describe, test } from "node:test";

import { CACHE_NONE, CACHE_NOT_FOUND, CACHE_SUCCESS, FALLBACK_PATH, FONT_FILES, createHandler } from "../src/handler.mjs";

const realFetch = globalThis.fetch;
globalThis.fetch = async (url) => {
  throw new Error(`external fetch refused in tests: ${url}`);
};

const ID = "0123456789";
const record = await readFile(new URL("./fixtures/record.json", import.meta.url));
// A small Latin font stands in for the 4.5 MB Noto Sans JP files under web/og/fonts/; the card's
// Japanese labels render as missing glyphs, which these tests do not look at.
const font = await readFile(new URL("../node_modules/@vercel/og/dist/Geist-Regular.ttf", import.meta.url));

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
  routes = {
    [`/r/${ID}.json`]: send(record, "application/json"),
    "/og/fonts/NotoSansJP-Regular.otf": send(font, "font/otf"),
    "/og/fonts/NotoSansJP-Bold.otf": send(font, "font/otf"),
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
        routes["/og/fonts/NotoSansJP-Regular.otf"] = send("not a font", "font/otf");
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
test("the fonts and the fallback image the function fetches are shipped under web/ and pinned", async () => {
  const manifest = JSON.parse(await readFile(new URL("../../tool/web_deps.json", import.meta.url), "utf8"));
  for (const { path } of FONT_FILES) {
    const key = path.slice(1);
    assert.ok(manifest.files[key], `${key} is not pinned in tool/web_deps.json`);
    assert.ok(
      manifest.provisioned_roots.some((root) => key.startsWith(root)),
      `${key} is not under a provisioned root`,
    );
  }
  const fallback = FALLBACK_PATH.slice(1);
  assert.ok(manifest.first_party.files.includes(fallback), `${fallback} is not listed as first-party`);
  const png = await readFile(new URL(`../../web/${fallback}`, import.meta.url));
  assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [1200, 630]);
});
