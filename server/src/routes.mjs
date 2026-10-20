// The shape of every path the Worker answers. A path that matches none of these is answered 404
// before anything touches D1: a Worker with static assets is invoked for every path that matches
// no file, not only for the paths `run_worker_first` lists, so mistyped URLs and probes for
// non-existent ids land here too.

// Public ids: 10 lowercase Crockford base32 characters (no i, l, o, u).
export const ID_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";
const ID = "[0-9a-hjkmnp-tv-z]{10}";
// Account ids: 16 characters of the same alphabet, so their length alone tells them from record ids.
const ACCOUNT_ID = "[0-9a-hjkmnp-tv-z]{16}";

// [method, name, pattern]. HEAD is accepted wherever GET is.
const ROUTES = [
  ["GET", "recordJson", new RegExp(`^/r/(${ID})\\.json$`)],
  ["GET", "recordPage", new RegExp(`^/r/(${ID})$`)],
  ["GET", "listJson", new RegExp(`^/u/(${ACCOUNT_ID})\\.json$`)],
  ["GET", "listPage", new RegExp(`^/u/(${ACCOUNT_ID})$`)],
  ["GET", "me", /^\/api\/me$/],
  ["DELETE", "deleteAccount", /^\/api\/me$/],
  ["POST", "meTrainer", /^\/api\/me\/trainers$/],
  ["POST", "share", /^\/api\/shares$/],
  ["DELETE", "unshare", new RegExp(`^/api/shares/(${ID})$`)],
  ["GET", "myShares", /^\/api\/me\/shares$/],
  ["GET", "loginPage", /^\/api\/auth\/start$/],
  ["POST", "loginBegin", /^\/api\/auth\/begin$/],
  // The id is the provider's name; the callback refuses one that is not a provider.
  ["GET", "loginCallback", /^\/api\/auth\/callback\/([a-z]+)$/],
  ["POST", "loginClaim", /^\/api\/auth\/claim$/],
  ["POST", "logout", /^\/api\/auth\/logout$/],
];

/** `{name, id}` for a recognised route (`id` only on routes that carry one), or null. */
export function matchRoute(method, pathname) {
  const asMethod = method === "HEAD" ? "GET" : method;
  for (const [routeMethod, name, pattern] of ROUTES) {
    if (routeMethod !== asMethod) continue;
    const m = pattern.exec(pathname);
    if (m) return m[1] === undefined ? { name } : { name, id: m[1] };
  }
  return null;
}
