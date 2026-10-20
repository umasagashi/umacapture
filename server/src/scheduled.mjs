// The hourly run (`triggers.crons` in wrangler.jsonc): what a request leaves behind when it is cut off,
// and no later request of the same account comes to finish, is tidied here. One run is one Worker
// invocation, under the same limits as a request (B2_REQUESTS_PER_INVOCATION B2 requests, and the CPU
// time the Workers Paid plan gives an invocation), so every kind takes on a bounded amount and leaves
// the rest, still recorded in D1, for the next run.

import { clock } from "./api.mjs";
import { Bucket } from "./b2.mjs";
import { syncEnabled } from "./sync.mjs";
import { forgetDays } from "./sync_quota.mjs";
import { forgetLeftovers, hideLeftovers, showLeftovers, writeLeftovers } from "./sync_refs.mjs";

/**
 * What the hourly run tidies, one kind per row: `run` takes on what it can of that kind with what is
 * left of the run's one bucket (its B2 requests are counted across the kinds), and leaves the rest
 * recorded for the next run. The kinds run in order, each after the one before has finished or failed.
 */
const KINDS = [
  {
    // Shows what a request cut off left referenced and hidden: after a replacement's commit and before
    // it showed what a hide recorded after its look, or inside a hide that found its name referenced or
    // taken over. First, since B2's lifecycle deletes what stays hidden; what went past the six-day
    // boundary meanwhile it leaves hidden, gone.
    key: "shows",
    run: (env, bucket, at) => showLeftovers(env.DB, bucket, at),
  },
  {
    // Hides what nothing references and no request is hiding: what a put stored and no replacement
    // referenced within SYNC_ABANDONED_AFTER, and what a replacement cut off between making a name
    // unreferenced and hiding it left; and hides again what a request left inside a hide or a show (or
    // B2 failed there), once abandoned. After the shows, so it hides nothing a show was owed.
    key: "hides",
    run: (env, bucket, at) => hideLeftovers(env.DB, bucket, at),
  },
  {
    // Deletes what a request wrote under an account's prefix in B2 and left no row to account for: a
    // put cut off before its row, or a put or a hide that reached an account being deleted, deleted
    // since included. Last, since what it leaves costs storage, not a record the user sees.
    key: "writes",
    run: (env, bucket, at) => writeLeftovers(env.DB, bucket, at),
  },
  {
    // Deletes the rows of names gone past the six-day boundary that nothing references, a day after the
    // boundary: they answer as no row does, and B2's lifecycle deletes their versions. After the kinds
    // that read rows, and it takes no B2 request, so the ones before cannot leave it none.
    key: "forgets",
    run: (env, bucket, at) => forgetLeftovers(env.DB, at),
  },
  {
    // Deletes the days of sync_daily no request reads any more.
    key: "days",
    run: (env, bucket, at) => forgetDays(env.DB, at),
  },
];

/**
 * The scheduled handler's work at the Worker clock `now`. Nothing runs while sync is switched off
 * (SYNC_ENABLED "false"): every kind is sync's, and the switch keeps sync from reaching B2. A kind that
 * fails does not stop the ones after it; the run then fails with the first failure.
 */
export async function runScheduled(env, now) {
  if (!syncEnabled(env)) return;
  const at = clock(now).now;
  const bucket = new Bucket(env, now);
  const failures = [];
  for (const kind of KINDS) {
    try {
      await kind.run(env, bucket, at);
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length > 0) throw failures[0];
}
