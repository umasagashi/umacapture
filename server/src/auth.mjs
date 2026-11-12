// The login endpoints (start page, begin, callback, claim), logout, and the session check of every
// endpoint that needs one. A login is identified by `h`, the SHA-256 of a secret only the app holds;
// everything the server keeps about a login is a row in `logins`, and about a session a row in
// `sessions`.

import {
  AccountDeleting,
  BEARER,
  clock,
  envelope,
  fail,
  isTurnstileToken,
  json,
  noContent,
  readJson,
  readText,
  SessionRequired,
  sharingEnabled,
  TooLarge,
  untilTomorrow,
} from "./api.mjs";
import * as limits from "./limits.mjs";
import { loginFailureResponse, loginPageResponse } from "./login_page.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { clientId, clientSecret, identityKey, isProvider, PROVIDERS, redirectUri } from "./providers.mjs";
import { base64url, hexBytes, isLoginSecret, isSecretHash, newAccountId, randomSecret, sha256, toHex } from "./secrets.mjs";
import {
  beginLogin,
  claimLogin,
  completeLogin,
  deleteSession,
  findLogin,
  findSession,
  findStartedLogin,
  sweepLogins,
  Unavailable,
} from "./store.mjs";
import { verifyTurnstile } from "./turnstile.mjs";

const PORT = /^[1-9][0-9]{3,4}$/;
const FORM = "application/x-www-form-urlencoded";
// Google documents no bound on an authorization code; this bounds what a callback reads.
const MAX_CODE = 2_048;

/** `value` as a loopback port (1024 to 65535), null when absent, or undefined when malformed. */
function loopbackPort(value) {
  if (value === null) return null;
  if (!PORT.test(value)) return undefined;
  const port = Number(value);
  return port >= 1024 && port <= 65535 ? port : undefined;
}

/** `{h, p, port}` read from `params` (a URLSearchParams), or null when any is malformed. */
function loginTarget(params) {
  const h = params.get("h");
  const p = params.get("p");
  const port = loopbackPort(params.get("port"));
  if (!isSecretHash(h) || !isProvider(p) || port === undefined) return null;
  return { h, p, port };
}

/** GET /api/auth/start?p=<provider>&h=<64 hex>[&port=<n>]. Checks the query's shape only; no D1. */
export function loginPage(request, env) {
  const target = loginTarget(new URL(request.url).searchParams);
  if (target === null) return loginFailureResponse(400);
  return loginPageResponse(target, env);
}

/** The form fields of a begin, each present at most once and none other than these. */
const BEGIN_FIELDS = ["h", "p", "token", "port"];

function beginForm(text) {
  const params = new URLSearchParams(text);
  for (const key of new Set(params.keys())) {
    if (!BEGIN_FIELDS.includes(key) || params.getAll(key).length !== 1) return null;
  }
  const target = loginTarget(params);
  const token = params.get("token");
  if (target === null || !isTurnstileToken(token)) return null;
  return { ...target, token };
}

/** `?code_challenge` of PKCE S256 for `verifier`. */
async function codeChallenge(verifier) {
  return base64url(await sha256(verifier));
}

/**
 * POST /api/auth/begin, the start page's form. Answers a 302 to the provider's authorisation URL
 * with the begin cookie `uc_begin_<h>`, or a refusal page. `now` is the Worker's clock.
 */
