// The guard Worker's entry: the cron handler. It builds the run's outside calls on fetch and hands them
// to runGuard (run.mjs), which reaches nothing else.
//
// Bindings (wrangler.guard.jsonc and secrets):
//   GUARD_DB            the guard's D1 database
//   GUARD_CF_TOKEN      secret: the token for GraphQL Analytics and for reading and writing rule G; the
//                       calls need Account Analytics Read and Zone WAF Edit (umacapture.com)
//   GUARD_BILL_TOKEN    secret: the token for the Billable Usage API; the call needs Account Billing Read
//   Each call reads only its own secret, so the two may hold different tokens. Both hold one and the
//   same user API token, which carries all three permissions (docs/web-deploy.md, "The guard's token").
//   GUARD_ACCOUNT_ID    var: the account GraphQL and Billable Usage are read for
//   GUARD_ZONE_ID       var: the zone rule G lives in
//   GUARD_SENTRY_DSN    var: where notifications go; empty sends none (each stays unconfirmed)
// A missing token or id makes the calls that need it fail, which every reader takes as "could not be
// read": nothing is extended and the rule closes when its lease runs out.

import { CFG } from "./config.mjs";
import { runGuard } from "./run.mjs";
import { sentrySender, sentrySink } from "./sentry.mjs";

const API = "https://api.cloudflare.com/client/v4";

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");

/** A JSON call to the Cloudflare API with `token`, abandoned after CALL_TIMEOUT_MS. Throws when it cannot be made or answered. */
async function cfCall(token, { method, path, body }) {
  if (typeof token !== "string" || token === "") throw new Error("no token");
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(CFG.CALL_TIMEOUT_MS),
  });
  let parsed = null;
  try {
    parsed = await res.json();
  } catch {
    parsed = null;
  }
  return { status: res.status, body: parsed, retryAfter: res.headers.get("Retry-After") };
}

const needs = (value, name) => {
  if (typeof value !== "string" || value === "") throw new Error(`${name} is not set`);
  return value;
};

export default {
  async scheduled(controller, env) {
    const scheduledMs = controller.scheduledTime;
    const nowSec = Math.floor(Date.now() / 1000);
    const result = await runGuard({
      db: env.GUARD_DB,
      cfg: CFG,
      nowSec,
      scheduledMs,
      clock: () => Date.now(),
      runId: `${scheduledMs}-${hex(crypto.getRandomValues(new Uint8Array(8)))}`,
      accountId: env.GUARD_ACCOUNT_ID,
      zoneId: env.GUARD_ZONE_ID,
      graphql: (body) => {
        needs(env.GUARD_ACCOUNT_ID, "GUARD_ACCOUNT_ID");
        return cfCall(env.GUARD_CF_TOKEN, { method: "POST", path: "/graphql", body });
      },
      cf: (req) => {
        needs(env.GUARD_ZONE_ID, "GUARD_ZONE_ID");
        return cfCall(env.GUARD_CF_TOKEN, req);
      },
      fetchBill: (path) => {
        needs(env.GUARD_ACCOUNT_ID, "GUARD_ACCOUNT_ID");
        return cfCall(env.GUARD_BILL_TOKEN, { method: "GET", path });
      },
      send: sentrySender(sentrySink(env.GUARD_SENTRY_DSN), { environment: "guard", timeoutMs: CFG.CALL_TIMEOUT_MS }),
    });
    // The run's outcome in the Worker's log: what ended it early, or the decision, never a response's rows.
    console.log(
      JSON.stringify({
        ended: result.ended,
        tp: result.read?.tp ?? null,
        measurable: result.plan?.measurable ?? null,
        committed: result.committed ?? null,
        rules: result.cls?.kind ?? null,
        write: result.conv?.action ?? null,
        bill: result.bill?.verdict ?? null,
      }),
    );
  },
};
