// Public JSON v1: what /r/<id>.json serves. Built from the stored posted form (sids and numbers
// only) by resolving every sid through the server's own tables, so every string a reader sees comes
// from those tables and never from the client. sids themselves are not published.
//
// Changes to v1 only ever add keys. A breaking change gets a new path and v1 stays.

import { Keys } from "./tables.mjs";

const SCHEMA = 1;
const DAY_MS = 86_400_000;

/** A UTC day (days since the epoch, as `records.shared_day` holds it) as `YYYY-MM-DD`. */
export function dayToIso(day) {
  return new Date(day * DAY_MS).toISOString().slice(0, 10);
}

/** `YYYY/MM/DD` as `YYYY-MM-DD`; the empty string (date not read) as null. */
function trainedOn(date) {
  return date === "" ? null : date.replaceAll("/", "-");
}

const chara = (tables, c) => ({
  card: tables.label(Keys.card, c.card),
  character: tables.label(Keys.character, c.character),
});

const parent = (tables, p) => ({
  self: chara(tables, p.self),
  parent1: chara(tables, p.parent1),
  parent2: chara(tables, p.parent2),
  rental: p.rental ?? false,
});

const aptitude = (tables, value) => ({ name: tables.name(Keys.aptitude, value), value });

function aptitudes(tables, a) {
  const of = (value) => aptitude(tables, value);
  return {
    ground: { turf: of(a.ground.turf), dirt: of(a.ground.dirt) },
    distance: {
      short: of(a.distance.short_range),
      mile: of(a.distance.mile_range),
      middle: of(a.distance.middle_range),
      long: of(a.distance.long_range),
    },
    style: {
      lead_pace: of(a.style.lead_pace),
      with_pace: of(a.style.with_pace),
      off_pace: of(a.style.off_pace),
      late_charge: of(a.style.late_charge),
    },
  };
}

const factors = (tables, list) =>
  list.map((f) => ({ ...tables.label(Keys.factor, f.id), star: f.star }));

function skill(tables, s) {
  const out = tables.label(Keys.skill, s.id);
  if (s.level !== undefined) out.level = s.level;
  return out;
}

function race(tables, r) {
  return {
    title: tables.label(Keys.raceTitle, r.title),
    turn: tables.label(Keys.turn, r.turn),
    place: tables.label(Keys.place, r.place),
    ground: tables.label(Keys.ground, r.ground),
    // The distance table holds metres as text; the public form gives them as an integer.
    distance: Number.parseInt(tables.name(Keys.distance, r.distance), 10),
    variation: tables.label(Keys.variation, r.variation),
    weather: tables.label(Keys.weather, r.weather),
    strategy: tables.label(Keys.strategy, r.strategy),
    // The recognizer stores the finishing position 1-based (1st place is 1).
    position: tables.label(Keys.position, r.position - 1),
  };
}

/**
 * @param {object} form the stored posted form v1
 * @param {{id: string, sharedDay: number, origin: string}} meta
 * @param {import("./tables.mjs").Tables} tables
 */
export function buildPublicRecord(form, meta, tables) {
  return {
    schema: SCHEMA,
    id: meta.id,
    url: `${meta.origin}/r/${meta.id}`,
    shared_on: dayToIso(meta.sharedDay),
    region: form.region,
    recognizer_version: form.recognizer_version,
    tables_version: tables.version,
    ...recordSummary(form, tables),
    status: { ...form.status },
    aptitudes: aptitudes(tables, form.aptitudes),
    strategy: tables.label(Keys.strategy, form.strategy),
    skills: form.skills.map((s) => skill(tables, s)),
    factors: {
      self: factors(tables, form.factors.self),
      parent1: factors(tables, form.factors.parent1),
      parent2: factors(tables, form.factors.parent2),
    },
    support_cards: form.support_cards.map((c) => ({
      ...tables.label(Keys.supportCard, c.id),
      limit_break: c.rank,
      level: c.level,
    })),
    family: { parent1: parent(tables, form.family.parent1), parent2: parent(tables, form.family.parent2) },
    relation_bonus: form.relation_bonus ?? null,
    fans: form.fans,
    // Scenario labels carry a subtitle after a line break; the public name is the first line.
    scenario: { name: tables.name(Keys.scenario, form.scenario.id).split("\n")[0] },
    trained_on: trainedOn(form.trained_date),
    races: form.races.map((r) => race(tables, r)),
  };
}

/**
 * The part of a public record that names it in a list: its type, trainee and evaluation. The public
 * record carries the same keys.
 *
 * @param {object} form the stored posted form v1
 * @param {import("./tables.mjs").Tables} tables
 */
export function recordSummary(form, tables) {
  const inheritanceOnly = form.record_type === "InheritanceOnly";
  return {
    record_type: inheritanceOnly ? "inheritance_only" : "standard",
    trainee: {
      card: tables.label(Keys.card, form.trainee.card),
      character: tables.label(Keys.character, form.trainee.character),
      rank: form.trainee.rank === undefined ? null : tables.label(Keys.rank, form.trainee.rank),
    },
    // An inheritance-only record never reads the evaluation value, so its 0 means "unknown".
    evaluation: inheritanceOnly ? null : form.evaluation_value,
  };
}
