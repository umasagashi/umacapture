// Name tables the Worker resolves recognizer class numbers (sids) through.
//
// The tables live in D1 (migrations/0006_share_tables.sql): publishing a recognizer module set
// appends the rows its archive adds, so the Worker can name every sid of the module set served to
// users without being deployed again. A table read back from D1 has this shape:
//
//   {
//     "version": "<recognizer_version of the latest load, null while D1 holds none>",
//     "names": { "<labels.json key>": ["<name of sid 0>", "<name of sid 1>", ...], ... },
//     "gids":  { "<labels.json key>": [<gid of sid 0>, <gid of sid 1>, ...], ... },
//     "tags":  { "<labels.json key>": [[<tag of sid 0>, ...], [<tag of sid 1>, ...], ...], ... }
//   }
//
// `names` holds every labels.json key except campaign_field.name. `gids` holds only the keys an info
// table gives a gid column to (character.card, skill.name, factor.name, race_title.name); a key
// absent from `gids` has no gid, and the public JSON then carries the name alone. `tags` holds the
// info table's tags of the keys in TAG_KEYS (migrations/0007_share_table_tags.sql). Every list is
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

/**
 * The keys whose entries are held only with their tags. Tags reached D1 after the names and gids
 * (0007 came after 0006), so a key's tags cannot be told apart from absent by whether its rows
 * exist: D1 holding no tags for factor.name means the tags are not loaded yet, and its sids are not
 * held until they are, which makes a Worker that met them read D1 again.
 */
export const TAG_KEYS = Object.freeze([Keys.factor]);

/** A name table whose index is not the stored value itself. */
export class TableLookupError extends Error {}

export class Tables {
  constructor(raw) {
    this.version = raw.version;
    this.names = raw.names;
    this.gids = raw.gids;
    this.tagLists = raw.tags;
  }

  /**
   * How many entries table `key` holds: valid sids are 0 to size − 1. An entry is held only once
   * every column the key has is: its name, its gid when the key has a gid column, and its tags when
   * the key is one of TAG_KEYS. A load writes the names before the gids and the gids before the
   * tags, so tables read part way through it can hold a name whose gid or tags are not there yet;
   * that sid is not held until they are.
   */
  size(key) {
    const list = this.names[key];
    if (!list) throw new TableLookupError(`${key} is not in the tables`);
    let size = list.length;
    const gids = this.gids[key];
    if (gids) size = Math.min(size, gids.length);
    if (TAG_KEYS.includes(key)) size = Math.min(size, this.tagLists[key]?.length ?? 0);
    return size;
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

  /** The tags of `sid` in table `key`, one of TAG_KEYS. Throws for a sid the table does not hold. */
  tags(key, sid) {
    if (!TAG_KEYS.includes(key)) throw new Error(`${key} carries no tags`);
    this.name(key, sid);
    return this.tagLists[key][sid];
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
 * written can hold a name without its gid or tags, which `Tables.size` does not count as held.
 */
async function load(db) {
  const head = await latestLoad(db);
  const names = await db.prepare("SELECT key, pos, name FROM share_table_name ORDER BY key, pos").all();
  const gids = await db.prepare("SELECT key, pos, gid FROM share_table_gid ORDER BY key, pos").all();
  const tags = await db.prepare("SELECT key, pos, tags FROM share_table_tags ORDER BY key, pos").all();
  const tables = new Tables({
    version: head?.recognizer_version ?? null,
    names: listsOf(names.results, "name"),
    gids: listsOf(gids.results, "gid"),
    // Each row holds its tags as a JSON array.
    tags: listsOf(
      tags.results.map((row) => ({ ...row, tags: JSON.parse(row.tags) })),
      "tags",
    ),
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
