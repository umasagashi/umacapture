// The OGP image function: GET /r/<public id>.png draws the record's card from public JSON v1.
//
// Cheap checks run first and the upstream fetch and the render last, so a request that cannot name
// a public record never reaches the sharing Worker and never renders:
//   1. GET or HEAD, else 405.
//   2. The path is /r/<id>.png with no query string, else 404 without fetching anything. A query
//      string is refused because the CDN keys a function response on the full URL, so `?a=1`,
//      `?a=2`… would each render again.
//   3. Fetch <origin>/r/<id>.json. Upstream 404 is 404; any other failure is a temporary one.
//   4. Check the JSON's shape.
//   5. Load the fonts and the logo.
//   6. Render, awaiting the whole PNG before answering.
// A temporary failure answers 302 to the static fallback image with `no-store`, so the CDN does
// not keep it; a 404 is cached, because public ids are random and never requested before they
// exist.

import { ImageResponse } from "@vercel/og";

import { FONT_FAMILY, buildCard, isRenderable, svgDataUri } from "./card.mjs";

// Public ids: 10 lowercase Crockford base32 characters (no i, l, o, u), as the sharing Worker
// issues them.
const IMAGE_PATH = /^\/r\/([0-9a-hjkmnp-tv-z]{10})\.png$/;

export const CACHE_SUCCESS = "public, max-age=3600, s-maxage=3600";
export const CACHE_NOT_FOUND = "public, s-maxage=86400";
export const CACHE_NONE = "no-store";

export const FALLBACK_PATH = "/og/default.png";
// The card is set in M PLUS Rounded 1c, the app's font. It lacks a few characters the tables use
// (稍 in 稍重, 攬 in [総攬]…), so Noto Sans JP is loaded after it: satori draws a character the first
// font lacks from the next one. Without it, @vercel/og would ask Google Fonts for the character,
// sending record text off the origin.
export const FONT_FILES = [
  { path: "/og/fonts/MPLUSRounded1c-Regular.ttf", name: FONT_FAMILY, weight: 400 },
  { path: "/og/fonts/MPLUSRounded1c-Bold.ttf", name: FONT_FAMILY, weight: 700 },
  { path: "/og/fonts/NotoSansJP-Regular.otf", name: "Noto Sans JP", weight: 400 },
];
// The mark the public pages show, read from the same origin so it has one definition.
export const LOGO_PATH = "/site/logo.svg";

/**
 * Limits on the two fetches. Each covers the response headers and the whole body.
 * PROVISIONAL: the timeouts are to be set from the cold fetch times measured on the preview
 * deployment, and must stay well under the function's `maxDuration` in vercel.json.
 */
export const DEFAULT_LIMITS = {
  upstreamTimeoutMs: 3_000,
  upstreamMaxBytes: 64 * 1024,
  assetTimeoutMs: 10_000,
  assetMaxBytes: 16 * 1024 * 1024,
};

class TemporaryFailure extends Error {}

const empty = (status, cacheControl, extra = {}) =>
  new Response(null, { status, headers: { "cache-control": cacheControl, ...extra } });

/** Reads `response`'s body up to `maxBytes`; more than that is a temporary failure. */
async function readCapped(response, maxBytes) {
  const declared = Number(response.headers.get("content-length"));
  if (declared > maxBytes) throw new TemporaryFailure(`body of ${declared} bytes`);
  const chunks = [];
  let total = 0;
  for await (const chunk of response.body ?? []) {
    total += chunk.byteLength;
    if (total > maxBytes) throw new TemporaryFailure(`body over ${maxBytes} bytes`);
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, total);
}

/**
 * Fetches `url` and reads its body within `timeoutMs`. Resolves to null for a 404; throws
 * TemporaryFailure for every other non-200 answer, a redirect, a timeout or an oversized body.
 */
