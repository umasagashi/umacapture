// Operators' takedowns of shares. An operator who decides a share must go writes one row to
// share_takedowns (migrations/0009) by hand: scope 'share' to take the whole share down, 'images' to take
// down only its images. The hourly run (`takedowns` in scheduled.mjs) carries each out with the code a
// sharer's own withdrawal runs, as the share's owner, so a takedown leaves what that withdrawal leaves:
// the totals, the account's count and the declared image bytes given back, and the bundle's versions
// deleted through the write ledger. No switch stops it, since what it removes is what must stop being
// served.

import { clock } from "./api.mjs";
import * as limits from "./limits.mjs";
import { REMOVE_BUNDLE_B2_REQUESTS, withdrawImages } from "./share_images.mjs";
import { unshare } from "./shares.mjs";
import { d1 } from "./sync.mjs";

/** What carries out a takedown of each scope for share `id` of account `owner`. */
const SCOPES = Object.freeze({ share: unshare, images: withdrawImages });

/**
 * The hourly run's takedowns at clock `now`: the orders not carried out yet, oldest first, up to
 * SHARE_TAKEDOWNS_PER_RUN and as many as `bucket` has room for. Each is carried out as the share's
 * owner, then marked done once nothing of its scope is left: the share's row for 'share', the share's
 * declared images for 'images'. An order whose scope is still there stays not done, for a later run:
 * one whose account is being deleted (the withdrawal changes nothing then, and the deletion removes the
 * share in a later step), or whose D1 work failed.
 */
export async function carryOutTakedowns(env, bucket, now) {
  const orders = await d1(() =>
    env.DB.prepare(
      `SELECT t.share_id, t.scope, r.owner_id FROM share_takedowns t LEFT JOIN records r ON r.id = t.share_id
       WHERE t.done_at IS NULL ORDER BY t.ordered_at, t.share_id, t.scope LIMIT ?1`,
    )
      .bind(limits.SHARE_TAKEDOWNS_PER_RUN)
      .all(),
  );
  for (const order of orders.results) {
    if (bucket.sent + REMOVE_BUNDLE_B2_REQUESTS > limits.B2_REQUESTS_PER_INVOCATION) return;
    if (order.owner_id !== null) await SCOPES[order.scope](env, bucket, order.share_id, order.owner_id, now);
    await d1(() =>
      env.DB.prepare(
        `UPDATE share_takedowns SET done_at = ?3 WHERE share_id = ?1 AND scope = ?2 AND done_at IS NULL
           AND NOT EXISTS (SELECT 1 FROM records WHERE id = ?1 AND (?2 = 'share' OR images_name IS NOT NULL))`,
      )
        .bind(order.share_id, order.scope, clock(now).now)
        .run(),
    );
  }
}
