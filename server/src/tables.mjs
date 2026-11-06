// Name tables the Worker resolves recognizer class numbers (sids) through.
//
// The tables live in D1 (migrations/0006_share_tables.sql): publishing a recognizer module set
// appends the rows its archive adds, so the Worker can name every sid of the module set served to
// users without being deployed again. A table read back from D1 has this shape:
//
//   {
//     "version": "<recognizer_version of the latest load, null while D1 holds none>",
//     "names": { "<labels.json key>": ["<name of sid 0>", "<name of sid 1>", ...], ... },
//     "gids":  { "<labels.json key>": [<gid of sid 0>, <gid of sid 1>, ...], ... }
//   }
//
// `names` holds every labels.json key except campaign_field.name. `gids` holds only the keys an info
// table gives a gid column to (character.card, skill.name, factor.name, race_title.name); a key
// absent from `gids` has no gid, and the public JSON then carries the name alone. Both lists are
// indexed by sid, and a newer module set only ever appends to them.

/** The labels.json keys the public form reads. */
export const Keys = Object.freeze({
  aptitude: "aptitude.name",
  character: "character.character",
  card: "character.card",
  rank: "character_rank.name",
  factor: "factor.name",
  place: "race_place.place",
  ground: "race_place.ground",
  distance: "race_place.distance",
  variation: "race_place.variation",
  position: "race_position.name",
  strategy: "race_strategy.name",
  raceTitle: "race_title.name",
  turn: "race_turn.name",
  weather: "race_weather.name",
  scenario: "scenario.name",
  skill: "skill.name",
  supportCard: "support_card.name",
});

/** A name table whose index is not the stored value itself. */
export class TableLookupError extends Error {}

export class Tables {
  constructor(raw) {
    this.version = raw.version;
    this.names = raw.names;
    this.gids = raw.gids;
  }

  /**
   * How many entries table `key` holds: valid sids are 0 to size − 1. An entry is held only once
   * every column the key has is: its name, and its gid when the key has a gid column. A load writes
   * the names before the gids, so tables read part way through it can hold a name whose gid is not
   * there yet; that sid is not held until its gid is.
   */
  size(key) {
    const list = this.names[key];
    if (!list) throw new TableLookupError(`${key} is not in the tables`);
    const gids = this.gids[key];
    return gids ? Math.min(list.length, gids.length) : list.length;
  }

  /** The name stored at `index` of table `key`. Throws for an index the table does not hold. */
  name(key, index) {
    if (!Number.isInteger(index) || index < 0 || index >= this.size(key)) {
      throw new TableLookupError(`${key}[${index}] is not in the tables`);
    }
    return this.names[key][index];
  }

  /** `{gid, name}` when the key has a gid column, `{name}` otherwise. */
  label(key, sid) {
    const name = this.name(key, sid);
    const gids = this.gids[key];
    return gids ? { gid: gids[sid], name } : { name };
  }
}

/** The tables of D1 at one generation (0 while D1 holds no load). */
class Snapshot {
  constructor(generation, tables) {
    this.generation = generation;
    this.tables = tables;
  }
}

/** The latest load row of D1, `{generation, recognizer_version}`, or null while there is none. */
const latestLoad = (db) =>
  db.prepare("SELECT generation, recognizer_version FROM share_table_load ORDER BY generation DESC LIMIT 1").first();

/** `rows` (`{key, pos, <field>}` in key and pos order) as one list per key, indexed by pos. */
function listsOf(rows, field) {
  const lists = {};
  for (const row of rows) {
    const list = (lists[row.key] ??= []);
    if (row.pos !== list.length) throw new Error(`share table ${row.key} has no row at pos ${list.length}`);
    list.push(row[field]);
  }
  return lists;
}

/**
 * The tables D1 holds now. The generation is read before the rows: a load commits its rows before
 * its generation, so rows read after a generation are never fewer than that generation's. A
 * snapshot can hold more rows than its generation says, never fewer; rows of a load still being
 * written can hold a name without its gid, which `Tables.size` does not count as held.
 */
async function load(db) {
  const head = await latestLoad(db);
  const names = await db.prepare("SELECT key, pos, name FROM share_table_name ORDER BY key, pos").all();
  const gids = await db.prepare("SELECT key, pos, gid FROM share_table_gid ORDER BY key, pos").all();
  const tables = new Tables({
    version: head?.recognizer_version ?? null,
    names: listsOf(names.results, "name"),
    gids: listsOf(gids.results, "gid"),
  });
  return new Snapshot(head?.generation ?? 0, tables);
}

/**
 * The tables of one Worker isolate: read from D1 on first use and kept, and read again only when a
 * request meets a sid they do not hold and D1's generation has moved past theirs. A failed read is
 * not kept, so the next request reads again.
 */
export class TableSource {
  #memo = null;

  /** The kept snapshot, read from `db` on first use. */
  #snapshot(db) {
    return this.#memo ?? this.#remember(load(db));
  }

  #remember(pending) {
    this.#memo = pending;
    pending.catch(() => {
      if (this.#memo === pending) this.#memo = null;
    });
    return pending;
  }

  /** A snapshot newer than `seen`, read again from `db`, or null when D1's generation has not moved. */
  async #newer(db, seen) {
    const head = await latestLoad(db);
    if ((head?.generation ?? 0) <= seen.generation) return null;
    const fresh = await this.#remember(load(db));
    return fresh.generation > seen.generation ? fresh : null;
  }

  /** One request's copy of the tables. */
  async forRequest(db) {
    return new RequestTables(await this.#snapshot(db), (seen) => this.#newer(db, seen));
  }
}

/**
 * The tables one request reads, from one snapshot. `renew` replaces them with a newer snapshot when
 * D1 has one, once per request: a request that met a sid its tables lack tries once more, and a sid
 * still missing after that is answered as missing.
 */
export class RequestTables {
  #snapshot;
  #newer;
  #renewed = false;

  constructor(snapshot, newer) {
    this.#snapshot = snapshot;
    this.#newer = newer;
  }

  get tables() {
    return this.#snapshot.tables;
  }

  /** Whether the tables were replaced with a newer snapshot; false on every call after the first. */
  async renew() {
    if (this.#renewed) return false;
    this.#renewed = true;
    const fresh = await this.#newer(this.#snapshot);
    if (fresh === null) return false;
    this.#snapshot = fresh;
    return true;
  }
}

/**
 * `build(tables)` from one request's copy of `source`'s tables, built once more from a newer
 * snapshot when it throws TableLookupError and D1 has one.
 */
export async function withTables(source, db, build) {
  const copy = await source.forRequest(db);
  try {
    return build(copy.tables);
  } catch (error) {
    if (error instanceof TableLookupError && (await copy.renew())) return build(copy.tables);
    throw error;
  }
}
