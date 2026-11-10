// Posted form v1: what a client sends to POST /api/records as `record`. Every key is checked, an
// unknown key anywhere is refused, and the stored form is rebuilt from the checked values alone in a
// fixed key order: the bytes a client sent are never stored.

import { Keys } from "./tables.mjs";

/** A value the posted form does not allow; `field` locates it (`record.skills[3].id`). */
export class InvalidPayload extends Error {
  constructor(field) {
    super(`invalid ${field}`);
    this.field = field;
  }
}

/** A sid past the end of the server's table, which a module set newer than the tables can produce. */
export class SidOutOfRange extends InvalidPayload {}

const MAX_SKILLS = 128;
const MAX_FACTORS = 128;
const MAX_SUPPORT_CARDS = 6;
const MAX_RACES = 96;

const RECORD_TYPES = ["Standard", "InheritanceOnly"];
// The record types a parent may carry: the app's RecordType, friends' records included, since a
// parent is whichever record the sharer bred from.
const PARENT_RECORD_TYPES = ["Standard", "InheritanceOnly", "FriendStandard", "FriendInheritance"];
// A face icon is the recognizer's class number, published as is so the importing app can show the
// same face. The bound only keeps a number sane: the largest class number seen in real records is
// 876, far below it.
const MAX_ICON = 65_535;
const VERSION = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:?\d{2})$/;
const TRAINED_DATE = /^(\d{4})\/(\d{2})\/(\d{2})$/;

/**
 * Milliseconds since the epoch of a module or recognizer version (`2026-09-30T11:00:00+0900`), or
 * null when the text is not a real date and time in that shape.
 */
export function parseVersion(text) {
  const m = typeof text === "string" ? VERSION.exec(text) : null;
  if (!m) return null;
  const [, y, mo, d, h, mi, s, zone] = m;
  const local = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s);
  const check = new Date(local);
  if (check.getUTCMonth() !== +mo - 1 || check.getUTCDate() !== +d || +h > 23 || +mi > 59 || +s > 59) return null;
  if (zone === "Z") return local;
  const digits = zone.replace(":", "");
  const offset = (+digits.slice(1, 3) * 60 + +digits.slice(3, 5)) * 60_000;
  return digits[0] === "+" ? local - offset : local + offset;
}

function isRealDate(y, m, d) {
  const date = new Date(Date.UTC(+y, +m - 1, +d));
  return date.getUTCFullYear() === +y && date.getUTCMonth() === +m - 1 && date.getUTCDate() === +d;
}

function object(value, field, required, optional = []) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new InvalidPayload(field);
  for (const key of Object.keys(value)) {
    if (!required.includes(key) && !optional.includes(key)) throw new InvalidPayload(`${field}.${key}`);
  }
  for (const key of required) {
    if (!Object.hasOwn(value, key)) throw new InvalidPayload(`${field}.${key}`);
  }
  return value;
}

function int(value, field, min, max) {
  if (!Number.isInteger(value) || value < min || value > max) throw new InvalidPayload(field);
  return value;
}

function list(value, field, max) {
  if (!Array.isArray(value) || value.length > max) throw new InvalidPayload(field);
  return value;
}

/** An optional key: absent and null both mean "not given". */
const given = (obj, key) => obj[key] !== undefined && obj[key] !== null;

class Checker {
  constructor(tables) {
    this.tables = tables;
  }

  /** A 0-based index into table `key`. */
  sid(value, field, key) {
    int(value, field, 0, Number.MAX_SAFE_INTEGER);
    if (value >= this.tables.size(key)) throw new SidOutOfRange(field);
    return value;
  }

  /** Copies `value`'s face icon class number into `out`, when it carries one. */
  icon(value, out, field) {
    if (given(value, "icon")) out.icon = int(value.icon, `${field}.icon`, 0, MAX_ICON);
  }

