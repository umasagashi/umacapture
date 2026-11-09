// Request handling for the record-sharing Worker.

import { getMe, postTrainer } from "./account.mjs";
import { deleteAccount } from "./account_deletion.mjs";
import { answerApi } from "./api.mjs";
import { loginBegin, loginCallback, loginClaim, loginPage, logout } from "./auth.mjs";
import { buildPublicList, listSort, renderListPage } from "./list.mjs";
import { buildPublicRecord } from "./public_record.mjs";
import { PAGE_CSP, renderNotFoundPage, renderPage } from "./page.mjs";
import { matchRoute, pagePathKind } from "./routes.mjs";
import { runScheduled } from "./scheduled.mjs";
import { readRecord } from "./store.mjs";
import { newPublicId } from "./secrets.mjs";
import { deleteShare, getMyShares, postShares } from "./shares.mjs";
import { answerSync, getBodies, getGeneration, getHeld, getImage, getSettings, putBodies, putImage, putSettings } from "./sync.mjs";
import { getPart, getRoot, putPart, replaceRoot } from "./sync_list.mjs";
import { TableSource, withTables } from "./tables.mjs";

// A shared record's content never changes after sharing, but its sharer can unshare it; five minutes
// bounds how long caches keep serving it after that.
const CACHE = "public, max-age=300";
// A list changes with every share and unshare: an unshared record stays listed for at most a minute.
const LIST_CACHE = "public, max-age=60";

const notFound = () =>
  new Response("Not Found\n", {
    status: 404,
    headers: { "Content-Type": "text/plain; charset=utf-8", "X-Robots-Tag": "noindex" },
  });

const PAGE_KINDS = { r: "共有レコード", u: "共有レコード一覧" };

/** The 404 for `pathname`: the shared look on a public page's path, plain text on any other. */
function notFoundFor(method, pathname) {
  const kind = pagePathKind(method, pathname);
  if (kind === null) return notFound();
  return new Response(renderNotFoundPage(PAGE_KINDS[kind]), {
    status: 404,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": PAGE_CSP,
      "X-Robots-Tag": "noindex",
    },
  });
}

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
  const meta = { id, sharedDay: stored.sharedDay, origin: env.PUBLIC_ORIGIN };
  return withTables(tables, env.DB, (t) => buildPublicRecord(stored.form, meta, t));
}

/**
 * A Worker module (`{fetch, scheduled}`) answering from the name tables in its D1 (one TableSource
 * per isolate), and running the hourly run (scheduled.mjs) on its cron trigger. `newId` draws the
 * candidate public id of each share attempt, and `now` is the clock every expiry and UTC day is read
 * from (milliseconds since the epoch); only tests replace them, to make a candidate collide with a
 * stored id and to move time.
 */
export function createWorker({ newId = newPublicId, now = Date.now } = {}) {
  const tables = new TableSource();
  return {
    async fetch(request, env, ctx) {
      const url = new URL(request.url);
      const route = matchRoute(request.method, url.pathname);
      if (route === null) return notFoundFor(request.method, url.pathname);
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
        case "syncGeneration":
          return answerSync(env, now, (env) => answerApi(() => getGeneration(request, env, now)));
        case "syncGetSettings":
          return answerSync(env, now, (env) => answerApi(() => getSettings(request, env, now)));
        case "syncPutSettings":
          return answerSync(env, now, (env) => answerApi(() => putSettings(request, env, now)));
        case "syncPutBodies":
          return answerSync(env, now, (env) => answerApi(() => putBodies(request, env, now)));
        case "syncGetBodies":
          return answerSync(env, now, (env) => answerApi(() => getBodies(request, env, now)));
        case "syncHeld":
          return answerSync(env, now, (env) => answerApi(() => getHeld(request, env, now)));
        case "syncPutImage":
          return answerSync(env, now, (env) => answerApi(() => putImage(request, env, route.id, now)));
        case "syncGetImage":
          return answerSync(env, now, (env) => answerApi(() => getImage(request, env, route.id, now)));
        case "syncPutPart":
          return answerSync(env, now, (env) => answerApi(() => putPart(request, env, now)));
        case "syncGetPart":
          return answerSync(env, now, (env) => answerApi(() => getPart(request, env, route.id, now)));
        case "syncReplaceRoot":
          return answerSync(env, now, (env) => answerApi(() => replaceRoot(request, env, now)));
        case "syncGetRoot":
          return answerSync(env, now, (env) => answerApi(() => getRoot(request, env, route.id, now)));
        case "listJson":
        case "listPage": {
          const list = await buildPublicList(env, tables, route.id);
          if (list === null) return notFoundFor(request.method, url.pathname);
          // The JSON is one document whatever the query; only the page reads `sort`.
          if (route.name === "listJson") return publicJson(list, LIST_CACHE);
          return publicPage(renderListPage(list, env, listSort(url.searchParams.get("sort"))), LIST_CACHE);
        }
      }
      const record = await publicRecord(env, tables, route.id);
      if (record === null) return notFoundFor(request.method, url.pathname);
      if (route.name === "recordJson") return publicJson(record, CACHE);
      return publicPage(renderPage(record, env, record.view.focus), CACHE);
    },
    async scheduled(controller, env) {
      await runScheduled(env, now);
    },
  };
}