async function fetchBytes(fetchImpl, url, timeoutMs, maxBytes) {
  const signal = AbortSignal.timeout(timeoutMs);
  try {
    // no-store: the function never answers from a stored copy of the public JSON, so a withdrawn
    // record is seen as soon as the upstream says so.
    const response = await fetchImpl(url, { redirect: "manual", cache: "no-store", signal });
    if (response.status === 404) {
      await response.body?.cancel();
      return null;
    }
    if (response.status !== 200) {
      await response.body?.cancel();
      throw new TemporaryFailure(`${url} answered ${response.status}`);
    }
    return await readCapped(response, maxBytes);
  } catch (error) {
    if (error instanceof TemporaryFailure) throw error;
    throw new TemporaryFailure(`${url}: ${error?.message ?? error}`);
  }
}

/**
 * @param {{origin: string, fetch?: typeof fetch, limits?: Partial<typeof DEFAULT_LIMITS>,
 *          log?: (message: string) => void}} options
 *   `origin` is where the public JSON, the fonts and the logo come from (PUBLIC_ORIGIN).
 * @returns {(request: Request) => Promise<Response>}
 */
export function createHandler({ origin, fetch: fetchImpl = globalThis.fetch, limits = {}, log = console.warn }) {
  const base = new URL(origin).origin;
  const { upstreamTimeoutMs, upstreamMaxBytes, assetTimeoutMs, assetMaxBytes } = { ...DEFAULT_LIMITS, ...limits };
  const fallback = () =>
    empty(302, CACHE_NONE, { location: `${base}${FALLBACK_PATH}` });

  const fetchAsset = async (path) => {
    const data = await fetchBytes(fetchImpl, `${base}${path}`, assetTimeoutMs, assetMaxBytes);
    if (data === null) throw new TemporaryFailure(`${path} is missing`);
    return data;
  };
  // Kept for the life of the instance once a render with them succeeded; dropped after a failed
  // one, so bytes that fail to parse are fetched again rather than kept.
  let assets = null;
  const loadAssets = () =>
    (assets ??= Promise.all([
      Promise.all(
        FONT_FILES.map(async ({ path, name, weight }) => ({ name, data: await fetchAsset(path), weight, style: "normal" })),
      ),
      fetchAsset(LOGO_PATH).then(svgDataUri),
    ]).catch((error) => {
      assets = null;
      throw error;
    }));

  return async function handle(request) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return empty(405, CACHE_NONE, { allow: "GET, HEAD" });
    }
    const url = new URL(request.url);
    const match = IMAGE_PATH.exec(url.pathname);
    // `request.url.includes("?")` and not `url.search`: a bare trailing "?" has an empty search
    // but is still a different URL to the CDN.
    if (!match || request.url.includes("?")) return empty(404, CACHE_NOT_FOUND);
    const id = match[1];

    try {
      const body = await fetchBytes(fetchImpl, `${base}/r/${id}.json`, upstreamTimeoutMs, upstreamMaxBytes);
      if (body === null) return empty(404, CACHE_NOT_FOUND);
      let record;
      try {
        record = JSON.parse(body.toString("utf8"));
      } catch {
        throw new TemporaryFailure("the public JSON does not parse");
      }
      if (!isRenderable(record)) throw new TemporaryFailure("the public JSON has an unexpected shape");

      const png = await render(record, await loadAssets()).catch((error) => {
        assets = null;
        throw new TemporaryFailure(`render: ${error?.message ?? error}`);
      });
      return new Response(request.method === "HEAD" ? null : png, {
        status: 200,
        headers: { "content-type": "image/png", "cache-control": CACHE_SUCCESS },
      });
    } catch (error) {
      if (!(error instanceof TemporaryFailure)) throw error;
      log(`og: ${id}: ${error.message}`);
      return fallback();
    }
  };
}

/**
 * Draws the card and waits for the whole PNG. ImageResponse renders inside its body stream, so its
 * constructor returning says nothing; a failed render only shows when the body is read.
 */
async function render(record, [fonts, logo]) {
  const response = new ImageResponse(buildCard(record, logo), { width: 1200, height: 630, fonts });
  return new Uint8Array(await response.arrayBuffer());
}
