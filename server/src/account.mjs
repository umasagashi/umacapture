// The session's own account: GET /api/me, GET /api/me/usage and POST /api/me/trainers.

import { AccountDeleting, clock, envelope, fail, json, readJson, SessionRequired } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { readAccount, registerTrainer } from "./store.mjs";
import { d1 } from "./sync.mjs";
import { usage } from "./sync_quota.mjs";

// The form the app's trainer ids take (a lowercase UUID).
const TRAINER_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * GET /api/me: `{account_id, list_url, share_count, shares_remaining, trainer_ids, deleting}` of the
 * session's account. `shares_remaining` is what ACCOUNT_SHARE_CAP still allows.
 */
export async function getMe(request, env, now) {
  const session = await requireSession(request, env, clock(now).now);
  const account = await readAccount(env.DB, session.accountId);
  // A session outliving its account would be one a deletion left behind: it authorises nothing.
  if (account === null) throw new SessionRequired();
  return json(200, {
    account_id: session.accountId,
    list_url: `${env.PUBLIC_ORIGIN}/u/${session.accountId}`,
    share_count: account.shareCount,
    shares_remaining: Math.max(0, limits.ACCOUNT_SHARE_CAP - account.shareCount),
    trainer_ids: account.trainerIds,
    deleting: account.deleting,
  });
}

/**
 * GET /api/me/usage: what the session's account uses of its per-account caps, each beside its cap:
 * `{shares: {count, cap}, sync: {stored_bytes, bytes_cap, records, records_cap}}`. `shares` counts the
 * account's shares against ACCOUNT_SHARE_CAP. `sync.stored_bytes` and `sync.records` are what
 * `admitGrowth` and `recordsRefusal` hold against ACCOUNT_SYNC_BYTES_CAP and ACCOUNT_SYNC_RECORDS_CAP:
 * the bytes the current root references, and the records its parts list; both 0 before a first sync.
 * Bytes waiting for B2's lifecycle (ACCOUNT_SYNC_HIDDEN_BYTES_CAP) are left out. Like GET /api/me it
 * is admitted against no daily limit, and it answers whether sync is switched on or not: it reports
 * what is stored, and switching sync off stores nothing new.
 */
export async function getUsage(request, env, now) {
  const at = clock(now).now;
  const session = await requireSession(request, env, at);
  const account = await readAccount(env.DB, session.accountId);
  if (account === null) throw new SessionRequired();
  const sync = await d1(() => usage(env.DB, session.accountId, at));
  return json(200, {
    shares: { count: account.shareCount, cap: limits.ACCOUNT_SHARE_CAP },
    sync: {
      stored_bytes: sync.stored,
      bytes_cap: limits.ACCOUNT_SYNC_BYTES_CAP,
      records: sync.records,
      records_cap: limits.ACCOUNT_SYNC_RECORDS_CAP,
    },
  });
}

/**
 * POST /api/me/trainers `{trainer_id}`: registers this device's trainer id under the session's
 * account; 200 also when it was registered before. An account holding ACCOUNT_TRAINERS_CAP of them
 * is refused another with 409 trainer_limit, and an account being deleted any with 409 account_deleting.
 */
export async function postTrainer(request, env, now) {
  const session = await requireSession(request, env, clock(now).now);
  const { trainer_id: trainerId } = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["trainer_id"]);
  if (typeof trainerId !== "string" || !TRAINER_ID.test(trainerId)) throw new InvalidPayload("trainer_id");
  const outcome = await registerTrainer(env.DB, session.accountId, trainerId, limits.ACCOUNT_TRAINERS_CAP);
  if (outcome === "gone") throw new SessionRequired();
  if (outcome === "deleting") throw new AccountDeleting();
  if (outcome === "limit") return fail(409, "trainer_limit");
  return json(200, { trainer_id: trainerId });
}
