// The public page /r/<id>: HTML built as a string from public JSON v1. It carries no script and
// loads nothing from another origin; the CSP sent with it says the same. Its look comes from the
// shared stylesheet (web/site/site.css); the viewer's switches (colour, whose factors, the race
// table) are radio buttons and <details>, driven by that stylesheet alone.
//
// Every interpolated value goes through `esc`, table names included: the tables come from the
// module set, not from this repository, and are not trusted to be markup-free.

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function esc(value) {
  return String(value).replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

/**
 * The CSP of every page the Worker builds without a script: /r/<id>, /u/<id> and the login
 * refusals. No script at all; styles, fonts and images from this origin only, which is where the
 * shared look of the public pages lives (web/site/site.css, its fonts and the logo, served from
 * static assets). No inline style either: a page carries no <style> and no style attribute.
 */
export const PAGE_CSP = "default-src 'none'; img-src 'self'; style-src 'self'; font-src 'self'";

/**
 * The site header of a page the Worker builds: the mark and name linking to the app, the name of
 * this kind of page, and the colour switch. web/notice and web/privacy carry the same markup.
 */
export function siteHeader(kind) {
  return `<header class="site-header"><div class="site-header-inner">
<a class="site-brand" href="/"><img src="/site/logo.svg" alt="" width="28" height="28">umacapture</a>
<span class="site-kind">${esc(kind)}</span>
<fieldset class="site-theme"><legend>表示の色</legend>
<input type="radio" name="site-theme" id="site-theme-auto" checked><label for="site-theme-auto">自動</label>
<input type="radio" name="site-theme" id="site-theme-light"><label for="site-theme-light">ライト</label>
<input type="radio" name="site-theme" id="site-theme-dark"><label for="site-theme-dark">ダーク</label>
</fieldset>
</div></header>`;
}

/** The footer of every shared page (/r/<id> and /u/<id>): its own JSON, the notice, the privacy policy, the app. */
export function pageFooter(url) {
  return `<footer class="site-footer">
<a href="${esc(url)}.json">JSON</a> · <a href="/notice/">試験公開について</a> · <a href="/privacy/">プライバシーポリシー</a> · <a href="/">umacapture</a>
</footer>`;
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

/** The two parents: key in `factors` / `family`, label, and the id suffix of their tab. */
const PARENTS = [
  ["parent1", "親1", "p1"],
  ["parent2", "親2", "p2"],
];

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

/** A list of chips; every item is markup already escaped by the caller. */
const chips = (items) => (items.length ? `<ul class="rec-chips">${items.map((i) => `<li>${i}</li>`).join("")}</ul>` : NONE);

function factorChips(factors) {
  return chips(factors.map((f) => `${esc(f.name)} <span class="rec-star">★${esc(f.star)}</span>`));
}

function meta(record) {
  const items = [
    ["シナリオ", esc(record.scenario.name)],
    ["育成日", record.trained_on === null ? null : esc(record.trained_on)],
    ["作戦", esc(record.strategy.name)],
    ["ファン数", readsTraining(record) ? num(record.fans) : null],
    ["重賞ボーナス", record.relation_bonus === null ? null : esc(record.relation_bonus)],
  ].filter(([, value]) => value !== null);
  return `<dl class="rec-meta">${items.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join("")}</dl>`;
}

function stats(record) {
  const cells = STATUS_LABELS.map(
    ([key, label]) => `<div><span class="rec-k">${label}</span><strong>${esc(record.status[key])}</strong></div>`,
  );
  return `<div class="rec-stats">${cells.join("")}</div>`;
}

/** The hero's strip under focus "inheritance": the trainee and both parents, with their factors. */
function lineage(record) {
  const node = (cls, label, name, factors, extra) =>
    `<div class="rec-node${cls}"><span class="rec-k">${label}</span><strong>${esc(name)}</strong>${extra}<span class="rec-k">因子 ${factors.length} ・ ★${starSum(factors)}</span></div>`;
  const nodes = [node(" rec-self", "本人", record.trainee.character.name, record.factors.self, "")];
  for (const [key, label] of PARENTS) {
    const p = record.family[key];
    const rental = p.rental ? '<span class="rec-tag">レンタル</span>' : "";
    const grand = `<span class="rec-gp">${esc(p.parent1.character.name)} ／ ${esc(p.parent2.character.name)}</span>`;
    nodes.push(node("", label, p.self.character.name, record.factors[key], rental + grand));
  }
  return `<div class="rec-lineage">${nodes.join("")}</div>`;
}

function hero(record, focus) {
  const { costume, name } = splitCard(record.trainee.card.name);
  const rank = record.trainee.rank ? `<span class="rec-rank">${esc(record.trainee.rank.name)}</span>` : "";
  const evaluation =
    record.evaluation === null ? "" : `<span class="rec-eval"><small>評価点</small>${num(record.evaluation)}</span>`;
  return `<section class="rec-hero">
${costume === null ? "" : `<p class="rec-costume">${esc(costume)}</p>`}<h1>${esc(name)}</h1>
<div class="rec-badges">${rank}${evaluation}<span class="rec-tag">${RECORD_TYPE_LABELS[record.record_type]}</span></div>
${meta(record)}
${focus === "training" && readsTraining(record) ? stats(record) : lineage(record)}
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
    record.skills.map((s) =>
      s.level === undefined ? esc(s.name) : `${esc(s.name)} <span class="rec-lv">Lv${esc(s.level)}</span>`,
    ),
  );
}

/** Tabs for whose factors are shown: the trainee, then each parent with who that parent is. */
function factorTabs(record) {
  const tab = (id, label, count, checked) =>
    `<input type="radio" name="rec-factor" id="rec-f-${id}"${checked ? " checked" : ""}><label for="rec-f-${id}">${label}<small>${count}</small></label>`;
  const tabs = [tab("self", "本人", record.factors.self.length, true)];
  const panels = [`<div class="rec-panel rec-p-self">${factorChips(record.factors.self)}</div>`];
  for (const [key, label, id] of PARENTS) {
    const p = record.family[key];
    const { costume } = splitCard(p.self.card.name);
    tabs.push(tab(id, `${label} ${esc(p.self.character.name)}`, record.factors[key].length, false));
    const who = [
      `<strong>${esc(p.self.character.name)}</strong>`,
      costume === null ? "" : ` <span class="rec-k">${esc(costume)}</span>`,
      p.rental ? ' <span class="rec-tag">レンタル</span>' : "",
      `<span class="rec-gp">${label}の親: ${esc(p.parent1.character.name)} ／ ${esc(p.parent2.character.name)}</span>`,
    ].join("");
    panels.push(`<div class="rec-panel rec-p-${id}"><p class="rec-who">${who}</p>${factorChips(record.factors[key])}</div>`);
  }
  return `<fieldset class="rec-tabs"><legend>誰の因子か</legend>${tabs.join("")}</fieldset>${panels.join("")}`;
}

function supports(record) {
  if (record.support_cards.length === 0) return NONE;
  const cards = record.support_cards.map((c) => {
    const { costume, name } = splitCard(c.name);
    // A level of 0 is left out rather than shown as "Lv0".
    const level = c.level ? ` ・ Lv${esc(c.level)}` : "";
    const costumeLine = costume === null ? "" : `<span class="rec-k">${esc(costume)}</span>`;
    return `<div class="rec-support">${costumeLine}${esc(name)}<span class="rec-k">${esc(c.limit_break)}凸${level}</span></div>`;
  });
  return `<div class="rec-supports">${cards.join("")}</div>`;
}

/** The races, folded: the summary line carries how many were run and won. */
function races(record) {
  const wins = record.races.filter((r) => r.position.name === "1").length;
  const rows = record.races.map((r) => {
    const where = [r.place.name, r.ground.name, `${r.distance}m`, r.variation.name, r.weather.name, r.strategy.name];
    const win = r.position.name === "1" ? " rec-win" : "";
    return `<tr><td class="rec-k">${esc(r.turn.name)}</td><td>${esc(r.title.name)}<span class="rec-k">${where.map(esc).join(" ")}</span></td><td class="rec-pos${win}">${esc(r.position.name)}着</td></tr>`;
  });
  const table = rows.length ? `<table class="rec-races">${rows.join("")}</table>` : NONE;
  return `<details><summary><h2>レース</h2><span class="rec-n">${record.races.length}戦 ${wins}勝</span></summary>${table}</details>`;
}

function provenance(record) {
  const rows = [
    ["共有日", record.shared_on],
    ["地域", record.region],
    ["認識器の版", record.recognizer_version],
    ["表の版", record.tables_version],
  ];
  return `<dl class="rec-prov">${rows.map(([k, v]) => `<dt>${k}</dt><dd>${esc(v)}</dd>`).join("")}</dl>`;
}

const card = (id, heading, content) => `<section class="rec-card" id="${id}"><h2>${heading}</h2>${content}</section>`;

/**
 * The sections of the page by anchor: [jump label, markup]; a section the record cannot fill is
 * absent. Under focus "training" the stats sit in the hero, so "status" holds the aptitudes alone;
 * under "inheritance" the hero holds the lineage and "status" holds both, unless the record is
 * inheritance-only and has no stats to show.
 */
function sections(record, focus) {
  const withStats = focus === "inheritance" && readsTraining(record);
  const statusHeading = withStats ? "ステータスと適性" : "適性";
  const statusBody = withStats ? stats(record) + aptitudes(record) : aptitudes(record);
  const skillsHeading = `スキル <span class="rec-n">${record.skills.length}</span>`;
  return {
    status: [statusHeading, card("status", statusHeading, statusBody)],
    ...(readsTraining(record) && { skills: ["スキル", card("skills", skillsHeading, skills(record))] }),
    factors: ["因子と継承", card("factors", "因子と継承", factorTabs(record))],
    supports: ["サポート", card("supports", "サポートカード", supports(record))],
    races: ["レース", `<section class="rec-card" id="races">${races(record)}</section>`],
  };
}

/** The order of the sections, and of the jump links to them, for each focus. */
const ORDER = {
  training: ["status", "skills", "factors", "supports", "races"],
  inheritance: ["factors", "status", "skills", "supports", "races"],
};

function body(record, focus) {
  const all = sections(record, focus);
  const order = ORDER[focus].filter((key) => key in all);
  const jump = order.map((key) => `<a href="#${key}">${all[key][0]}</a>`).join("");
  return `${hero(record, focus)}
<nav class="rec-jump" aria-label="区分へ移動">${jump}</nav>
${order.map((key) => all[key][1]).join("\n")}
${provenance(record)}`;
}

/**
 * The full HTML document for one shared record.
 *
 * @param {object} record public JSON v1
 * @param {object} env the Worker's vars (for og:image)
 * @param {"training" | "inheritance"} focus what the page leads with: the hero's strip and the
 *   order of the sections. The caller decides it; `defaultFocus` in public_record.mjs is the rule
 *   for a record that carries no choice.
 */
export function renderPage(record, env, focus) {
  if (!Object.hasOwn(ORDER, focus)) {
    throw new Error(`focus must be "training" or "inheritance", got ${JSON.stringify(focus)}`);
  }
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
${body(record, focus)}
${pageFooter(record.url)}
</main>
</body>
</html>
`;
}
