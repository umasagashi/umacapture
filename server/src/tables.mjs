// Name tables the Worker resolves recognizer class numbers (sids) through.
//
// The tables are generated from the module set served to users (tool/cloudflare/build_share_tables.py
// writes src/tables.generated.json, which is not tracked: it carries game text). Shape:
//
//   {
//     "version": "<recognizer_version of the module set>",
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

  /** How many entries table `key` holds: valid sids are 0 to size − 1. */
  size(key) {
    const list = this.names[key];
    if (!list) throw new TableLookupError(`${key} is not in the tables`);
    return list.length;
  }

  /** The name stored at `index` of table `key`. Throws for an index the table does not hold. */
  name(key, index) {
    const list = this.names[key];
    if (!list || !Number.isInteger(index) || index < 0 || index >= list.length) {
      throw new TableLookupError(`${key}[${index}] is not in the tables`);
    }
    return list[index];
  }

  /** `{gid, name}` when the key has a gid column, `{name}` otherwise. */
  label(key, sid) {
    const name = this.name(key, sid);
    const gids = this.gids[key];
    return gids ? { gid: gids[sid], name } : { name };
  }
}
