// The session's own account: GET /api/me and POST /api/me/trainers.

import { AccountDeleting, clock, envelope, fail, json, readJson, SessionRequired } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { readAccount, registerTrainer } from "./store.mjs";

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
