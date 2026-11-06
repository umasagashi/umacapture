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
export const ROUTES = [
  ["GET", "recordJson", new RegExp(`^/r/(${ID})\\.json$`)],
  ["GET", "recordPage", new RegExp(`^/r/(${ID})$`)],
  ["GET", "listJson", new RegExp(`^/u/(${ACCOUNT_ID})\\.json$`)],
  ["GET", "listPage", new RegExp(`^/u/(${ACCOUNT_ID})$`)],
  ["GET", "me", /^\/api\/me$/],
  ["DELETE", "deleteAccount", /^\/api\/me$/],
  ["POST", "meTrainer", /^\/api\/me\/trainers$/],
  ["POST", "share", /^\/api\/shares$/],
  ["PATCH", "shareView", new RegExp(`^/api/shares/(${ID})$`)],
  ["DELETE", "unshare", new RegExp(`^/api/shares/(${ID})$`)],
  ["GET", "myShares", /^\/api\/me\/shares$/],
  ["GET", "loginPage", /^\/api\/auth\/start$/],
  ["POST", "loginBegin", /^\/api\/auth\/begin$/],
  // The id is the provider's name; the callback refuses one that is not a provider.
  ["GET", "loginCallback", /^\/api\/auth\/callback\/([a-z]+)$/],
  ["POST", "loginClaim", /^\/api\/auth\/claim$/],
  ["POST", "logout", /^\/api\/auth\/logout$/],
  // File sync: every endpoint lives under /api/sync/, so the zone's WAF can tell them apart by prefix.
  // The id is an object name, the SHA-256 of its bytes.
  ["GET", "syncGeneration", /^\/api\/sync\/generation$/],
  ["GET", "syncGetSettings", /^\/api\/sync\/settings$/],
  ["PUT", "syncPutSettings", /^\/api\/sync\/settings$/],
  ["POST", "syncPutBodies", /^\/api\/sync\/bodies$/],
  ["POST", "syncGetBodies", /^\/api\/sync\/bodies\/get$/],
  ["POST", "syncHeld", /^\/api\/sync\/held$/],
  ["PUT", "syncPutImage", /^\/api\/sync\/images\/([0-9a-f]{64})$/],
  ["GET", "syncGetImage", /^\/api\/sync\/images\/([0-9a-f]{64})$/],
  ["POST", "syncPutPart", /^\/api\/sync\/parts$/],
  ["GET", "syncGetPart", /^\/api\/sync\/parts\/([0-9a-f]{64})$/],
  ["POST", "syncReplaceRoot", /^\/api\/sync\/root$/],
  ["GET", "syncGetRoot", /^\/api\/sync\/roots\/([0-9a-f]{64})$/],
];

// The paths a viewer opens as a page: /r/ or /u/ and one segment with no extension, whatever that
// segment is. A 404 on one of them is a page too; .json, .png and every other path keep the plain 404.
const PAGE_PATH = /^\/(r|u)\/[^/.]*$/;

/** "r" or "u" when a GET (or HEAD) of `pathname` asks for a public page, else null. */
export function pagePathKind(method, pathname) {
  if (method !== "GET" && method !== "HEAD") return null;
  return PAGE_PATH.exec(pathname)?.[1] ?? null;
}

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
