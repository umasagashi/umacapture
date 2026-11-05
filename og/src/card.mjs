// The 1200×630 card drawn for one public record. Text only: every string on it comes from public
// JSON v1, whose names the sharing Worker resolved from its own tables, so the image says nothing
// the JSON does not. The fixed labels ("スキル", "親1", …) are the only other words on it.
//
// Elements are plain {type, props} objects, which satori accepts without React.

// The light values of the public pages' colour variables in web/site/site.css, which takes them
// from the app's FlexScheme.blue theme. Copied because satori cannot read a stylesheet: change both.
//   page = --page, card = --card, tint = --tint, ink = --ink, muted = --muted,
//   primary = --primary, onPrimary = --on-primary, container = --primary-container,
//   onContainer = --on-primary-container
const COLOR = {
  page: "#E5E8EB",
  card: "#F3F6FA",
  tint: "#DDEDFD",
  ink: "#111111",
  muted: "#393939",
  primary: "#1565C0",
  onPrimary: "#FFFFFF",
  container: "#90CAF9",
  onContainer: "#000000",
};

/** The family the card is set in; the handler and the default-image script load it under this name. */
export const FONT_FAMILY = "M PLUS Rounded 1c";

const h = (type, style, ...children) => ({
  type,
  props: { style, children: children.length === 1 ? children[0] : children },
});
const row = (style, ...children) => h("div", { display: "flex", flexDirection: "row", ...style }, ...children);
const column = (style, ...children) => h("div", { display: "flex", flexDirection: "column", ...style }, ...children);
const text = (style, value) =>
  h("div", { display: "flex", overflow: "hidden", whiteSpace: "nowrap", textOverflow: "ellipsis", ...style }, value);
const image = (src, size) => ({ type: "img", props: { src, width: size, height: size } });

const STATUS = [
  ["speed", "スピード"],
  ["stamina", "スタミナ"],
  ["power", "パワー"],
  ["guts", "根性"],
  ["intelligence", "賢さ"],
];

// Chips wrap into rows of a fixed height, and each list gets a box of whole rows: rows past the
// box are clipped whole, never cut through. The section title carries the full count.
const CHIP_ROW = 46;

/** The two ways a card can present a record. */
export const FOCI = ["training", "inheritance"];

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
const isNamed = (v) => isObject(v) && typeof v.name === "string";
const isFactorList = (v) => Array.isArray(v) && v.every((f) => isNamed(f) && Number.isInteger(f.star));
const isTrainee = (v) => isObject(v) && isNamed(v.card) && isNamed(v.character);
const isParent = (v) => isObject(v) && isTrainee(v.self) && typeof v.rental === "boolean";

/** Whether `record` is public JSON v1 with every key the card reads. */
export function isRenderable(record) {
  return (
    isObject(record) &&
    record.schema === 1 &&
    (record.record_type === "standard" || record.record_type === "inheritance_only") &&
    isTrainee(record.trainee) &&
    (record.trainee.rank === null || isNamed(record.trainee.rank)) &&
    (record.evaluation === null || Number.isInteger(record.evaluation)) &&
    isObject(record.status) &&
    STATUS.every(([key]) => Number.isInteger(record.status[key])) &&
    Array.isArray(record.skills) &&
    record.skills.every(isNamed) &&
    isObject(record.factors) &&
    isFactorList(record.factors.self) &&
    isFactorList(record.factors.parent1) &&
    isFactorList(record.factors.parent2) &&
    isObject(record.family) &&
    isParent(record.family.parent1) &&
    isParent(record.family.parent2) &&
    Array.isArray(record.races) &&
    record.races.every((r) => isObject(r) && isNamed(r.position)) &&
    isObject(record.scenario) &&
    typeof record.scenario.name === "string" &&
    (record.trained_on === null || typeof record.trained_on === "string")
  );
}

/**
 * Which of FOCI the card presents `record` with: the sharer's choice in `view.focus` when the JSON
 * carries a known one, else the record's kind. JSON written before `view` existed, and a focus this
 * function does not know, fall back to the kind, so every renderable record has a card.
 */
export function focusOf(record) {
  const focus = record.view?.focus;
  if (FOCI.includes(focus)) return focus;
  return record.record_type === "inheritance_only" ? "inheritance" : "training";
}

const starTotal = (factors) => factors.reduce((sum, f) => sum + f.star, 0);

// "[costume]name" with name equal to the character is split so the name can be drawn large; any
// other card name is drawn whole.
function splitCard(card, character) {
  const match = /^\[(.+)\](.+)$/.exec(card);
  return match && match[2] === character ? [match[1], match[2]] : ["", card];
}

const chip = (label, extra, style = {}) =>
  row(
    {
      alignItems: "center",
      maxWidth: 520,
      height: CHIP_ROW - 8,
      padding: "0 14px",
      margin: "0 8px 8px 0",
      borderRadius: 19,
      background: COLOR.tint,
      fontSize: 20,
      ...style,
    },
    text({ flexShrink: 1, minWidth: 0 }, label),
    extra ? text({ flexShrink: 0, marginLeft: 6, fontSize: 16, color: COLOR.primary }, extra) : null,
  );

function chips(items, rows, toChip) {
  const shown = items.map(toChip);
  if (shown.length === 0) shown.push(chip("なし", null, { color: COLOR.muted }));
  return row({ flexWrap: "wrap", height: rows * CHIP_ROW, flexShrink: 0, overflow: "hidden" }, ...shown);
}

const factorChip = (f) => chip(f.name, "★".repeat(f.star));

function section(title, body) {
  return column({ marginTop: 14, flexShrink: 0 }, text({ fontSize: 18, color: COLOR.muted, marginBottom: 6 }, title), body);
}

