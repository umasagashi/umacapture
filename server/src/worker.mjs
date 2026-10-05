// Request handling for the record-sharing Worker, independent of where the tables come from.

import { answerApi, deleteRecord, postLookup, postRecord, postTicket, verifyPage } from "./api.mjs";
import { buildPublicRecord } from "./public_record.mjs";
import { renderPage } from "./page.mjs";
import { matchRoute } from "./routes.mjs";
import { readRecord } from "./store.mjs";
import { newPublicId } from "./secrets.mjs";
import { Tables } from "./tables.mjs";

// Published records never change after publishing; five minutes bounds how long a withdrawn one
// stays in caches.
const CACHE = "public, max-age=300";
const PAGE_CSP = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'";

const notFound = () =>
  new Response("Not Found\n", {
    status: 404,
    headers: { "Content-Type": "text/plain; charset=utf-8", "X-Robots-Tag": "noindex" },
  });

async function publicRecord(env, tables, id) {
  const stored = await readRecord(env.DB, id);
  if (stored === null) return null;
  return buildPublicRecord(stored.form, { id, publishedDay: stored.publishedDay, origin: env.PUBLIC_ORIGIN }, tables);
}

/**
 * A Worker module (`{fetch}`) answering from `rawTables`. `newId` draws the candidate public id of
 * each publish attempt; only tests replace it, to make a candidate collide with a stored id.
 */
export function createWorker(rawTables, { newId = newPublicId } = {}) {
  const tables = new Tables(rawTables);
  return {
    async fetch(request, env, ctx) {
      const route = matchRoute(request.method, new URL(request.url).pathname);
      if (route === null) return notFound();
      switch (route.name) {
        case "verifyPage":
          return verifyPage(request, env);
        case "issueTicket":
          return answerApi(() => postTicket(request, env, ctx));
        case "publish":
          return answerApi(() => postRecord(request, env, tables, newId));
        case "lookup":
          return answerApi(() => postLookup(request, env));
        case "withdraw":
          return answerApi(() => deleteRecord(request, env, route.id));
      }
      const record = await publicRecord(env, tables, route.id);
      if (record === null) return notFound();
      if (route.name === "recordJson") {
        return new Response(JSON.stringify(record), {
          headers: {
            "Content-Type": "application/json; charset=utf-8",
            "Access-Control-Allow-Origin": "*",
            "Cross-Origin-Resource-Policy": "cross-origin",
            "Cache-Control": CACHE,
            "X-Robots-Tag": "noindex",
          },
        });
      }
      return new Response(renderPage(record, env), {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Content-Security-Policy": PAGE_CSP,
          "Cache-Control": CACHE,
          "X-Robots-Tag": "noindex",
        },
      });
    },
  };
}
