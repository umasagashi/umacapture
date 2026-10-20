// Request handling for the record-sharing Worker, independent of where the tables come from.

import { getMe, postTrainer } from "./account.mjs";
import { deleteAccount } from "./account_deletion.mjs";
import { answerApi } from "./api.mjs";
import { loginBegin, loginCallback, loginClaim, loginPage, logout } from "./auth.mjs";
import { buildPublicList, renderListPage } from "./list.mjs";
import { buildPublicRecord } from "./public_record.mjs";
import { renderPage } from "./page.mjs";
import { matchRoute } from "./routes.mjs";
import { readRecord } from "./store.mjs";
import { newPublicId } from "./secrets.mjs";
import { deleteShare, getMyShares, postShares } from "./shares.mjs";
import { Tables } from "./tables.mjs";

// Shared records never change after sharing; five minutes bounds how long an unshared one stays
// in caches.
const CACHE = "public, max-age=300";
// A list changes with every share and unshare: an unshared record stays listed for at most a minute.
const LIST_CACHE = "public, max-age=60";
const PAGE_CSP = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'";

const notFound = () =>
  new Response("Not Found\n", {
    status: 404,
    headers: { "Content-Type": "text/plain; charset=utf-8", "X-Robots-Tag": "noindex" },
  });

const publicJson = (body, cache) =>
  new Response(JSON.stringify(body), {
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": "*",
      "Cross-Origin-Resource-Policy": "cross-origin",
      "Cache-Control": cache,
      "X-Robots-Tag": "noindex",
    },
  });

const publicPage = (html, cache) =>
  new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": PAGE_CSP,
      "Cache-Control": cache,
      "X-Robots-Tag": "noindex",
    },
  });

async function publicRecord(env, tables, id) {
  const stored = await readRecord(env.DB, id);
  if (stored === null) return null;
  return buildPublicRecord(stored.form, { id, sharedDay: stored.sharedDay, origin: env.PUBLIC_ORIGIN }, tables);
}

/**
 * A Worker module (`{fetch}`) answering from `rawTables`. `newId` draws the candidate public id of
 * each share attempt, and `now` is the clock every expiry and UTC day is read from (milliseconds
 * since the epoch); only tests replace them, to make a candidate collide with a stored id and to
 * move time.
 */
export function createWorker(rawTables, { newId = newPublicId, now = Date.now } = {}) {
  const tables = new Tables(rawTables);
  return {
    async fetch(request, env, ctx) {
      const route = matchRoute(request.method, new URL(request.url).pathname);
      if (route === null) return notFound();
      switch (route.name) {
        case "share":
          return answerApi(() => postShares(request, env, tables, newId, now));
        case "unshare":
          return answerApi(() => deleteShare(request, env, route.id, now));
        case "myShares":
          return answerApi(() => getMyShares(request, env, tables, now));
        case "loginPage":
          return loginPage(request, env);
        case "loginBegin":
          return loginBegin(request, env, ctx, now);
        case "loginCallback":
          return loginCallback(request, env, route.id, now);
        case "loginClaim":
          return answerApi(() => loginClaim(request, env, ctx, now));
        case "logout":
          return answerApi(() => logout(request, env, now));
        case "me":
          return answerApi(() => getMe(request, env, now));
        case "deleteAccount":
          return answerApi(() => deleteAccount(request, env, now));
        case "meTrainer":
          return answerApi(() => postTrainer(request, env, now));
        case "listJson":
        case "listPage": {
          const list = await buildPublicList(env, tables, route.id);
          if (list === null) return notFound();
          if (route.name === "listJson") return publicJson(list, LIST_CACHE);
          return publicPage(renderListPage(list, env), LIST_CACHE);
        }
      }
      const record = await publicRecord(env, tables, route.id);
      if (record === null) return notFound();
      if (route.name === "recordJson") return publicJson(record, CACHE);
      return publicPage(renderPage(record, env), CACHE);
    },
  };
}
