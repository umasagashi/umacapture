// An account's public list: /u/<id> (HTML) and /u/<id>.json, answered without a session like
// /r/<id>. It names the account only by its id: no name, no provider, no creation day.

import { RECORD_TYPE_LABELS, esc, num, pageFooter, siteHeader, splitCard } from "./page.mjs";
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

/**
 * The orders the page can list in, by the value of its `sort` query: the share day as the list
 * JSON carries it (newest first), or the evaluation (highest first; an inheritance-only record has
 * none and goes last). Each keeps the list JSON's order among equals.
 */
const SORTS = {
  shared: { label: "共有日", order: (records) => records },
  evaluation: {
    label: "評価点",
    order: (records) => records.toSorted((a, b) => (b.evaluation ?? -1) - (a.evaluation ?? -1)),
  },
};
const DEFAULT_SORT = "shared";

/** The order a `sort` query value names; anything else, a missing one included, is the default. */
export function listSort(value) {
  return Object.hasOwn(SORTS, value) ? value : DEFAULT_SORT;
}

/** The kinds the filter offers, by the id suffix of their radio button. */
const KINDS = [
  ["std", "standard"],
  ["inh", "inheritance_only"],
];

function card(record) {
  const { costume, name } = splitCard(record.trainee.card.name);
  const rank = record.trainee.rank ? `<span class="rec-rank">${esc(record.trainee.rank.name)}</span>` : "";
  const evaluation = record.evaluation === null ? "" : `<span class="rec-eval">${num(record.evaluation)}</span>`;
  return `<li class="list-item" data-type="${esc(record.record_type)}"><a href="${esc(record.url)}">
${costume === null ? "" : `<span class="rec-costume">${esc(costume)}</span>`}<strong>${esc(name)}</strong>
<span class="list-row">${rank}${evaluation}<span class="rec-tag">${RECORD_TYPE_LABELS[record.record_type]}</span><span class="list-day">${esc(record.shared_on)}</span></span>
</a></li>`;
}

/**
 * The filter by kind (radio buttons the stylesheet reads, no request) and the order (links: the
 * Worker sorts, so the order of the markup is the order on screen and in a screen reader).
 */
function controls(list, path, sort) {
  const radio = (id, label, checked) =>
    `<input type="radio" name="list-kind" id="list-k-${id}"${checked ? " checked" : ""}><label for="list-k-${id}">${label}</label>`;
  const kinds = KINDS.map(([id, type]) => {
    const n = list.records.filter((r) => r.record_type === type).length;
    return radio(id, `${RECORD_TYPE_LABELS[type]} <small>${n}</small>`, false);
  });
  const sorts = Object.entries(SORTS).map(([key, { label }]) => {
    if (key === sort) return `<span aria-current="page">${label}</span>`;
    const href = key === DEFAULT_SORT ? path : `${path}?sort=${key}`;
    return `<a href="${esc(href)}">${label}</a>`;
  });
  return `<div class="list-controls">
<fieldset class="list-kinds"><legend>種類</legend>${radio("all", "すべて", true)}${kinds.join("")}</fieldset>
<nav class="list-sorts" aria-label="並び"><span class="rec-k">並び</span>${sorts.join("")}</nav>
</div>`;
}

/**
 * The HTML document for one public list, its records in the order `sort` names (see `listSort`).
 * Its og:image is always the static default picture: the OGP image function draws only /r/<id>.png.
 */
export function renderListPage(list, env, sort) {
  if (!Object.hasOwn(SORTS, sort)) throw new Error(`sort must be one of ${Object.keys(SORTS)}, got ${JSON.stringify(sort)}`);
  const body = list.records.length
    ? `${controls(list, `/u/${list.id}`, sort)}
<ul class="list-items">${SORTS[sort].order(list.records).map(card).join("")}</ul>`
    : '<p class="rec-none">なし</p>';
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
<link rel="stylesheet" href="/site/site.css">
<link rel="icon" type="image/png" href="/favicon.png">
</head>
<body>
${siteHeader("共有レコード一覧")}
<main class="site-main rec list">
<h1>共有レコード <span class="rec-n">${list.count}件</span></h1>
<p class="list-lead">同じ人が共有したレコードの一覧です。名前やアカウントの情報は表示しません。</p>
${body}
${pageFooter(list.url)}
</main>
</body>
</html>
`;
}
