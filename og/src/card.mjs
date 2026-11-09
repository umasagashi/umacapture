// The 1200×630 card drawn for one public record: the trainee (card, rank, evaluation), the
// aptitudes and the factor totals, and nothing else. Text only: every string on it comes from public
// JSON v1, whose names the sharing Worker resolved from its own tables, so the image says nothing
// the JSON does not. The fixed labels ("因子（合計）", "芝", …) are the only other words on it.
//
// Elements are plain {type, props} objects, which satori accepts without React.

// The light values of the public pages' colour variables in web/site/site.css, which takes them
// from the app's FlexScheme.blue theme. Copied because satori cannot read a stylesheet: change both.
//   page = --page, card = --card, tint = --tint, ink = --ink, muted = --muted,
//   primary = --primary, onPrimary = --on-primary, container = --primary-container,
//   onContainer = --on-primary-container, factor.<color> = --factor-<color>
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
  factor: { blue: "#1E88E5", red: "#E53935", green: "#43A047", white: "#9E9E9E" },
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

/** The aptitude groups in the order the public page lists them: key in `aptitudes`, cells. */
const APTITUDES = [
  ["ground", [["turf", "芝"], ["dirt", "ダート"]]],
  ["distance", [["short", "短距離"], ["mile", "マイル"], ["middle", "中距離"], ["long", "長距離"]]],
  ["style", [["lead_pace", "逃げ"], ["with_pace", "先行"], ["off_pace", "差し"], ["late_charge", "追込"]]],
];

/** The factor colours public JSON v1 writes in `color`. */
const FACTOR_COLORS = ["blue", "red", "green", "white"];

// Factor chips wrap into rows of a fixed height inside a box of whole rows: rows past the box are
// clipped whole, never cut through. factor_totals lists the white factors last and most stars first,
// so the clipped ones are the white factors with the fewest stars. The title carries the full count.
const CHIP_ROW = 46;
const FACTOR_ROWS = 7;

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
const isNamed = (v) => isObject(v) && typeof v.name === "string";
const isTrainee = (v) => isObject(v) && isNamed(v.card) && isNamed(v.character);
const isTotal = (v) => isNamed(v) && Number.isInteger(v.star) && FACTOR_COLORS.includes(v.color);
const isAptitudes = (v) =>
  isObject(v) && APTITUDES.every(([group, cells]) => isObject(v[group]) && cells.every(([key]) => isNamed(v[group][key])));

/**
 * Whether `record` is public JSON v1 with every key the card reads. JSON from a Worker that does not
 * write `factor_totals` is not, so the handler answers it with the fallback image.
 */
export function isRenderable(record) {
  return (
    isObject(record) &&
    record.schema === 1 &&
    (record.record_type === "standard" || record.record_type === "inheritance_only") &&
    isTrainee(record.trainee) &&
    (record.trainee.rank === null || isNamed(record.trainee.rank)) &&
    (record.evaluation === null || Number.isInteger(record.evaluation)) &&
    isAptitudes(record.aptitudes) &&
    Array.isArray(record.factor_totals) &&
    record.factor_totals.every(isTotal)
  );
}

// "[costume]name" with name equal to the character is split so the name can be drawn large; any
// other card name is drawn whole.
function splitCard(card, character) {
  const match = /^\[(.+)\](.+)$/.exec(card);
  return match && match[2] === character ? [match[1], match[2]] : ["", card];
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

// The grade colours of the public page: S and A in the primary colour, B and C in the ink, the rest
// muted.
function gradeColor(grade) {
  if (grade === "S" || grade === "A") return COLOR.primary;
  if (/^[D-G]$/.test(grade)) return COLOR.muted;
  return COLOR.ink;
}

function aptitudes(record) {
  const groups = APTITUDES.map(([group, cells]) =>
    row(
      { flexShrink: 0 },
      ...cells.map(([key, label]) => {
        const grade = record.aptitudes[group][key].name;
        return row(
          { alignItems: "baseline", padding: "4px 10px", marginRight: 6, borderRadius: 10, background: COLOR.tint },
          text({ fontSize: 17, color: COLOR.muted, marginRight: 6 }, label),
          text({ fontSize: 24, fontWeight: 700, color: gradeColor(grade) }, grade),
        );
      }),
    ),
  );
  const divider = row({ width: 1, alignSelf: "stretch", margin: "0 10px 0 4px", background: COLOR.muted, opacity: 0.25 });
  return row(
    { marginTop: 16, flexShrink: 0, justifyContent: "space-between" },
    ...groups.flatMap((group, i) => (i === 0 ? [group] : [divider, group])),
  );
}

// The colour is a band on the chip's left edge; the chip keeps the tint behind its text, so the
// text contrast is the same for every colour.
const factorChip = (f) =>
  row(
    {
      alignItems: "center",
      maxWidth: 520,
      height: CHIP_ROW - 8,
      padding: "0 14px 0 10px",
      margin: "0 8px 8px 0",
      borderRadius: 19,
      borderLeft: `8px solid ${COLOR.factor[f.color]}`,
      background: COLOR.tint,
      fontSize: 20,
    },
    text({ flexShrink: 1, minWidth: 0 }, f.name),
    text({ flexShrink: 0, marginLeft: 6, fontSize: 16, color: COLOR.primary }, `★${f.star}`),
  );

function factors(record) {
  const totals = record.factor_totals;
  const shown = totals.length > 0 ? totals.map(factorChip) : [text({ fontSize: 20, color: COLOR.muted }, "なし")];
  return column(
    { marginTop: 14, flexShrink: 0 },
    text({ fontSize: 18, color: COLOR.muted, marginBottom: 6 }, `因子（合計） ${totals.length}種`),
    row({ flexWrap: "wrap", height: FACTOR_ROWS * CHIP_ROW, flexShrink: 0, overflow: "hidden" }, ...shown),
  );
}

function footer(logo) {
  return row(
    { marginTop: "auto", alignItems: "center", justifyContent: "flex-end", fontSize: 21, color: COLOR.ink, fontWeight: 700 },
    image(logo, 34),
    text({ marginLeft: 8 }, "umacapture"),
  );
}

/**
 * The card for `record`, which must satisfy isRenderable.
 * `logo` is web/site/logo.svg as an image source (a data URI).
 */
export function buildCard(record, logo) {
  return column(
    {
      width: 1200,
      height: 630,
      padding: "30px 44px 24px",
      background: COLOR.page,
      color: COLOR.ink,
      fontFamily: FONT_FAMILY,
    },
    column(
      { flexGrow: 1, borderRadius: 28, padding: "24px 30px 18px", background: COLOR.card },
      header(record),
      aptitudes(record),
      factors(record),
      footer(logo),
    ),
  );
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