export async function loginBegin(request, env, ctx, now) {
  // Paused sharing stops new logins too; logins already begun still complete and claim.
  if (!sharingEnabled(env)) return loginFailureResponse(503, {}, "sharing_paused");
  // Only the start page posts here: a form POST from any other origin carries that origin.
  if (request.headers.get("Origin") !== env.PUBLIC_ORIGIN) return loginFailureResponse(403);
  const type = request.headers.get("Content-Type") ?? "";
  if (type.split(";")[0].trim().toLowerCase() !== FORM) return loginFailureResponse(400);
  let form;
  try {
    form = beginForm(await readText(request, limits.MAX_SMALL_BODY));
  } catch (error) {
    if (error instanceof TooLarge || error instanceof InvalidPayload) return loginFailureResponse(400);
    throw error;
  }
  if (form === null) return loginFailureResponse(400);
  if (!(await verifyTurnstile(form.token, env, env.TURNSTILE_ACTION))) return loginFailureResponse(403);

  const provider = PROVIDERS[form.p];
  const state = randomSecret();
  const verifier = randomSecret();
  const oidcNonce = randomSecret();
  const mark = randomSecret();
  // Built before the row is written, so a missing client id or redirect origin refuses the begin
  // without spending a login of the day's limit.
  const authorize = new URL(provider.authorizeUrl);
  authorize.search = new URLSearchParams({
    client_id: clientId(env, form.p),
    redirect_uri: redirectUri(env, form.p),
    response_type: "code",
    scope: provider.scope,
    state,
    nonce: oidcNonce,
    code_challenge: await codeChallenge(verifier),
    code_challenge_method: "S256",
    prompt: "select_account",
  }).toString();
  const at = clock(now);
  let outcome;
  try {
    outcome = await beginLogin(env.DB, {
      h: hexBytes(form.h),
      provider: form.p,
      stateHash: await sha256(state),
      pkceVerifier: verifier,
      nonceHash: await sha256(oidcNonce),
      beginHash: await sha256(mark),
      port: form.port,
      expiresAt: at.now + limits.LOGIN_TTL_SECONDS,
      day: at.day,
      limit: limits.LOGIN_LIMIT,
      now: at.now,
      markHash: await markHash(request, form.h),
    });
  } catch (error) {
    if (error instanceof Unavailable) return loginFailureResponse(503);
    throw error;
  }
  if (outcome === "limit") return loginFailureResponse(429, { "Retry-After": String(untilTomorrow(at)) });
  if (outcome === "taken") return loginFailureResponse(409, {}, "login_in_progress");
  // Only after a begin committed, and outside the response: a failed sweep is picked up by the next.
  ctx.waitUntil(sweepLogins(env.DB, at.now, limits.SWEEP_LIMIT).catch(() => {}));

  // The authorisation URL goes in Location only, never in a body. The cookie's name carries h, so
  // two logins begun in one browser keep their marks apart instead of the later replacing the earlier.
  return new Response(null, {
    status: 302,
    headers: {
      Location: authorize.toString(),
      "Set-Cookie": `uc_begin_${form.h}=${mark}; Path=/api/auth; HttpOnly; Secure; SameSite=Lax; Max-Age=${limits.LOGIN_TTL_SECONDS}`,
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
    },
  });
}

/** The cookie that marks the browser a login began in, and the one that hands a web login's proof to the app. */
const beginCookie = (h) => `uc_begin_${h}`;
const loginCookie = (h) => `uc_login_${h}`;
const removal = (name) => `${name}=; Path=/api/auth; HttpOnly; Secure; SameSite=Lax; Max-Age=0`;

/** The SHA-256 of the begin cookie of `h` (64 hex digits) that `request` carries, or null without one. */
async function markHash(request, h) {
  const mark = readCookie(request, beginCookie(h));
  return mark === null ? null : sha256(mark);
}

/** The value of cookie `name` in `request`'s Cookie header, or null. Other cookies are not read. */
function readCookie(request, name) {
  for (const part of (request.headers.get("Cookie") ?? "").split(";")) {
    const eq = part.indexOf("=");
    if (eq !== -1 && part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return null;
}

/** Whether two byte strings (D1 BLOBs or Uint8Arrays) hold the same bytes. */
function sameBytes(a, b) {
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  return x.length === y.length && x.every((v, i) => v === y[i]);
}

/** The JSON payload of a JWT, or null when it does not decode. Its signature is not checked. */
function jwtPayload(token) {
  const part = typeof token === "string" ? token.split(".")[1] : undefined;
  if (part === undefined) return null;
  try {
    const text = atob(part.replaceAll("-", "+").replaceAll("_", "/"));
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(text, (c) => c.charCodeAt(0))));
  } catch {
    return null;
  }
}

/**
 * The subject of the ID token the provider answers `code` with, or null when the exchange is refused
 * or the token is not this login's: wrong issuer, audience or nonce, or expired at `atNow`.
 * Throws Unavailable when the provider cannot be reached.
 *
 * The ID token arrives straight from the provider's token endpoint over TLS, authenticated by the
 * client secret, so its signature is not verified; its claims still are.
 */