  /**
   * A parent's chara. Its icon, rank and record type are optional: shares posted before the app sent
   * them stay valid, and the app reading a share tells such a share by their absence.
   */
  chara(value, field) {
    object(value, field, ["character", "card"], ["icon", "rank", "record_type"]);
    const out = {
      character: this.sid(value.character, `${field}.character`, Keys.character),
      card: this.sid(value.card, `${field}.card`, Keys.card),
    };
    this.icon(value, out, field);
    if (given(value, "rank")) out.rank = this.sid(value.rank, `${field}.rank`, Keys.rank);
    if (given(value, "record_type")) {
      if (!PARENT_RECORD_TYPES.includes(value.record_type)) throw new InvalidPayload(`${field}.record_type`);
      out.record_type = value.record_type;
    }
    return out;
  }

  parent(value, field) {
    object(value, field, ["self", "parent1", "parent2"], ["rental"]);
    const out = {
      self: this.chara(value.self, `${field}.self`),
      parent1: this.chara(value.parent1, `${field}.parent1`),
      parent2: this.chara(value.parent2, `${field}.parent2`),
    };
    if (given(value, "rental")) {
      if (typeof value.rental !== "boolean") throw new InvalidPayload(`${field}.rental`);
      out.rental = value.rental;
    }
    return out;
  }

  aptitudes(value, field) {
    object(value, field, ["ground", "distance", "style"]);
    const group = (name, keys) => {
      const g = object(value[name], `${field}.${name}`, keys);
      return Object.fromEntries(keys.map((k) => [k, int(g[k], `${field}.${name}.${k}`, 0, 7)]));
    };
    return {
      ground: group("ground", ["turf", "dirt"]),
      distance: group("distance", ["short_range", "mile_range", "middle_range", "long_range"]),
      style: group("style", ["lead_pace", "with_pace", "off_pace", "late_charge"]),
    };
  }

  skill(value, field) {
    object(value, field, ["id"], ["level"]);
    const out = { id: this.sid(value.id, `${field}.id`, Keys.skill) };
    if (given(value, "level")) out.level = int(value.level, `${field}.level`, 0, 10);
    return out;
  }

  factors(value, field) {
    return list(value, field, MAX_FACTORS).map((f, i) => {
      object(f, `${field}[${i}]`, ["id", "star"]);
      return { id: this.sid(f.id, `${field}[${i}].id`, Keys.factor), star: int(f.star, `${field}[${i}].star`, 1, 3) };
    });
  }

  supportCard(value, field) {
    object(value, field, ["id", "rank", "level"]);
    return {
      id: this.sid(value.id, `${field}.id`, Keys.supportCard),
      rank: int(value.rank, `${field}.rank`, 0, 4),
      level: int(value.level, `${field}.level`, 0, 60),
    };
  }

  race(value, field) {
    object(value, field, ["title", "place", "ground", "distance", "variation", "weather", "strategy", "turn", "position"]);
    const position = int(value.position, `${field}.position`, 1, Number.MAX_SAFE_INTEGER);
    // The recognizer stores the finishing position 1-based, so the table holds positions 1 to size.
    if (position > this.tables.size(Keys.position)) throw new SidOutOfRange(`${field}.position`);
    return {
      title: this.sid(value.title, `${field}.title`, Keys.raceTitle),
      place: this.sid(value.place, `${field}.place`, Keys.place),
      ground: this.sid(value.ground, `${field}.ground`, Keys.ground),
      distance: this.sid(value.distance, `${field}.distance`, Keys.distance),
      variation: this.sid(value.variation, `${field}.variation`, Keys.variation),
      weather: this.sid(value.weather, `${field}.weather`, Keys.weather),
      strategy: this.sid(value.strategy, `${field}.strategy`, Keys.strategy),
      turn: this.sid(value.turn, `${field}.turn`, Keys.turn),
      position,
    };
  }
}

const TOP_LEVEL = [
  "schema",
  "region",
  "module_version",
  "recognizer_version",
  "record_type",
  "strategy",
  "trainee",
  "evaluation_value",
  "status",
  "aptitudes",
  "skills",
  "factors",
  "support_cards",
  "family",
  "fans",
  "scenario",
  "trained_date",
  "races",
];

