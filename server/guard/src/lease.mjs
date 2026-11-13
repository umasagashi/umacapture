// The expression of rule G, the zone's WAF block rule the guard alone writes. It carries three times:
//   Ep: every host not on the allow list is blocked from Ep on (production, and staging with it).
//   Es: every host other than production's and not on the allow list is blocked from Es on (staging).
//   Ea: production's dynamic paths (/r/, /u/, /api/) are blocked from Ea on (stage A).
// Ep and Es are UNIX seconds, 0 when closed. Ea is 0 while stage A is latched and EA_OFF otherwise.
//
// The rule's text is the only record of these values: the guard keeps no copy in D1 and reads the rule
// back on every run. formatLease writes the text, parseLease reads it back only when it is exactly
// what formatLease would write, and leaseExpression is formatLease with the range checks a write must
// pass.

/** What `decide()` returns for an environment whose lease is to stay as the rule holds it. */
export const KEEP = Symbol("keep");

const hostSet = (cfg) => `{${cfg.ALLOW_HOSTS.map((h) => JSON.stringify(h)).join(" ")}}`;

/** The rule's expression for the three times, with no check of their range. */
export function formatLease({ Ep, Es, Ea }, cfg) {
  const allow = hostSet(cfg);
  const prod = JSON.stringify(cfg.PRODUCTION_HOST);
  const ts = "http.request.timestamp.sec";
  const path = (p) => `starts_with(http.request.uri.path, ${JSON.stringify(p)})`;
  return (
    `(not http.host in ${allow} and ${ts} ge ${Ep})` +
    ` or (http.host ne ${prod} and not http.host in ${allow} and ${ts} ge ${Es})` +
    ` or (http.host eq ${prod} and ${ts} ge ${Ea} and (${path("/r/")} or ${path("/u/")} or ${path("/api/")}))`
  );
}

const INTEGER = "(0|[1-9][0-9]*)";
const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * The three times of `expr`, or null when `expr` is not exactly the text formatLease writes for them
 * (an edited rule). No range check: a past or far-future time is returned as it stands.
 */
export function parseLease(expr, cfg) {
  if (typeof expr !== "string") return null;
  const marker = "\u0000";
  const template = formatLease({ Ep: `${marker}Ep`, Es: `${marker}Es`, Ea: `${marker}Ea` }, cfg);
  const pattern = escapeRegExp(template).replace(new RegExp(`${marker}(Ep|Es|Ea)`, "g"), INTEGER);
  const m = new RegExp(`^${pattern}$`).exec(expr);
  if (m === null) return null;
  const [Ep, Es, Ea] = m.slice(1, 4).map(Number);
  if (![Ep, Es, Ea].every(Number.isSafeInteger)) return null;
  const values = { Ep, Es, Ea };
  return formatLease(values, cfg) === expr ? values : null;
}

/** Whether `x` is a lease time the guard may write at `nowSec`: 0, or a whole second after nowSec within D_S + WRITE_MARGIN_S. */
const writable = (x, nowSec, cfg) => x === 0 || (Number.isSafeInteger(x) && nowSec < x && x <= nowSec + cfg.D_S + cfg.WRITE_MARGIN_S);

/**
 * formatLease for a write at `nowSec`. Throws, so that the run writes nothing, when Ep or Es is neither 0
 * nor a time within (nowSec, nowSec + D_S + WRITE_MARGIN_S], or Ea is neither 0 nor EA_OFF. A time in
 * milliseconds always falls outside that range.
 */
export function leaseExpression({ Ep, Es, Ea }, nowSec, cfg) {
  if (!Number.isSafeInteger(nowSec)) throw new RangeError(`nowSec ${nowSec} is not whole seconds`);
  for (const [name, x] of [["Ep", Ep], ["Es", Es]]) {
    if (!writable(x, nowSec, cfg)) throw new RangeError(`${name} ${String(x)} is outside what may be written at ${nowSec}`);
  }
  if (Ea !== 0 && Ea !== cfg.EA_OFF) throw new RangeError(`Ea ${String(Ea)} is neither 0 nor EA_OFF`);
  return formatLease({ Ep, Es, Ea }, cfg);
}

/**
 * The value to write back for an environment whose lease is KEEP, from `cur`, the time the rule holds
 * (null when the rule could not be read): the same time while it may still be written, otherwise 0.
 * A time at or before nowSec means "closed" either way, and 0 is that state's one spelling.
 */
export const keptLease = (cur, nowSec, cfg) => (cur !== null && cur !== 0 && writable(cur, nowSec, cfg) ? cur : 0);
