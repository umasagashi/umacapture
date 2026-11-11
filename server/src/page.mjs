// The public page /r/<id>: HTML built as a string from public JSON v1. It loads nothing from another
// origin, and its one script is the inline COPY_SCRIPT, the only script its CSP (sharedPageCspOnce) lets run. Its
// look comes from the shared stylesheet (web/site/site.css); the viewer's switches (colour, each
// slot's factors or their totals, the folded sections) are radio buttons and <details>, driven by that
// stylesheet alone.
//
// Every interpolated value goes through `esc`, table names included: the tables come from the
// module set, not from this repository, and are not trusted to be markup-free. The sharer's own text
// (the tagline and the public profile) goes through it too, and is never made a link.

import { groupedGameTrainerId } from "./user_text.mjs";

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function esc(value) {
  return String(value).replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

/**
 * The CSP of every page the Worker builds without a script: the 404 of a public page's path, the
 * login refusals and the report pages. No script at all; styles, fonts and images from this origin
 * only, which is where the shared look of the public pages lives (web/site/site.css, its fonts and
 * the logo, served from static assets). No inline style either: a page carries no <style> and no
 * style attribute.
 */
export const PAGE_CSP = "default-src 'none'; img-src 'self'; style-src 'self'; font-src 'self'";

/**
 * The one script of a shared page (/r/<id>, /u/<id>): it shows each trainer id's copy button, which
 * the page sends hidden, and copies the button's digits to the clipboard. Without script, or without
 * the clipboard API, the buttons stay hidden and the page reads the same. A refused write (the site's
 * clipboard permission denied) leaves the button disabled and saying so, since a retry would be
 * refused the same way. Firefox and Safari cannot be asked about the permission beforehand, so the
 * refusal is learned from the write itself on every browser.
 */
export const COPY_SCRIPT = `for (const b of document.querySelectorAll("button[data-copy]")) {
  if (!navigator.clipboard) break;
  const label = b.textContent;
  b.hidden = false;
  b.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(b.dataset.copy);
    } catch {
      b.textContent = "コピーできませんでした";
      b.disabled = true;
      return;
    }
    b.textContent = "コピーしました";
    setTimeout(() => (b.textContent = label), 2000);
  });
}`;

let sharedPageCsp = null;

/**
 * The CSP of a shared page (/r/<id>, /u/<id>): PAGE_CSP, plus COPY_SCRIPT by its
 * hash and no other script. A hash, not a per-response nonce, because the page is cached, and a
 * cached nonce is the same for every viewer.
 */
export function sharedPageCspOnce() {
  sharedPageCsp ??= crypto.subtle.digest("SHA-256", new TextEncoder().encode(COPY_SCRIPT)).then((hash) => {
    const b64 = btoa(String.fromCharCode(...new Uint8Array(hash)));
    return `${PAGE_CSP}; script-src 'sha256-${b64}'`;
  });
  return sharedPageCsp;
}

/**
 * The inline script element of a shared page whose sharer line is `sharer`: COPY_SCRIPT, exactly the
 * text the CSP hashes, when that line carries a copy button, and "" when it carries none.
 */
export const copyScriptElement = (sharer) => (sharer?.game_trainer_id == null ? "" : `<script>${COPY_SCRIPT}</script>`);

/**
 * The site header of a page the Worker builds: the mark and name linking to the app, the name of
 * this kind of page, and the colour switch. web/notice and web/privacy carry the same markup.
 */
export function siteHeader(kind) {
  return `<header class="site-header"><div class="site-header-inner">
<a class="site-brand" href="/"><img src="/site/logo.png" alt="" width="28" height="28">umacapture</a>
<span class="site-kind">${esc(kind)}</span>
<fieldset class="site-theme"><legend>表示の色</legend>
<input type="radio" name="site-theme" id="site-theme-auto" checked><label for="site-theme-auto">自動</label>
<input type="radio" name="site-theme" id="site-theme-light"><label for="site-theme-light">ライト</label>
<input type="radio" name="site-theme" id="site-theme-dark"><label for="site-theme-dark">ダーク</label>
</fieldset>
</div></header>`;
}

/**
 * The footer of every shared page (/r/<id> and /u/<id>): its own JSON, the notice and the privacy
 * policy, then at the right end the link to that page's report page (<url>/report).
 */
export function pageFooter(url) {
  return `<footer class="site-footer">
<span class="site-footer-links"><a href="${esc(url)}.json">JSON</a> · <a href="/notice/">試験公開について</a> · <a href="/privacy/">プライバシーポリシー</a></span>
<a class="site-footer-report" href="${esc(url)}/report" rel="nofollow">問題を報告</a>
</footer>`;
}

/**
 * The page a viewer gets for /r/<id> or /u/<id> when there is nothing to show: the id never
 * existed, was unshared, or is not an id at all. One page for all three, so the answer does not
 * tell which ids once existed. `kind` is the site header's name of the page asked for.
 */
export function renderNotFoundPage(kind) {
  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>見つかりませんでした | umacapture</title>
<link rel="stylesheet" href="/site/site.css">
<link rel="icon" type="image/png" href="/favicon.png">
</head>
<body>
${siteHeader(kind)}
<main class="site-doc">
<h1>見つかりませんでした</h1>
<p>この共有は見つかりませんでした。取り消されたか、URL が違う可能性があります。</p>
<p><a href="/">umacapture のトップへ</a></p>
</main>
</body>
</html>
`;
}

/** The og:image / twitter:card set for one page, chosen by `vars.OG_IMAGE_MODE`. */
export function ogImage(env, id) {
  switch (env.OG_IMAGE_MODE) {
    case "vercel":
      return {
        url: `${env.OG_IMAGE_ORIGIN}/r/${id}.png`,
        width: 1200,
        height: 630,
        card: "summary_large_image",
      };
    case "static":
      // A generic picture is shown as the small square card; X advises against stretching a
      // generic image across the large one.
      return { url: `${env.PUBLIC_ORIGIN}/og/default.png`, card: "summary" };
    default:
      throw new Error(`OG_IMAGE_MODE must be "vercel" or "static", got ${JSON.stringify(env.OG_IMAGE_MODE)}`);
  }
}

const STATUS_LABELS = [
  ["speed", "スピード"],
  ["stamina", "スタミナ"],
  ["power", "パワー"],
  ["guts", "根性"],
  ["intelligence", "賢さ"],
];

const APTITUDE_LABELS = [
  ["ground", "バ場", [["turf", "芝"], ["dirt", "ダート"]]],
  ["distance", "距離", [["short", "短距離"], ["mile", "マイル"], ["middle", "中距離"], ["long", "長距離"]]],
  ["style", "脚質", [["lead_pace", "逃げ"], ["with_pace", "先行"], ["off_pace", "差し"], ["late_charge", "追込"]]],
];

/** How a record's kind is named on every page: /r/<id> and the cards of /u/<id>. */
export const RECORD_TYPE_LABELS = { standard: "育成", inheritance_only: "継承用" };

/** The two parents: key in `factors` / `family`, and label. */
const PARENTS = [
  ["parent1", "親1"],
  ["parent2", "親2"],
];

/** The heading of each factor colour public JSON v1 writes in `color`. */
const FACTOR_COLOR_LABELS = { blue: "青因子", red: "赤因子", green: "緑因子", white: "白因子" };

function title(record) {
  const parts = [record.trainee.card.name];
  if (record.trainee.rank) parts.push(record.trainee.rank.name);
  if (record.evaluation !== null) parts.push(String(record.evaluation));
  return `${parts.join(" ")} | umacapture`;
}

/**
 * The page's description: the stats and the trainee's factors for a training, the lineage for an
 * inheritance-only record (whose stats were never read).
 */
function description(record) {
  if (!readsTraining(record)) {
    const self = record.factors.self;
    const parents = PARENTS.map(([key, label]) => `${label} ${record.family[key].self.character.name}`).join(" / ");
    return `因子 ${self.length} ・ ★${starSum(self)} | ${parents}`;
  }
  const status = STATUS_LABELS.map(([key, label]) => `${label} ${record.status[key]}`).join(" / ");
  const factors = record.factors.self.map((f) => `${f.name}★${f.star}`).join(" ");
  return factors ? `${status} | ${factors}` : status;
}

/**
 * A card name of the form "[costume]name" split into its two parts; any other form is all name.
 * The tables carry card names whole, so this reads the shape of the string.
 */
export function splitCard(name) {
  const m = /^\[([^\]]+)\](.+)$/.exec(name);
  return m ? { costume: m[1], name: m[2] } : { costume: null, name };
}

/**
 * Whether the record carries what a training reads: stats, fans and skills. An inheritance-only
 * record carries 0 and an empty list for them, which the game never read, so the page leaves them out.
 */
const readsTraining = (record) => record.record_type !== "inheritance_only";

export const num = (n) => esc(Number(n).toLocaleString("en-US"));
const starSum = (factors) => factors.reduce((sum, f) => sum + f.star, 0);
const NONE = '<p class="rec-none">なし</p>';

/**
 * A list of chips. Every item is [markup already escaped by the caller, class or null]; the class
 * marks a factor chip with its colour.
 */
const chips = (items) =>
  items.length
    ? `<ul class="rec-chips">${items.map(([markup, cls]) => `<li${cls ? ` class="${cls}"` : ""}>${markup}</li>`).join("")}</ul>`
    : NONE;

/** Factor chips, each marked with its colour; `star` is a slot's stars or a total's. */
function factorChips(factors) {
  return chips(
    factors.map((f) => [`${esc(f.name)} <span class="rec-star">★${esc(f.star)}</span>`, `rec-c-${esc(f.color)}`]),
  );
}

function stats(record) {
  const cells = STATUS_LABELS.map(
    ([key, label]) => `<div><span class="rec-k">${label}</span><strong>${esc(record.status[key])}</strong></div>`,
  );
  return `<div class="rec-stats">${cells.join("")}</div>`;
}

/**
 * The line naming the sharer of a page from public JSON's `sharer` (`publicSharer` in user_text.mjs),
 * with `cls` its class, or "" when the sharer wrote no profile. The trainer id is shown grouped by
 * three, as the game shows it, followed by a button that copies its bare digits, which is what the
 * game takes when pasted; COPY_SCRIPT shows the button. The name is self-declared and is shown as
 * written, never as verified.
 */
export function sharerLine(sharer, cls) {
  if (sharer === null) return "";
  const digits = sharer.game_trainer_id;
  const id = digits === null ? null : `ID ${esc(groupedGameTrainerId(digits))}`;
  const named = sharer.trainer_name === null ? id : id === null ? esc(sharer.trainer_name) : `${esc(sharer.trainer_name)}（${id}）`;
  const copy =
    digits === null ? "" : ` <button type="button" class="sharer-copy" data-copy="${esc(digits)}" hidden>ID をコピー</button>`;
  return `<p class="${cls}"><span class="rec-k">トレーナー</span> ${named}${copy}</p>`;
}

/** The share's tagline as a paragraph of class `cls`, or "" when none is written. Never a link. */
export const taglineText = (tagline, cls, tag = "p") => (tagline === null ? "" : `<${tag} class="${cls}">${esc(tagline)}</${tag}>`);

function hero(record) {
  const { costume, name } = splitCard(record.trainee.card.name);
  const rank = record.trainee.rank ? `<span class="rec-rank">${esc(record.trainee.rank.name)}</span>` : "";
  const evaluation =
    record.evaluation === null ? "" : `<span class="rec-eval"><small>評価点</small>${num(record.evaluation)}</span>`;
  return `<section class="rec-hero">
${costume === null ? "" : `<p class="rec-costume">${esc(costume)}</p>`}<h1>${esc(name)}</h1>
<div class="rec-badges">${rank}${evaluation}<span class="rec-tag">${RECORD_TYPE_LABELS[record.record_type]}</span></div>
${sharerLine(record.sharer, "rec-sharer")}${taglineText(record.tagline, "rec-tagline")}
</section>`;
}

function aptitudes(record) {
  const rows = APTITUDE_LABELS.map(([group, label, keys]) => {
    const cells = keys.map(([key, keyLabel]) => {
      const grade = record.aptitudes[group][key].name;
      // The grade is a table name; it picks a colour class only when it is one of the known letters.
      const cls = /^[SA-G]$/.test(grade) ? ` rec-g${grade}` : "";
      return `<span class="rec-apt">${keyLabel}<span class="rec-grade${cls}">${esc(grade)}</span></span>`;
    });
    return `<span class="rec-k">${label}</span><span class="rec-cells">${cells.join("")}</span>`;
  });
  return `<div class="rec-apts">${rows.join("")}</div>`;
}

function skills(record) {
  return chips(
    record.skills.map((s) => [
      s.level === undefined ? esc(s.name) : `${esc(s.name)} <span class="rec-lv">Lv${esc(s.level)}</span>`,
      null,
    ]),
  );
}

/** One slot's factors under "each": who the slot is, then its factors in the record's order. */
function slot(heading, under, factors) {
  const count = `<span class="rec-n">因子 ${factors.length} ・ ★${starSum(factors)}</span>`;
  return `<div class="rec-slot"><h3>${heading}${count}</h3>${under}${factorChips(factors)}</div>`;
}

/** The trainee's factors, then each parent's under who that parent is, one under the other. */
function eachSlot(record) {
  const slots = [slot("<span>本人</span>", "", record.factors.self)];
  for (const [key, label] of PARENTS) {
    const p = record.family[key];
    const { costume } = splitCard(p.self.card.name);
    const heading = [
      `<span>${label}</span><strong>${esc(p.self.character.name)}</strong>`,
      costume === null ? "" : `<span class="rec-k">${esc(costume)}</span>`,
      p.rental ? '<span class="rec-tag">レンタル</span>' : "",
    ].join("");
    const grand = `<p class="rec-gp">${label}の親: ${esc(p.parent1.character.name)} ／ ${esc(p.parent2.character.name)}</p>`;
    slots.push(slot(heading, grand, record.factors[key]));
  }
  return slots.join("");
}

/**
 * The factor totals in the order public JSON lists them, under a heading for each run of one
 * colour. The order, colours first, is factor_totals' own; the page does not sort it.
 */
function totals(record) {
  const runs = [];
  for (const f of record.factor_totals) {
    const last = runs.at(-1);
    if (last && last.color === f.color) last.factors.push(f);
    else runs.push({ color: f.color, factors: [f] });
  }
  if (runs.length === 0) return NONE;
  return runs
    .map((r) => {
      const heading = `<span>${FACTOR_COLOR_LABELS[r.color]}</span><span class="rec-n">${r.factors.length}種</span>`;
      return `<div class="rec-slot"><h3>${heading}</h3>${factorChips(r.factors)}</div>`;
    })
    .join("");
}

/** The factors, each slot (checked by default) or the totals, switched by a radio button. */
function factorViews() {
  const tab = (id, label, checked) =>
    `<input type="radio" name="rec-factor" id="rec-f-${id}"${checked ? " checked" : ""}><label for="rec-f-${id}">${label}</label>`;
  return `<fieldset class="rec-tabs"><legend>因子の表示</legend>${tab("each", "個別", true)}${tab("total", "合計", false)}</fieldset>`;
}

function factorsBody(record) {
  return `${factorViews()}<div class="rec-p-each">${eachSlot(record)}</div><div class="rec-p-total">${totals(record)}</div>`;
}

/** The support cards, without their limit breaks: the recognizer misreads those. */
function supports(record) {
  if (record.support_cards.length === 0) return NONE;
  const cards = record.support_cards.map((c) => {
    const { costume, name } = splitCard(c.name);
    // A level of 0 is left out rather than shown as "Lv0".
    const level = c.level ? `<span class="rec-k">Lv${esc(c.level)}</span>` : "";
    const costumeLine = costume === null ? "" : `<span class="rec-k">${esc(costume)}</span>`;
    return `<div class="rec-support">${costumeLine}${esc(name)}${level}</div>`;
  });
  return `<div class="rec-supports">${cards.join("")}</div>`;
}

function raceTable(record) {
  const rows = record.races.map((r) => {
    const where = [r.place.name, r.ground.name, `${r.distance}m`, r.variation.name, r.weather.name, r.strategy.name];
    const win = r.position.name === "1" ? " rec-win" : "";
    return `<tr><td class="rec-k">${esc(r.turn.name)}</td><td>${esc(r.title.name)}<span class="rec-k">${where.map(esc).join(" ")}</span></td><td class="rec-pos${win}">${esc(r.position.name)}着</td></tr>`;
  });
  return rows.length ? `<table class="rec-races">${rows.join("")}</table>` : NONE;
}

/** What the record is beyond the trainee: the training's facts, then the share's own. */
function info(record) {
  const rows = [
    ["シナリオ", esc(record.scenario.name)],
    ["育成日", record.trained_on === null ? null : esc(record.trained_on)],
    ["作戦", esc(record.strategy.name)],
    ["ファン数", readsTraining(record) ? num(record.fans) : null],
    ["重賞ボーナス", record.relation_bonus === null ? null : esc(record.relation_bonus)],
    ["共有日", esc(record.shared_on)],
    ["地域", esc(record.region)],
    ["認識器の版", esc(record.recognizer_version)],
    ["表の版", esc(record.tables_version)],
  ].filter(([, value]) => value !== null);
  return `<dl class="rec-info">${rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("")}</dl>`;
}

const card = (id, heading, content) => `<section class="rec-card" id="${id}"><h2>${heading}</h2>${content}</section>`;

/** A section folded by default; the summary line carries the heading and a short count. */
const folded = (id, heading, count, content) =>
  `<section class="rec-card" id="${id}"><details><summary><h2>${heading}</h2>${count}</summary>${content}</details></section>`;

/**
 * The sections of the page in order, each [anchor, jump label, markup]. The first ones are always
 * open, the last three folded; a section the record cannot fill is absent.
 */
function sections(record) {
  const wins = record.races.filter((r) => r.position.name === "1").length;
  const n = (text) => `<span class="rec-n">${text}</span>`;
  return [
    ["aptitudes", "適性", card("aptitudes", "適性", aptitudes(record))],
    ["factors", "因子", card("factors", "因子", factorsBody(record))],
    ...(readsTraining(record)
      ? [
          ["status", "ステータス", card("status", "ステータス", stats(record))],
          ["skills", "スキル", card("skills", `スキル ${n(record.skills.length)}`, skills(record))],
        ]
      : []),
    ["supports", "サポート", folded("supports", "サポートカード", n(record.support_cards.length), supports(record))],
    ["races", "レース", folded("races", "レース", n(`${record.races.length}戦 ${wins}勝`), raceTable(record))],
    ["info", "記録の情報", folded("info", "記録の情報", "", info(record))],
  ];
}

function body(record) {
  const all = sections(record);
  const jump = all.map(([id, label]) => `<a href="#${id}">${label}</a>`).join("");
  return `${hero(record)}
<nav class="rec-jump" aria-label="区分へ移動">${jump}</nav>
${all.map(([, , markup]) => markup).join("\n")}`;
}

/**
 * The full HTML document for one shared record. Every record is laid out the same way: the trainee,
 * aptitudes, factors, stats and skills open, then the support cards, races and the record's
 * information folded.
 *
 * @param {object} record public JSON v1
 * @param {object} env the Worker's vars (for og:image)
 */
export function renderPage(record, env) {
  const og = ogImage(env, record.id);
  const t = title(record);
  const d = description(record);
  const size = og.width ? `
<meta property="og:image:width" content="${og.width}">
<meta property="og:image:height" content="${og.height}">` : "";
  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(t)}</title>
<meta name="description" content="${esc(d)}">
<meta name="robots" content="noindex">
<meta property="og:type" content="website">
<meta property="og:site_name" content="umacapture">
<meta property="og:title" content="${esc(t)}">
<meta property="og:description" content="${esc(d)}">
<meta property="og:url" content="${esc(record.url)}">
<meta property="og:image" content="${esc(og.url)}">${size}
<meta property="og:locale" content="ja_JP">
<meta name="twitter:card" content="${og.card}">
<meta name="twitter:image:alt" content="${esc(t)}">
<link rel="stylesheet" href="/site/site.css">
<link rel="icon" type="image/png" href="/favicon.png">
</head>
<body>
${siteHeader("共有レコード")}
<main class="site-main rec">
${body(record)}
${pageFooter(record.url)}
</main>
${copyScriptElement(record.sharer)}
</body>
</html>
`;
}
