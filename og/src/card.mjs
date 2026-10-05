// The 1200×630 card drawn for one public record. Text only: every string on it comes from public
// JSON v1, whose names the sharing Worker resolved from its own tables, so the image says nothing
// the JSON does not.
//
// Elements are plain {type, props} objects, which satori accepts without React.

const h = (type, style, ...children) => ({
  type,
  props: { style, children: children.length === 1 ? children[0] : children },
});
const row = (style, ...children) => h("div", { display: "flex", flexDirection: "row", ...style }, ...children);
const column = (style, ...children) => h("div", { display: "flex", flexDirection: "column", ...style }, ...children);
const text = (style, value) =>
  h("div", { display: "flex", overflow: "hidden", whiteSpace: "nowrap", textOverflow: "ellipsis", ...style }, value);

const STATUS = [
  ["speed", "スピード"],
  ["stamina", "スタミナ"],
  ["power", "パワー"],
  ["guts", "根性"],
  ["intelligence", "賢さ"],
];

// Chips wrap into rows of a fixed height, and each list gets a box of whole rows: rows past the
// box are clipped whole, never cut through. The section title carries the full count.
const CHIP_ROW = 44;
const SKILL_ROWS = 3;
const FACTOR_ROWS = 2;

const INK = "#1f2430";
const MUTED = "#5b6273";
const PANEL = "#f3f1ec";
const ACCENT = "#c2410c";

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
const isNamed = (v) => isObject(v) && typeof v.name === "string";

/** Whether `record` is public JSON v1 with every key the card reads. */
export function isRenderable(record) {
  return (
    isObject(record) &&
    record.schema === 1 &&
    isObject(record.trainee) &&
    isNamed(record.trainee.card) &&
    isNamed(record.trainee.character) &&
    (record.trainee.rank === null || isNamed(record.trainee.rank)) &&
    (record.evaluation === null || Number.isInteger(record.evaluation)) &&
    isObject(record.status) &&
    STATUS.every(([key]) => Number.isInteger(record.status[key])) &&
    Array.isArray(record.skills) &&
    record.skills.every(isNamed) &&
    isObject(record.factors) &&
    Array.isArray(record.factors.self) &&
    record.factors.self.every((f) => isNamed(f) && Number.isInteger(f.star)) &&
    Array.isArray(record.races) &&
    record.races.every((r) => isObject(r) && isNamed(r.position)) &&
    isObject(record.scenario) &&
    typeof record.scenario.name === "string" &&
    (record.trained_on === null || typeof record.trained_on === "string")
  );
}

const chip = (label, style = {}) =>
  text(
    {
      maxWidth: 520,
      height: CHIP_ROW - 8,
      alignItems: "center",
      padding: "0 12px",
      margin: "0 8px 8px 0",
      borderRadius: 8,
      background: PANEL,
      fontSize: 20,
      ...style,
    },
    label,
  );

function chips(items, rows, toLabel) {
  const shown = items.map((item) => chip(toLabel(item)));
  if (shown.length === 0) shown.push(chip("なし", { color: MUTED }));
  return row({ flexWrap: "wrap", height: rows * CHIP_ROW, flexShrink: 0, overflow: "hidden" }, ...shown);
}

function header(record) {
  const { card, character, rank } = record.trainee;
  const score = record.evaluation === null ? "評価点 —" : `評価点 ${record.evaluation.toLocaleString("en-US")}`;
  return row(
    { alignItems: "flex-end", justifyContent: "space-between" },
    column(
      { flexShrink: 1, minWidth: 0 },
      text({ fontSize: 26, color: MUTED }, card.name),
      text({ fontSize: 52, fontWeight: 700 }, character.name),
    ),
    row(
      { alignItems: "baseline", flexShrink: 0, marginLeft: 24 },
      text({ fontSize: 56, fontWeight: 700, color: ACCENT, marginRight: 20 }, rank ? rank.name : "—"),
      text({ fontSize: 28 }, score),
    ),
  );
}

function statusRow(status) {
  return row(
    { justifyContent: "space-between", marginTop: 16, flexShrink: 0 },
    ...STATUS.map(([key, label]) =>
      column(
        { alignItems: "center", width: 210, padding: "6px 0", borderRadius: 10, background: PANEL },
        text({ fontSize: 20, color: MUTED }, label),
        text({ fontSize: 36, fontWeight: 700 }, String(status[key])),
      ),
    ),
  );
}

function section(title, body) {
  return column({ marginTop: 12, flexShrink: 0 }, text({ fontSize: 18, color: MUTED, marginBottom: 4 }, title), body);
}

function footer(record) {
  const wins = record.races.filter((r) => r.position.name === "1").length;
  const parts = [record.scenario.name, record.races.length > 0 ? `${record.races.length}戦${wins}勝` : null];
  if (record.trained_on) parts.push(record.trained_on);
  return row(
    { justifyContent: "space-between", alignItems: "center", marginTop: "auto", fontSize: 22, color: MUTED },
    text({ flexShrink: 1, minWidth: 0 }, parts.filter(Boolean).join(" ・ ")),
    text({ flexShrink: 0, marginLeft: 24, fontWeight: 700 }, "umacapture"),
  );
}

/** The card for `record`, which must satisfy isRenderable. */
export function buildCard(record) {
  return column(
    {
      width: 1200,
      height: 630,
      padding: "36px 48px 28px",
      background: "#ffffff",
      color: INK,
      fontFamily: "Noto Sans JP",
    },
    header(record),
    statusRow(record.status),
    section(
      `スキル ${record.skills.length}`,
      chips(record.skills, SKILL_ROWS, (s) => (s.level === undefined ? s.name : `${s.name} Lv${s.level}`)),
    ),
    section(
      `因子 ${record.factors.self.length}`,
      chips(record.factors.self, FACTOR_ROWS, (f) => `${f.name} ${"★".repeat(f.star)}`),
    ),
    footer(record),
  );
}

/**
 * The record-independent card served as /og/default.png, the image a page falls back to when the
 * function cannot draw its own. Same canvas, fonts and palette as buildCard, and no record data.
 * scripts/render_default.mjs draws it into web/og/default.png.
 */
export function buildFallbackCard() {
  return column(
    {
      width: 1200,
      height: 630,
      alignItems: "center",
      justifyContent: "center",
      background: "#ffffff",
      color: INK,
      fontFamily: "Noto Sans JP",
    },
    text({ fontSize: 96, fontWeight: 700 }, "umacapture"),
    text({ marginTop: 16, padding: "8px 28px", borderRadius: 10, background: PANEL, fontSize: 40, color: ACCENT }, "公開レコード"),
  );
}
