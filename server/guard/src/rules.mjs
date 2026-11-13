// Reading and writing rule G in the zone's custom-rules entry point.
//
// The guard keeps no model of the rule in D1: every run GETs the entry point and takes what it reads as
// the truth. Its own rule is the one whose description starts with RULE_MARK_PREFIX. With exactly one such
// rule the guard rewrites it when it has to; with none it creates one (after recording the attempt, and
// not again within CREATE_HOLD_S); with two or more it writes nothing and lets every one of them run out.
// A POST or PATCH answer is used only to record a failure (and a 429's Retry-After): whether a write took
// effect is what the next run's GET shows, so losing an answer changes no later decision.
//
// The guard never deletes a rule, and never creates or replaces the entry point itself (a PUT replaces
// every rule of the phase).

import { KEEP, keptLease, leaseExpression, leaseHorizonS, parseLease } from "./lease.mjs";

/** The description the guard writes on rule G; RULE_MARK_PREFIX is what identifies it. */
export const RULE_MARK = "umacapture-guard lease v1 — written by the guard Worker only";
export const RULE_MARK_PREFIX = "umacapture-guard lease";

const PHASE = "http_request_firewall_custom";
/** The entry point of the custom-rules phase. */
export const entrypointPath = (zoneId) => `/zones/${zoneId}/rulesets/phases/${PHASE}/entrypoint`;

const isObject = (x) => x !== null && typeof x === "object";

/**
 * The GET of the entry point, classified. `answer` is `{ status, body }` (null when the call failed).
 *  - `{ kind: "missing" }`: 404 with Cloudflare's "no entry point" error (code 10003).
 *  - `{ kind: "unreadable" }`: any other status, `success` not true, or a body of another shape.
 *  - `{ kind: "rules", rulesetId, count, ... }`: `count` rules carry the mark. With exactly one, `rule` is
 *    it, `first`/`shapeOk` whether it is first and enabled with action block, `cur` its parsed times (null
 *    when the expression is not exactly what the guard writes), and `protecting` whether it is in the
 *    protecting form: shapeOk, cur readable, and Ep and Es both at most nowSec + D_S + WRITE_MARGIN_S.
 * An entry point whose answer omits `rules` holds none.
 */
export function classifyRules(answer, nowSec, cfg) {
  if (!isObject(answer)) return { kind: "unreadable" };
  const { status, body } = answer;
  if (status === 404 && isObject(body) && Array.isArray(body.errors) && body.errors.some((e) => e?.code === 10003)) return { kind: "missing" };
  if (status !== 200 || !isObject(body) || body.success !== true) return { kind: "unreadable" };
  const r = body.result;
  if (!isObject(r) || typeof r.id !== "string" || r.id === "") return { kind: "unreadable" };
  const rules = r.rules === undefined ? [] : r.rules;
  if (!Array.isArray(rules) || !rules.every((x) => isObject(x) && typeof x.id === "string")) return { kind: "unreadable" };
  const ours = [];
  rules.forEach((x, index) => {
    if (typeof x.description === "string" && x.description.startsWith(RULE_MARK_PREFIX)) ours.push({ rule: x, index });
  });
  if (ours.length !== 1) return { kind: "rules", rulesetId: r.id, count: ours.length, rule: null, cur: null, protecting: false };
  const { rule, index } = ours[0];
  const cur = parseLease(rule.expression, cfg);
  const shapeOk = index === 0 && rule.enabled === true && rule.action === "block";
  const bound = nowSec + leaseHorizonS(cfg);
  const protecting = shapeOk && cur !== null && cur.Ep <= bound && cur.Es <= bound;
  return { kind: "rules", rulesetId: r.id, count: 1, rule, first: index === 0, shapeOk, cur, protecting };
}

/**
 * The times to write, from the decision's lease (`{ Ep, Es, Ea }`, Ep and Es being 0, a time or KEEP), the
 * times the rule holds (`cur`, null when unreadable or absent) and the environments' state after the
 * decision (`env`, for open_until_s). KEEP keeps the rule's time while it may still be written, else 0. A
 * time is never lowered below the rule's own (still writable) time, and never written past the
 * environment's open_until_s; a time that would then lie at or before nowSec is 0.
 */
export function wantLease(lease, cur, env, nowSec, cfg) {
  const one = (x, held, openUntil) => {
    if (x === 0) return 0;
    const kept = keptLease(held, nowSec, cfg);
    const t = Math.min(x === KEEP ? kept : Math.max(x, kept), openUntil ?? Infinity);
    return t > nowSec ? t : 0;
  };
  return {
    Ep: one(lease.Ep, cur?.Ep ?? null, env.production.open_until_s),
    Es: one(lease.Es, cur?.Es ?? null, env.staging.open_until_s),
    Ea: lease.Ea,
  };
}

/**
 * Whether the one rule G (`cls.count === 1`) must be rewritten to carry `want`: it is not in the protecting
 * form, a time that should be 0 is not, Ea differs, or a time moves forward by RENEW_STEP_S or more.
 */
export function patchNeeded(cls, want, cfg) {
  if (!cls.protecting) return true;
  const { cur } = cls;
  if ((want.Ep === 0 && cur.Ep !== 0) || (want.Es === 0 && cur.Es !== 0) || want.Ea !== cur.Ea) return true;
  return want.Ep - cur.Ep >= cfg.RENEW_STEP_S || want.Es - cur.Es >= cfg.RENEW_STEP_S;
}

/**
 * The body of a POST or PATCH of rule G: every field, and `position: { before: "" }` (first in the phase)
 * unless the rule is already first — the rulesets API refuses that position for a rule already at the top
 * (400, code 20011) and changes nothing.
 */