async function exchangeCode(env, providerName, login, code, atNow) {
  const provider = PROVIDERS[providerName];
  let response;
  try {
    response = await fetch(provider.tokenUrl, {
      method: "POST",
      headers: { "Content-Type": FORM },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code,
        client_id: clientId(env, providerName),
        client_secret: clientSecret(env, providerName),
        redirect_uri: redirectUri(env, providerName),
        code_verifier: login.pkce_verifier,
      }).toString(),
    });
  } catch (error) {
    throw new Unavailable("the token endpoint is unreachable", { cause: error });
  }
  if (response.status >= 500) throw new Unavailable(`the token endpoint answered ${response.status}`);
  if (!response.ok) return null;
  let claims;
  try {
    claims = jwtPayload((await response.json()).id_token);
  } catch {
    return null;
  }
  if (claims === null || typeof claims.sub !== "string" || claims.sub === "") return null;
  if (!provider.issuers.includes(claims.iss) || claims.aud !== clientId(env, providerName)) return null;
  if (typeof claims.exp !== "number" || claims.exp <= atNow) return null;
  if (typeof claims.nonce !== "string" || !sameBytes(await sha256(claims.nonce), login.nonce_hash)) return null;
  return claims.sub;
}

/** HMAC-SHA256 of `provider || 0x00 || sub` under IDENTITY_HMAC_KEY: what `identities` holds instead of the subject. */
async function subjectHmac(env, provider, sub) {
  const message = new TextEncoder().encode(`${provider}\u0000${sub}`);
  return new Uint8Array(await crypto.subtle.sign("HMAC", await identityKey(env), message));
}

/**
 * GET /api/auth/callback/<provider>?state&code, where the provider sends the browser back. Completes
 * the login the state belongs to, only in the browser that began it: on the web the proof goes to
 * that browser as a cookie the app's claim carries, in a redirect back to the app; for the Windows
 * app it goes to the app's loopback listener in a redirect. `now` is the Worker's clock.
 */
export async function loginCallback(request, env, providerName, now) {
  if (!isProvider(providerName)) return loginFailureResponse(400);
  const params = new URL(request.url).searchParams;
  const state = params.get("state");
  if (!isLoginSecret(state)) return loginFailureResponse(400);
  const at = clock(now);
  try {
    const stateHash = await sha256(state);
    const login = await findStartedLogin(env.DB, stateHash, at.now);
    // Unknown, expired or already completed: refused before the provider is called.
    if (login === null || login.provider !== providerName) return loginFailureResponse(400);
    const h = toHex(login.h);
    // From here on the login is known, and every answer removes this login's begin mark (and no other).
    const answer = await completeCallback(request, env, { login, h, stateHash, params, at });
    answer.headers.append("Set-Cookie", removal(beginCookie(h)));
    return answer;
  } catch (error) {
    if (error instanceof Unavailable) return loginFailureResponse(503);
    throw error;
  }
}

async function completeCallback(request, env, { login, h, stateHash, params, at }) {
  const mark = readCookie(request, beginCookie(h));
  if (mark === null || !sameBytes(await sha256(mark), login.begin_hash)) {
    return loginFailureResponse(400, {}, "login_browser_mismatch");
  }
  const code = params.get("code");
  if (code === null || code === "" || code.length > MAX_CODE) return loginFailureResponse(400);
  const sub = await exchangeCode(env, login.provider, login, code, at.now);
  if (sub === null) return loginFailureResponse(400);

  const proof = randomSecret();
  const outcome = await completeLogin(env.DB, {
    h: login.h,
    stateHash,
    provider: login.provider,
    subjectHmac: await subjectHmac(env, login.provider, sub),
    newAccountId: newAccountId(),
    proofHash: await sha256(proof),
    now: at.now,
    day: at.day,
    limit: limits.ACCOUNT_CREATE_LIMIT,
  });
  if (outcome === "limit") return loginFailureResponse(429, { "Retry-After": String(untilTomorrow(at)) });
  if (outcome === "gone") return loginFailureResponse(400);

  // The Windows app is not a browser and cannot read a cookie this page sets, so its proof travels
  // to its loopback listener instead; `h` lets the listener ignore a redirect of another login.
  if (login.port !== null) {
    const target = `http://127.0.0.1:${login.port}/cb?${new URLSearchParams({ h, code: proof })}`;
    return new Response(null, {
      status: 302,
      headers: { Location: target, "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex" },
    });
  }
  // The web app is a browser tab, and a password manager's "Sign in with" follows one tab, so the app left for the
  // start page in its own tab: this sends that tab back to the app's account tab, whose start-up claims with the
  // cookie. The target is fixed, never taken from the request. `/#/account` is the app's route under Flutter's
  // default (hash) URL strategy.
  return new Response(null, {
    status: 302,
    headers: {
      Location: `${env.PUBLIC_ORIGIN}${APP_ACCOUNT_TAB}`,
      "Set-Cookie": `${loginCookie(h)}=${proof}; Path=/api/auth; HttpOnly; Secure; SameSite=Lax; Max-Age=${limits.LOGIN_TTL_SECONDS}`,
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
    },
  });
}

