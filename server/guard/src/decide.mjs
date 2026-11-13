// The decision of one run (pure): from the state the run read and what it measured, the state changes
// to commit and the lease each environment's part of rule G should carry.
//
// The guard never takes an environment out of 'tripped': only the operator does. A run that cannot
// measure changes nothing but the billing period's limit and extends nothing; the rule then closes on
// its own as the lease it holds runs out.

import { KEEP } from "./lease.mjs";
import { periodStart } from "./time.mjs";

const ENVS = Object.freeze(["production", "staging"]);

/**
 * `state.env` holds the two guard_env rows as read. `read` is `{ tp, spend, hold }`: t_p (null when not
 * measured), the spend per environment in micro-USD (null when not measured), and `hold`, false only
 * when nothing in this run's reading forbids an extension (a gap recorded, catching up, a stalled ledger);
 * anything but false holds.
 *
 * Returns `{ measurable, transitions, env, lease }`: `transitions` are the changes to commit, one per
 * changed environment (`{ env, gen, set }`, `gen` being the value read, for the compare-and-set), `env`
 * the rows after them, and `lease` the times `{ Ep, Es, Ea }` for rule G, where Ep and Es are 0 (close),
 * a time (extend to it), or KEEP (leave the rule's value).
 */
export function decide({ state, read, nowSec, cfg }) {
  const measurable = read.tp !== null && read.spend !== null;
  const pStart = periodStart(nowSec, cfg);
  const env = {};
  const transitions = [];
  for (const e of ENVS) {
    const s = { ...state.env[e] };
    const set = {};
    const change = (fields) => {
      Object.assign(s, fields);
      Object.assign(set, fields);
    };
    // 0) A new billing period: the limit goes back to the base (mode, 'tripped' included, stays).
    if (pStart > s.limit_period_start_s) change({ limit_micros: s.base_limit_micros, limit_period_start_s: pStart });
    if (measurable) {
      const spent = read.spend[e];
      // 1) Just opened: the operator's allowance becomes this period's limit on top of what is spent.
      if (s.mode === "open" && s.pending_allowance_micros !== null) {
        change({ limit_micros: spent + s.pending_allowance_micros, pending_allowance_micros: null });
      }
      // 2) The budget: at the limit the environment trips; production latches stage A at warn_permille of it.
      // The limits and the share are guard_env state, set by the migration and changed by the operator.
      if (s.mode === "open" && s.limit_micros !== null && spent >= s.limit_micros) {
        change({ mode: "tripped", tripped_at_s: nowSec, trip_reason: "budget", spent_at_trip_micros: spent });
      } else if (
        e === "production" &&
        s.mode === "open" &&
        !s.stage_a &&
        s.limit_micros !== null &&
        spent * 1000 >= s.limit_micros * s.warn_permille
      ) {
        change({ stage_a: 1 });
      }
      // 3) Staging's test window is over. Production's open_until_s is the reach of billing evidence, not a
      // window: past it production stays open and its lease simply is not extended.
      if (e === "staging" && s.mode === "open" && s.open_until_s !== null && nowSec >= s.open_until_s) change({ mode: "closed" });
    }
    if (Object.keys(set).length > 0) {
      change({ updated_at_s: nowSec });
      transitions.push({ env: e, gen: state.env[e].gen, set });
    }
    env[e] = s;
  }

  const lease = (e) => {
    const s = env[e];
    if (s.mode !== "open") return 0; // close, always written
    if (!measurable || read.hold !== false || s.limit_micros === null) return KEEP; // extend nothing
    const until = Math.min(read.tp + cfg.D_S, s.open_until_s ?? Infinity);
    return until > nowSec ? until : KEEP; // a time already past is not written
  };
  return {
    measurable,
    transitions,
    env,
    lease: { Ep: lease("production"), Es: lease("staging"), Ea: env.production.stage_a ? 0 : cfg.EA_OFF },
  };
}