function header(record) {
  const { card, character, rank } = record.trainee;
  const [costume, name] = splitCard(card.name, character.name);
  const kind = record.record_type === "inheritance_only" ? "継承用" : "育成";
  return row(
    { alignItems: "flex-end", justifyContent: "space-between", flexShrink: 0 },
    column(
      { flexShrink: 1, minWidth: 0 },
      text({ fontSize: 24, color: COLOR.muted, height: 32 }, costume),
      text({ fontSize: 54, fontWeight: 700 }, name),
    ),
    row(
      { alignItems: "center", flexShrink: 0, marginLeft: 24 },
      rank
        ? text(
            {
              fontSize: 40,
              fontWeight: 700,
              padding: "0 14px",
              marginRight: 16,
              borderRadius: 14,
              background: COLOR.primary,
              color: COLOR.onPrimary,
            },
            rank.name,
          )
        : null,
      record.evaluation === null
        ? text(
            { fontSize: 26, padding: "4px 18px", borderRadius: 20, background: COLOR.container, color: COLOR.onContainer },
            kind,
          )
        : column(
            { alignItems: "flex-end" },
            text({ fontSize: 18, color: COLOR.muted }, "評価点"),
            text({ fontSize: 36, fontWeight: 700 }, record.evaluation.toLocaleString("en-US")),
          ),
    ),
  );
}

function footer(left, logo) {
  return row(
    { marginTop: "auto", alignItems: "center", justifyContent: "space-between", fontSize: 21, color: COLOR.muted },
    text({ flexShrink: 1, minWidth: 0 }, left),
    row(
      { alignItems: "center", flexShrink: 0, marginLeft: 20, color: COLOR.ink, fontWeight: 700 },
      image(logo, 34),
      text({ marginLeft: 8 }, "umacapture"),
    ),
  );
}

const frame = (...children) =>
  column(
    {
      width: 1200,
      height: 630,
      padding: "30px 44px 24px",
      background: COLOR.page,
      color: COLOR.ink,
      fontFamily: FONT_FAMILY,
    },
    column({ flexGrow: 1, borderRadius: 28, padding: "24px 30px 18px", background: COLOR.card }, ...children),
  );

function training(record, logo) {
  const wins = record.races.filter((r) => r.position.name === "1").length;
  const races = record.races.length > 0 ? `${record.races.length}戦${wins}勝` : null;
  return frame(
    header(record),
    row(
      { justifyContent: "space-between", marginTop: 14, flexShrink: 0 },
      ...STATUS.map(([key, label]) =>
        column(
          { alignItems: "center", width: 200, padding: "6px 0", borderRadius: 16, background: COLOR.tint },
          text({ fontSize: 18, color: COLOR.muted }, label),
          text({ fontSize: 36, fontWeight: 700 }, String(record.status[key])),
        ),
      ),
    ),
    section(
      `スキル ${record.skills.length}`,
      chips(record.skills, 2, (s) => chip(s.name, s.level === undefined ? null : `Lv${s.level}`)),
    ),
    section(`因子 ${record.factors.self.length}`, chips(record.factors.self, 2, factorChip)),
    footer([record.scenario.name, races, record.trained_on].filter(Boolean).join(" ・ "), logo),
  );
}

function parentPanel(label, parent, factors) {
  return column(
    { flexGrow: 1, flexBasis: 0, minWidth: 0, padding: "10px 14px", borderRadius: 16, background: COLOR.tint },
    row(
      { alignItems: "baseline" },
      text({ flexShrink: 0, fontSize: 16, color: COLOR.muted, marginRight: 8 }, label),
      text({ flexShrink: 1, minWidth: 0, fontSize: 22, fontWeight: 700 }, parent.self.character.name),
      parent.rental ? text({ flexShrink: 0, fontSize: 14, marginLeft: 8, color: COLOR.primary }, "レンタル") : null,
    ),
    text({ fontSize: 16, color: COLOR.muted, marginTop: 4 }, `因子 ${factors.length} ・ ★${starTotal(factors)}`),
  );
}

function inheritance(record, logo) {
  const self = record.factors.self;
  return frame(
    header(record),
    section(`本人の因子 ${self.length} ・ ★${starTotal(self)}`, chips(self, 4, factorChip)),
    row(
      { marginTop: 10, flexShrink: 0 },
      parentPanel("親1", record.family.parent1, record.factors.parent1),
      row({ width: 12 }),
      parentPanel("親2", record.family.parent2, record.factors.parent2),
    ),
    footer([record.scenario.name, record.trained_on].filter(Boolean).join(" ・ "), logo),
  );
}

/**
 * The card for `record`, which must satisfy isRenderable, laid out for focusOf(record).
 * `logo` is web/site/logo.svg as an image source (a data URI).
 */
export function buildCard(record, logo) {
  return focusOf(record) === "inheritance" ? inheritance(record, logo) : training(record, logo);
}

/**
 * The record-independent card served as /og/default.png, the image a page falls back to when the
 * function cannot draw its own. Same canvas, fonts and colours as buildCard, and no record data.
 * scripts/render_default.mjs draws it into web/og/default.png.
 */
export function buildFallbackCard(logo) {
  return column(
    {
      width: 1200,
      height: 630,
      alignItems: "center",
      justifyContent: "center",
      background: COLOR.page,
      color: COLOR.ink,
      fontFamily: FONT_FAMILY,
    },
    image(logo, 160),
    text({ fontSize: 88, fontWeight: 700, marginTop: 20 }, "umacapture"),
    text(
      { marginTop: 10, padding: "6px 26px", borderRadius: 30, background: COLOR.container, color: COLOR.onContainer, fontSize: 36 },
      "共有レコード",
    ),
  );
}

/** `svg` (the bytes of web/site/logo.svg) as an image source satori accepts. */
export const svgDataUri = (svg) => `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