/** Where a web login's callback sends its tab, under PUBLIC_ORIGIN. */
export const APP_ACCOUNT_TAB = "/#/account";

/**
 * POST /api/auth/claim `{s, code?}`: the app exchanges its login for a session. `s` is the secret
 * whose hash `h` named the login; the proof is the login's cookie on the web and `code` for the
 * Windows app, chosen by whether the login carries a loopback port, never by what the request sends.
 * `now` is the Worker's clock.
 */
export async function loginClaim(request, env, ctx, now) {
  const body = envelope(await readJson(request, limits.MAX_SMALL_BODY), ["s"], ["code"]);
  if (!isLoginSecret(body.s)) throw new InvalidPayload("s");
  if (body.code !== undefined && !isLoginSecret(body.code)) throw new InvalidPayload("code");
  const h = toHex(await sha256(body.s));
  const at = clock(now);
  const login = await findLogin(env.DB, hexBytes(h), at.now);
  if (login === null) return fail(410, "login_expired");
  const proof = login.port !== null ? (body.code ?? null) : readCookie(request, loginCookie(h));
  if (proof === null) return login.stage === 0 ? fail(409, "login_incomplete") : fail(403, "forbidden");
  // A proof against a login that holds none (stage 0, including one a later begin of the same h
  // reset) is a wrong proof, not an early claim.
  const proofHash = await sha256(proof);
  if (login.proof_hash === null || !sameBytes(proofHash, login.proof_hash)) return fail(403, "forbidden");

  const token = randomSecret();
  const session = await claimLogin(env.DB, {
    h: hexBytes(h),
    proofHash,
    tokenHash: await sha256(token),
    now: at.now,
    expiresAt: at.now + limits.SESSION_TTL_SECONDS,
    deleteExpiresAt: at.now + limits.ACCOUNT_DELETE_SESSION_TTL_SECONDS,
  });
  if (session === null) return fail(410, "login_expired");
  ctx.waitUntil(sweepLogins(env.DB, at.now, limits.SWEEP_LIMIT).catch(() => {}));
  // A login onto an account being deleted gets a session that can only continue the deletion, and
  // `deleting` tells the app to continue it.
  return json(
    200,
    { token, expires_at: session.expiresAt, account_id: session.accountId, deleting: session.scope === "delete" },
    // Only this login's handover cookie: another login of the same browser may still be in flight.
    { "Set-Cookie": removal(loginCookie(h)) },
  );
}


/**
 * The session `request` authenticates with, as `{accountId, scope, tokenHash}`, read at `atNow`.
 * Throws SessionRequired when there is none, AccountDeleting when it is a deletion-only session
 * (scope "delete") and `deletion` is false, and Unavailable. Only DELETE /api/me and logout pass
 * `deletion: true`.
 */
export async function requireSession(request, env, atNow, { deletion = false } = {}) {
  const token = BEARER.exec(request.headers.get("Authorization") ?? "")?.[1];
  if (!isLoginSecret(token)) throw new SessionRequired();
  const tokenHash = await sha256(token);
  const session = await findSession(env.DB, tokenHash, atNow);
  if (session === null) throw new SessionRequired();
  if (session.scope === "delete" && !deletion) throw new AccountDeleting();
  return { accountId: session.account_id, scope: session.scope, tokenHash };
}

/** POST /api/auth/logout with the session's bearer token: ends that session. */
export async function logout(request, env, now) {
  const session = await requireSession(request, env, clock(now).now, { deletion: true });
  await deleteSession(env.DB, session.tokenHash);
  return noContent();
}
