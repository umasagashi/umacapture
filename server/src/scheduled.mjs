// The hourly run (`triggers.crons` in wrangler.jsonc): what a request leaves behind when it is cut off,
// and no later request of the same account comes to finish, is tidied here, and the deletion of every
// account being deleted goes on. One run is one Worker invocation, under the same limits as a request
// (B2_REQUESTS_PER_INVOCATION B2 requests, and the CPU time the Workers Paid plan gives an invocation),
// so every kind takes on a bounded amount and leaves the rest, still recorded in D1, for the next run.

import { continueAccountDeletions } from "./account_deletion.mjs";
import { clock } from "./api.mjs";
import { Bucket } from "./b2.mjs";
import { syncEnabled } from "./sync.mjs";
import { forgetDays } from "./sync_quota.mjs";
import { forgetLeftovers, hideLeftovers, showLeftovers, writeLeftovers } from "./sync_refs.mjs";

/**
 * What the hourly run takes on, one kind per row: `run` takes on what it can of that kind at the run's
 * clock (`clock`) with what is left of the run's one bucket (its B2 requests are counted across the
 * kinds), and leaves the rest recorded for the next run. The kinds run in order, each after the one
 * before has finished or failed. `sync` marks the kinds of file sync, which the sync switch stops; only
 * a kind that says `sync: false` runs while sync is switched off.
 */
const KINDS = [
  {
    // Shows what a request cut off left referenced and hidden: after a replacement's commit and before
    // it showed what a hide recorded after its look, or inside a hide that found its name referenced or
    // taken over. First, since B2's lifecycle deletes what stays hidden; what went past the six-day
    // boundary meanwhile it leaves hidden, gone.
    key: "shows",
    sync: true,
    run: (env, bucket, clk) => showLeftovers(env.DB, bucket, clk.now),
  },
  {
    // Hides what nothing references and no request is hiding: what a put stored and no replacement
    // referenced within SYNC_ABANDONED_AFTER, and what a replacement cut off between making a name
    // unreferenced and hiding it left; and hides again what a request left inside a hide or a show (or
    // B2 failed there), once abandoned. After the shows, so it hides nothing a show was owed.
    key: "hides",
    sync: true,
    run: (env, bucket, clk) => hideLeftovers(env.DB, bucket, clk.now),
  },
  {
    // Deletes what a request wrote under an account's prefix in B2 and left no row to account for: a
    // put cut off before its row, or a put or a hide that reached an account being deleted, deleted
    // since included. Last of sync's kinds that send B2 requests, since what it leaves costs storage,
    // not a record the user sees.
    key: "writes",
    sync: true,
    run: (env, bucket, clk) => writeLeftovers(env.DB, bucket, "a", clk.now),
  },
  {
    // Continues the deletion of the accounts being deleted, a step at a time. After the kinds of sync
    // that send B2 requests, so it takes only what they leave of the bucket, a whole step at a time.
    // Not a kind of sync: deleting an account goes on while sync is switched off, as DELETE /api/me
    // does, so what a deletion the day's share stopped left still goes.
    key: "deletions",
    sync: false,
    run: (env, bucket, clk) => continueAccountDeletions(env.DB, bucket, clk),
  },
  {
    // Deletes what a request wrote under an account's shared images (s/<account id>/) and left no share
    // to account for: a bundle put after its share was unshared or its account deleted, one put whose
    // share's row was never told, and one an unshare failed to delete. Not a kind of sync: neither the
    // sync switch nor the image switch stops it, since what it deletes is what a sharer withdrew. After
    // the deletions, which take a whole step at a time: what it leaves costs storage, and B2 does not
    // serve it, since the bundle's GET answers only for a share that records its bundle as stored.
    key: "share_writes",
    sync: false,
    run: (env, bucket, clk) => writeLeftovers(env.DB, bucket, "s", clk.now),
  },
  {
    // Deletes the rows of names gone past the six-day boundary that nothing references, a day after the
    // boundary: they answer as no row does, and B2's lifecycle deletes their versions. After the kinds
    // that read rows, and it takes no B2 request, so the ones before cannot leave it none.
    key: "forgets",
    sync: true,
    run: (env, bucket, clk) => forgetLeftovers(env.DB, clk.now),
  },
  {
    // Deletes the days of sync_daily no request reads any more.
    key: "days",
    sync: true,
    run: (env, bucket, clk) => forgetDays(env.DB, clk.now),
  },
];

/**
 * The scheduled handler's work at the Worker clock `now`. While sync is switched off (SYNC_ENABLED
 * "false") only the kinds that are not sync's run: the switch keeps sync from reaching B2, not account
 * deletion. A kind that fails does not stop the ones after it; the run then fails with the first
 * failure.
 */
export async function runScheduled(env, now) {
  const kinds = syncEnabled(env) ? KINDS : KINDS.filter((kind) => kind.sync === false);
  const clk = clock(now);
  const bucket = new Bucket(env, now);
  const failures = [];
  for (const kind of kinds) {
    try {
      await kind.run(env, bucket, clk);
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length > 0) throw failures[0];
}
