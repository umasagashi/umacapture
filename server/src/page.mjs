// The public page /r/<id>: HTML built as a string from public JSON v1. It carries no script and
// loads nothing from another origin; the CSP sent with it says the same.
//
// Every interpolated value goes through `esc`, table names included: the tables come from the
// module set, not from this repository, and are not trusted to be markup-free.

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function esc(value) {
  return String(value).replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

/** The footer of every shared page (/r/<id> and /u/<id>): its own JSON, the notice, the privacy policy, the app. */
export function pageFooter(url) {
  return `<footer>
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

const RECORD_TYPE_LABELS = { standard: "育成", inheritance_only: "継承" };

function title(record) {
  const parts = [record.trainee.card.name];
  if (record.trainee.rank) parts.push(record.trainee.rank.name);
  if (record.evaluation !== null) parts.push(String(record.evaluation));
  return `${parts.join(" ")} | umacapture`;
}

function description(record) {
  const status = STATUS_LABELS.map(([key, label]) => `${label} ${record.status[key]}`).join(" / ");
  const factors = record.factors.self.map((f) => `${f.name}★${f.star}`).join(" ");
  return factors ? `${status} | ${factors}` : status;
}

const row = (label, value) => `<tr><th>${esc(label)}</th><td>${esc(value)}</td></tr>`;
const list = (items) => (items.length ? `<ul>${items.map((i) => `<li>${esc(i)}</li>`).join("")}</ul>` : "<p>-</p>");

const chara = (c) => `${c.card.name}（${c.character.name}）`;

function family(parent) {
  const self = parent.rental ? `${chara(parent.self)} レンタル` : chara(parent.self);
  return list([self, `祖 1: ${chara(parent.parent1)}`, `祖 2: ${chara(parent.parent2)}`]);
}

function race(r) {
  const where = `${r.place.name} ${r.ground.name} ${r.distance}m ${r.variation.name} ${r.weather.name}`;
  return `${r.turn.name} ${r.title.name}（${where}）${r.strategy.name} ${r.position.name}着`;
}

function body(record) {
  const status = STATUS_LABELS.map(([key, label]) => row(label, record.status[key])).join("");
  const aptitudes = APTITUDE_LABELS.map(([group, label, keys]) =>
    row(label, keys.map(([key, name]) => `${name} ${record.aptitudes[group][key].name}`).join(" / ")),
  ).join("");
  const skills = record.skills.map((s) => (s.level === undefined ? s.name : `${s.name} Lv${s.level}`));
  const factorsOf = (fs) => fs.map((f) => `${f.name} ★${f.star}`);
  const supports = record.support_cards.map((c) => `${c.name} ${c.limit_break}凸 Lv${c.level}`);
  const summary = [
    row("ウマ娘", record.trainee.character.name),
    row("ランク", record.trainee.rank?.name ?? "-"),
    row("評価点", record.evaluation ?? "-"),
    row("育成種別", RECORD_TYPE_LABELS[record.record_type]),
    row("シナリオ", record.scenario.name),
    row("作戦", record.strategy.name),
    row("ファン数", record.fans),
    row("重賞ボーナス", record.relation_bonus ?? "-"),
    row("育成日", record.trained_on ?? "-"),
  ].join("");
  const provenance = [
    row("共有日", record.shared_on),
    row("地域", record.region),
    row("認識器の版", record.recognizer_version),
    row("表の版", record.tables_version),
  ].join("");
  return `<h1>${esc(record.trainee.card.name)}</h1>
<table>${summary}</table>
<h2>ステータス</h2><table>${status}</table>
<h2>適性</h2><table>${aptitudes}</table>
<h2>スキル</h2>${list(skills)}
<h2>因子</h2>${list(factorsOf(record.factors.self))}
<h3>親 1</h3>${list(factorsOf(record.factors.parent1))}
<h3>親 2</h3>${list(factorsOf(record.factors.parent2))}
<h2>サポートカード</h2>${list(supports)}
<h2>家系</h2>
<h3>親 1</h3>${family(record.family.parent1)}
<h3>親 2</h3>${family(record.family.parent2)}
<h2>レース</h2>${list(record.races.map(race))}
<h2>記録</h2><table>${provenance}</table>`;
}

/** The full HTML document for one shared record. */
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
<style>
body { font-family: sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
th { text-align: left; padding-right: 1rem; font-weight: normal; }
footer { margin-top: 3rem; font-size: 0.9em; }
</style>
<link rel="icon" type="image/png" href="/favicon.png">
</head>
<body>
${body(record)}
${pageFooter(record.url)}
</body>
</html>
`;
}