const ruleBody = (expression, alreadyFirst) => {
  const body = { action: "block", expression, description: RULE_MARK, enabled: true };
  return alreadyFirst ? body : { ...body, position: { before: "" } };
};

/** Whether a management API answer is a success (200 with `success: true`). */
const succeeded = (answer) => isObject(answer) && answer.status === 200 && isObject(answer.body) && answer.body.success === true;

/** The seconds a 429 asks to wait: its Retry-After when that is a whole number of seconds, else one cell. */
const retryAfterS = (answer, cfg) => {
  const n = Number(answer?.retryAfter);
  return Number.isSafeInteger(n) && n > 0 ? n : cfg.CELL_S;
};

/** Records a 429's Retry-After as api_backoff_until_s. Returns whether the answer was a 429. */
export async function noteBackoff(db, answer, nowSec, cfg) {
  if (answer?.status !== 429) return false;
  await db
    .prepare("UPDATE guard_health SET api_backoff_until_s = max(coalesce(api_backoff_until_s, 0), ?1) WHERE id = 1")
    .bind(nowSec + retryAfterS(answer, cfg))
    .run()
    .catch(() => null);
  return true;
}

/** Records a failed POST or PATCH in last_patch_error (and a 429 as backoff). Returns the failure, or null on success. */
async function noteWrite(db, method, answer, nowSec, cfg) {
  if (succeeded(answer)) return null;
  const status = isObject(answer) && Number.isInteger(answer.status) ? answer.status : 0;
  await db
    .prepare("UPDATE guard_health SET last_patch_error = ?1 WHERE id = 1")
    .bind(`${method} ${status} at ${nowSec}`)
    .run()
    .catch(() => null);
  const backoff = await noteBackoff(db, answer, nowSec, cfg);
  return { status, backoff };
}

/**
 * Brings rule G to the decision, writing at most one POST or PATCH. Called only for an armed guard whose
 * GET was read (`cls.kind === "rules"`) and whose decision may be written. `call({ method, path, body })`
 * reaches the management API and returns `{ status, body, retryAfter }` (it may throw: a lost answer).
 * `health` is guard_health as the run read it.
 *
 * Returns `{ action, failure, wrote }`: action "none" (nothing to write, two or more rules, or the attempt
 * record could not be written), "hold" (no rule, an attempt within CREATE_HOLD_S), "refused" (the times
 * failed the write check), "post" or "patch"; `failure` is `{ status, backoff }` when the write failed, else
 * null; `wrote` is the lease `{ Ep, Es, Ea }` a POST or PATCH carried when the API answered it a success,
 * else null (no write, a failure, or a lost answer).
 */
export async function converge(db, call, { zoneId, cls, lease, env, health, nowSec, cfg }) {
  if (cls.count >= 2) return { action: "none", failure: null, wrote: null };
  if (cls.count === 0) {
    const attempt = health.create_attempt_s;
    if (attempt !== null && nowSec - attempt <= cfg.CREATE_HOLD_S) return { action: "hold", failure: null, wrote: null };
    const want = wantLease(lease, null, env, nowSec, cfg);
    let expression;
    try {
      expression = leaseExpression(want, nowSec, cfg);
    } catch {
      return { action: "refused", failure: null, wrote: null };
    }
    // The attempt is recorded first: a run that cannot record it does not create.
    const claimed = await db
      .prepare("UPDATE guard_health SET create_attempt_s = ?1 WHERE id = 1 AND create_attempt_s IS ?2")
      .bind(nowSec, attempt)
      .run()
      .then((r) => r.meta.changes === 1)
      .catch(() => false);
    if (!claimed) return { action: "none", failure: null, wrote: null };
    const answer = await call({ method: "POST", path: `/zones/${zoneId}/rulesets/${cls.rulesetId}/rules`, body: ruleBody(expression, false) }).catch(() => null);
    const failure = await noteWrite(db, "POST", answer, nowSec, cfg);
    return { action: "post", failure, wrote: failure === null ? want : null };
  }
  if (health.create_attempt_s !== null) {
    await db.prepare("UPDATE guard_health SET create_attempt_s = NULL WHERE id = 1").run().catch(() => null);
  }
  const want = wantLease(lease, cls.cur, env, nowSec, cfg);
  if (!patchNeeded(cls, want, cfg)) return { action: "none", failure: null, wrote: null };
  let expression;
  try {
    expression = leaseExpression(want, nowSec, cfg);
  } catch {
    return { action: "refused", failure: null, wrote: null };
  }
  const path = `/zones/${zoneId}/rulesets/${cls.rulesetId}/rules/${cls.rule.id}`;
  const answer = await call({ method: "PATCH", path, body: ruleBody(expression, cls.first) }).catch(() => null);
  const failure = await noteWrite(db, "PATCH", answer, nowSec, cfg);
  return { action: "patch", failure, wrote: failure === null ? want : null };
}

/**
 * The observation of the GET in guard_health.rule_seen_since_s: the first time the rule was seen in the
 * protecting form, kept while it stays so and reset to NULL on any GET that shows otherwise (no entry
 * point, no rule, two rules, or one not in the protecting form). An unreadable GET shows nothing either
 * way and changes nothing.
 */
export async function observeRule(db, health, cls, nowSec) {
  if (cls.kind === "unreadable") return;
  const protecting = cls.kind === "rules" && cls.protecting;
  if (protecting && health.rule_seen_since_s === null) {
    await db.prepare("UPDATE guard_health SET rule_seen_since_s = ?1 WHERE id = 1 AND rule_seen_since_s IS NULL").bind(nowSec).run().catch(() => null);
  } else if (!protecting && health.rule_seen_since_s !== null) {
    await db.prepare("UPDATE guard_health SET rule_seen_since_s = NULL WHERE id = 1").run().catch(() => null);
  }
}
