// Draws web/og/default.png, the static fallback image for the OGP card, from buildFallbackCard with
// the fonts pinned under web/og/fonts/. The PNG is committed; rerun this after changing the card:
//
//     cd og && npm ci && npm run render:default

import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { ImageResponse } from "@vercel/og";

import { buildFallbackCard } from "../src/card.mjs";
import { FONT_FILES } from "../src/handler.mjs";

const web = new URL("../../web/", import.meta.url);

const fonts = await Promise.all(
  FONT_FILES.map(async ({ path, weight }) => ({
    name: "Noto Sans JP",
    data: await readFile(new URL(`.${path}`, web)),
    weight,
    style: "normal",
  })),
);
// Every glyph is in the pinned fonts; refuse to let @vercel/og fetch a substitute from the network.
globalThis.fetch = async (url) => {
  throw new Error(`unexpected fetch: ${url}`);
};
const response = new ImageResponse(buildFallbackCard(), { width: 1200, height: 630, fonts });
const out = new URL("./og/default.png", web);
await writeFile(out, new Uint8Array(await response.arrayBuffer()));
console.log(`wrote ${fileURLToPath(out)}`);