/**
 * The canonical posted form rebuilt from `value`, checked against `tables`. Throws InvalidPayload
 * (or its SidOutOfRange) at the first value the form does not allow. Keys are checked in the order
 * they are listed here, so `module_version` is known to be valid by the time any sid is checked.
 */
export function canonicalPostedForm(value, tables) {
  const F = "record";
  const c = new Checker(tables);
  object(value, F, TOP_LEVEL, ["relation_bonus"]);
  if (value.schema !== 1) throw new InvalidPayload(`${F}.schema`);
  if (value.region !== "JPN") throw new InvalidPayload(`${F}.region`);
  if (parseVersion(value.module_version) === null) throw new InvalidPayload(`${F}.module_version`);
  if (parseVersion(value.recognizer_version) === null) throw new InvalidPayload(`${F}.recognizer_version`);
  // Only the user's own trainings are published; a friend's record is refused here as well.
  if (!RECORD_TYPES.includes(value.record_type)) throw new InvalidPayload(`${F}.record_type`);

  const out = {
    schema: 1,
    region: value.region,
    module_version: value.module_version,
    recognizer_version: value.recognizer_version,
    record_type: value.record_type,
    strategy: c.sid(value.strategy, `${F}.strategy`, Keys.strategy),
  };
  if (given(value, "relation_bonus")) out.relation_bonus = int(value.relation_bonus, `${F}.relation_bonus`, 0, 999);

  const trainee = object(value.trainee, `${F}.trainee`, ["character", "card", "rank"], ["icon"]);
  out.trainee = {
    character: c.sid(trainee.character, `${F}.trainee.character`, Keys.character),
    card: c.sid(trainee.card, `${F}.trainee.card`, Keys.card),
    rank: c.sid(trainee.rank, `${F}.trainee.rank`, Keys.rank),
  };
  c.icon(trainee, out.trainee, `${F}.trainee`);
  out.evaluation_value = int(value.evaluation_value, `${F}.evaluation_value`, 0, 9_999_999);

  const statusKeys = ["speed", "stamina", "power", "guts", "intelligence"];
  const status = object(value.status, `${F}.status`, statusKeys);
  out.status = Object.fromEntries(statusKeys.map((k) => [k, int(status[k], `${F}.status.${k}`, 0, 9_999)]));
  out.aptitudes = c.aptitudes(value.aptitudes, `${F}.aptitudes`);
  out.skills = list(value.skills, `${F}.skills`, MAX_SKILLS).map((s, i) => c.skill(s, `${F}.skills[${i}]`));

  const factors = object(value.factors, `${F}.factors`, ["self", "parent1", "parent2"]);
  out.factors = {
    self: c.factors(factors.self, `${F}.factors.self`),
    parent1: c.factors(factors.parent1, `${F}.factors.parent1`),
    parent2: c.factors(factors.parent2, `${F}.factors.parent2`),
  };
  out.support_cards = list(value.support_cards, `${F}.support_cards`, MAX_SUPPORT_CARDS).map((s, i) =>
    c.supportCard(s, `${F}.support_cards[${i}]`),
  );

  const family = object(value.family, `${F}.family`, ["parent1", "parent2"]);
  out.family = {
    parent1: c.parent(family.parent1, `${F}.family.parent1`),
    parent2: c.parent(family.parent2, `${F}.family.parent2`),
  };
  out.fans = int(value.fans, `${F}.fans`, 0, 2_147_483_647);

  const scenario = object(value.scenario, `${F}.scenario`, ["id"]);
  out.scenario = { id: c.sid(scenario.id, `${F}.scenario.id`, Keys.scenario) };

  const date = value.trained_date;
  const dm = typeof date === "string" ? TRAINED_DATE.exec(date) : null;
  if (date !== "" && !(dm && isRealDate(dm[1], dm[2], dm[3]))) throw new InvalidPayload(`${F}.trained_date`);
  out.trained_date = date;

  out.races = list(value.races, `${F}.races`, MAX_RACES).map((r, i) => c.race(r, `${F}.races[${i}]`));
  return out;
}
