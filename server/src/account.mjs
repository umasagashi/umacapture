// The session's own account: GET /api/me, GET /api/me/usage, POST /api/me/trainers and PUT /api/me/profile.

import { AccountDeleting, clock, envelope, fail, json, readJson, SessionRequired, sharingEnabled } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { readAccount, registerTrainer, writeProfile } from "./store.mjs";
import { d1 } from "./sync.mjs";
import { usage } from "./sync_quota.mjs";
import { canonicalGameTrainerId, canonicalText, textWriteQuota, textWriteRefused } from "./user_text.mjs";

// The form the app's trainer ids take (a lowercase UUID).
const TRAINER_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** A public profile (`{trainerName, gameTrainerId}`) as the API carries it. */
const profileJson = (profile) => ({ trainer_name: profile.trainerName, game_trainer_id: profile.gameTrainerId });

/**
 * GET /api/me: `{account_id, list_url, share_count, shares_remaining, trainer_ids, deleting, profile}` of
 * the session's account. `shares_remaining` is what ACCOUNT_SHARE_CAP still allows. `profile` is the
 * account's public profile `{trainer_name, game_trainer_id}` (PUT /api/me/profile), each null when not
 * written.
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
    profile: profileJson(account.profile),
  });
}

/** The `previous` of a profile body: the profile the editor started from, compared as it is. */
function previousProfile(value) {
  let previous;
  try {
    previous = envelope(value, ["trainer_name", "game_trainer_id"]);
  } catch (error) {
    if (error instanceof InvalidPayload) throw new InvalidPayload(error.field === "body" ? "previous" : `previous.${error.field}`);
    throw error;
  }
  for (const key of ["trainer_name", "game_trainer_id"]) {
    if (previous[key] !== null && typeof previous[key] !== "string") throw new InvalidPayload(`previous.${key}`);
  }
  return { trainerName: previous.trainer_name, gameTrainerId: previous.game_trainer_id };
}

/**
 * PUT /api/me/profile `{trainer_name, game_trainer_id, previous: {trainer_name, game_trainer_id}}`:
 * replaces the session's account's public profile, which every page of its shares and its list show
 * (never the OG card, a page's description or the import). Each field is a string or null (null, or
 * nothing left once trimmed, removes it): `trainer_name` up to MAX_TRAINER_NAME code points
 * (`canonicalText`), `game_trainer_id` 9 or 12 digits, which may be grouped with spaces, hyphens or
 * commas and are stored without them (`canonicalGameTrainerId`). `previous` is the profile the editor
 * started from, as GET /api/me or this endpoint answered it; the write is made only while the profile is
 * still `previous` in both fields.
 *
 * Answers 200 `{trainer_name, game_trainer_id}` with the canonical forms stored; 409 changed `{profile}`
 * with what it is now, having written nothing; 400 invalid_payload `{field}`; 409 account_deleting;
 * 429 daily_limit `{scope}` with a Retry-After to the next UTC day when the account ("account") or every
 * account together ("service") has used up the day's text writes, which this endpoint and
 * PUT /api/shares/<id>/tagline count together (ACCOUNT_TEXT_WRITES_PER_DAY, TEXT_WRITES_PER_DAY), only
 * a 200 counting. Not charged against any byte budget. While SHARING_ENABLED is "false" it takes only a write that
 * publishes nothing new: each field removed or left as it is. Any other is 503 sharing_paused.
 */
export async function putProfile(request, env, now) {
  const at = clock(now);
  const session = await requireSession(request, env, at.now);
  const body = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["trainer_name", "game_trainer_id", "previous"]);
  const profile = {
    trainerName: canonicalText(body.trainer_name, "trainer_name", limits.MAX_TRAINER_NAME),
    gameTrainerId: canonicalGameTrainerId(body.game_trainer_id, "game_trainer_id"),
  };
  const previous = previousProfile(body.previous);
  const publishes = (key) => profile[key] !== null && profile[key] !== previous[key];
  if (!sharingEnabled(env) && (publishes("trainerName") || publishes("gameTrainerId"))) return fail(503, "sharing_paused");
  const outcome = await writeProfile(env.DB, session.accountId, profile, previous, textWriteQuota(at));
  if (outcome.status === "gone") throw new SessionRequired();
  if (outcome.status === "deleting") throw new AccountDeleting();
  if (outcome.status === "limit") return textWriteRefused(outcome.scope, at);
  if (outcome.status === "changed") return fail(409, "changed", { profile: profileJson(outcome.profile) });
  return json(200, profileJson(profile));
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
