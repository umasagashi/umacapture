// An account's public list: /u/<id> (HTML) and /u/<id>.json, answered without a session like
// /r/<id>. It names the account only by its id: no name, no provider, no creation day.

import { esc } from "./page.mjs";
import { dayToIso, recordSummary } from "./public_record.mjs";
import { accountExists, listOwnShares } from "./store.mjs";

const SCHEMA = 1;

/**
 * Public list JSON v1 of account `id`, `{schema, id, url, count, records}` with the records newest
 * share day first, or null when no such account exists. An account sharing nothing has an empty list.
 */
export async function buildPublicList(env, tables, id) {
  if (!(await accountExists(env.DB, id))) return null;
  const shares = await listOwnShares(env.DB, id);
  return {
    schema: SCHEMA,
    id,
    url: `${env.PUBLIC_ORIGIN}/u/${id}`,
    count: shares.length,
    records: shares.map((share) => ({
      id: share.id,
      url: `${env.PUBLIC_ORIGIN}/r/${share.id}`,
      shared_on: dayToIso(share.sharedDay),
      ...recordSummary(share.form, tables),
    })),
  };
}

const TITLE = "共有レコード一覧 | umacapture";

function item(record) {
  const parts = [record.trainee.card.name];
  if (record.trainee.rank) parts.push(record.trainee.rank.name);
  if (record.evaluation !== null) parts.push(String(record.evaluation));
  return `<li><a href="${esc(record.url)}">${esc(parts.join(" "))}</a> ${esc(record.shared_on)}</li>`;
}

/**
 * The HTML document for one public list. Its og:image is always the static default picture: the
 * OGP image function draws only /r/<id>.png.
 */
export function renderListPage(list, env) {
  const items = list.records.length ? `<ul>${list.records.map(item).join("")}</ul>` : "<p>-</p>";
  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(TITLE)}</title>
<meta name="robots" content="noindex">
<meta property="og:type" content="website">
<meta property="og:site_name" content="umacapture">
<meta property="og:title" content="${esc(TITLE)}">
<meta property="og:url" content="${esc(list.url)}">
<meta property="og:image" content="${esc(`${env.PUBLIC_ORIGIN}/og/default.png`)}">
<meta property="og:locale" content="ja_JP">
<meta name="twitter:card" content="summary">
<style>
body { font-family: sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
footer { margin-top: 3rem; font-size: 0.9em; }
</style>
<link rel="icon" type="image/png" href="/favicon.png">
</head>
<body>
<h1>共有レコード一覧</h1>
${items}
<footer>
<a href="${esc(list.url)}.json">JSON</a> · <a href="/notice/">お知らせ</a> · <a href="/">umacapture</a>
</footer>
</body>
</html>
`;
}
