// The shape of every path the Worker answers. A path that matches none of these is answered 404
// before anything touches D1: a Worker with static assets is invoked for every path that matches
// no file, not only for the paths `run_worker_first` lists, so mistyped URLs and probes for
// non-existent ids land here too.

// Public ids: 10 lowercase Crockford base32 characters (no i, l, o, u).
export const ID_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";
const ID = "[0-9a-hjkmnp-tv-z]{10}";

// [method, name, pattern]. HEAD is accepted wherever GET is.
const ROUTES = [
  ["GET", "recordJson", new RegExp(`^/r/(${ID})\\.json$`)],
  ["GET", "recordPage", new RegExp(`^/r/(${ID})$`)],
  ["GET", "verifyPage", /^\/api\/verify$/],
  ["POST", "issueTicket", /^\/api\/tickets$/],
  ["POST", "publish", /^\/api\/records$/],
  ["POST", "lookup", /^\/api\/records\/lookup$/],
  ["DELETE", "withdraw", new RegExp(`^/api/records/(${ID})$`)],
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
