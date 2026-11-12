// The login endpoints (start page, begin, callback, claim) and sessions, driven over HTTP against a
// real (local) D1, with siteverify and Google's token endpoint answered inside the test.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import * as limits from "../src/limits.mjs";
import {
  CookieJar,
  GOOGLE,
  newLoginHash,
  newLoginSecret,
  ORIGIN,
  startWorker,
  subjectHmac,
  TURNSTILE,
} from "./support/worker_harness.mjs";

const sha256 = (text) => createHash("sha256").update(text, "utf8").digest();
const AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";

/** Asserts `res` is a refusal page with `status`, passing nothing on as a referrer. */
async function refusalPage(res, status) {
  assert.equal(res.status, status);
  assert.match(res.headers.get("content-type"), /^text\/html/);
  assert.equal(res.headers.get("referrer-policy"), "no-referrer");
  assert.equal(res.headers.get("location"), null);
  assert.deepEqual(res.headers.getSetCookie(), []);
  await res.text();
}

describe("login start page", () => {
  let worker;
  // No tables: a query would throw, so a page answered here never reached D1.
  before(async () => (worker = await startWorker({ migrate: false })));
  after(() => worker.dispose());

  test("is served without D1, with a form-action CSP and a same-origin referrer policy", async () => {
    const h = newLoginHash();
    const res = await worker.fetch(`/api/auth/start?p=google&h=${h}&port=49152`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("referrer-policy"), "same-origin");
    const csp = res.headers.get("content-security-policy").split("; ");
    assert.ok(csp.includes("form-action 'self' https://accounts.google.com"), csp.join("; "));
    assert.equal(csp.length, 8);
    const html = await res.text();
    assert.match(html, /<form id="begin" method="POST" action="\/api\/auth\/begin">/);
    assert.ok(html.includes(`name="h" value="${h}"`));
    assert.ok(html.includes(`name="port" value="49152"`));
    assert.ok(html.includes(`data-action="login"`));
  });

  test("asks for a press on the Google button, and does not submit when Turnstile passes", async () => {
    const res = await worker.fetch(`/api/auth/start?p=google&h=${newLoginHash()}`);
    const html = await res.text();
    const form = html.slice(html.indexOf('<form id="begin"'), html.indexOf("</form>"));
    assert.match(form, /<button type="submit"[^>]*>.*Google でログイン<\/span><\/button>/);
    // The widget stays outside the form, whose fields the begin checks.
    assert.ok(!form.includes("cf-turnstile"));
    const callback = html.slice(html.indexOf("window.onTurnstile ="), html.indexOf("};", html.indexOf("window.onTurnstile =")));
    assert.match(callback, /if \(pressed\) form\.submit\(\);/);
    assert.equal(callback.match(/submit\(/g).length, 1);
  });

  test("refuses a malformed h, p or port with a no-referrer page", async () => {
    const h = newLoginHash();
    for (const query of [
      `p=google&h=${h.toUpperCase()}`,
      `p=google&h=${h.slice(1)}`,
      `p=github&h=${h}`,
      `h=${h}`,
      `p=google&h=${h}&port=1023`,
      `p=google&h=${h}&port=65536`,
      `p=google&h=${h}&port=08080`,
    ]) {
      await refusalPage(await worker.fetch(`/api/auth/start?${query}`), 400);
    }
  });
});

describe("login begin", () => {
  let worker;
  let passing;
  before(async () => {
    worker = await startWorker({ testEntry: true });
    passing = worker.siteverify.answer;
  });
  after(() => worker.dispose());
  beforeEach(async () => {
    await worker.db.batch([worker.db.prepare("DELETE FROM logins"), worker.db.prepare("DELETE FROM daily")]);
    worker.siteverify.answer = passing;
    worker.siteverify.calls.length = 0;
  });

  const dailyLogins = async () =>
    (await worker.db.prepare("SELECT COALESCE(SUM(logins), 0) AS n FROM daily").first()).n;

  test("answers a 302 to Google with the begin cookie, and stores only hashes of what it sent", async () => {
    const h = newLoginHash();
    const jar = new CookieJar();
    const res = await worker.begin({ h }, {}, jar);
    assert.equal(res.status, 302);
    assert.equal(res.headers.get("referrer-policy"), "no-referrer");
    const body = await res.text();
    assert.equal(body, "");

    const location = new URL(res.headers.get("location"));
    assert.equal(`${location.origin}${location.pathname}`, AUTHORIZE);
    const q = location.searchParams;
    assert.equal(q.get("client_id"), GOOGLE.CLIENT_ID);
    assert.equal(q.get("redirect_uri"), `${GOOGLE.REDIRECT_ORIGIN}/api/auth/callback/google`);
    assert.equal(q.get("response_type"), "code");
    assert.equal(q.get("scope"), "openid email");
    assert.equal(q.get("code_challenge_method"), "S256");

    const cookie = jar.get(`uc_begin_${h}`);
    assert.ok(cookie, jar.names().join());
    assert.equal(cookie.attrs["max-age"], String(limits.LOGIN_TTL_SECONDS));
    assert.equal(cookie.attrs.path, "/api/auth");
    assert.equal(cookie.attrs.httponly, true);
    assert.equal(cookie.attrs.secure, true);
    assert.equal(cookie.attrs.samesite, "Lax");

    const row = await worker.login(h);
    assert.equal(row.stage, 0);
    assert.equal(row.port, null);
    assert.equal(row.provider, "google");
    assert.deepEqual(Buffer.from(row.state_hash), sha256(q.get("state")));
    assert.deepEqual(Buffer.from(row.nonce_hash), sha256(q.get("nonce")));
    assert.deepEqual(Buffer.from(row.begin_hash), sha256(cookie.value));
    assert.equal(createHash("sha256").update(row.pkce_verifier).digest("base64url"), q.get("code_challenge"));
    assert.equal(await dailyLogins(), 1);
    assert.equal(worker.siteverify.calls.length, 1);
  });

  test("stores the Windows app's loopback port", async () => {
    const h = newLoginHash();
    const res = await worker.begin({ h, port: "49152" });
    assert.equal(res.status, 302);
    await res.text();
    assert.equal((await worker.login(h)).port, 49152);
  });

  test("refuses a JSON body, and a form posted from another origin, without writing a login", async () => {
    const h = newLoginHash();
    const json = await worker.fetch("/api/auth/begin", {
      method: "POST",
      headers: { Origin: ORIGIN, "Content-Type": "application/json" },
      body: JSON.stringify({ h, p: "google", token: "turnstile-login-token" }),
      redirect: "manual",
    });
    await refusalPage(json, 400);
    await refusalPage(await worker.begin({ h }, { Origin: "https://evil.test" }), 403);
    await refusalPage(await worker.begin({ h }, { Origin: "null" }), 403);
    assert.equal(await worker.count("logins"), 0);
    assert.equal(await dailyLogins(), 0);
    assert.equal(worker.siteverify.calls.length, 0);
  });

  test("refuses a token that siteverify does not accept for this environment and action, without writing a login", async () => {
    const h = newLoginHash();
    const pass = { success: true, hostname: TURNSTILE.HOSTNAME, action: TURNSTILE.ACTION };
    const answers = {
      "failed": { ...pass, success: false },
      "other hostname": { ...pass, hostname: "evil.test" },
      "other action": { ...pass, action: "publish" },
      // Matching hostname and action, so only the testing-key mark can refuse it.
      "testing key": { ...pass, metadata: { result_with_testing_key: true } },
      "unreachable": new Error("network down"),
    };
    for (const [name, verdict] of Object.entries(answers)) {
      worker.siteverify.answer = () => verdict;
      const res = await worker.begin({ h });
      assert.equal(res.status, 403, name);
      await refusalPage(res, 403);
    }
    assert.equal(await worker.count("logins"), 0);
    assert.equal(await dailyLogins(), 0);
    const call = worker.siteverify.calls.at(-1);
    assert.equal(call.form.get("secret"), TURNSTILE.SECRET);
    assert.equal(call.form.get("response"), TURNSTILE.LOGIN_TOKEN);
    assert.equal(call.form.has("remoteip"), false, "the visitor's IP reached siteverify");
  });

  test("an environment declaring the testing key begins logins on the testing secret's answers only", async () => {
    const staging = await startWorker({ vars: { TURNSTILE_TESTING_KEY: "true" } });
    try {
      // What siteverify answers for the always-passing testing secret.
      const testing = {
        "success": true,
        "error-codes": [],
        "hostname": "example.com",
        "metadata": { result_with_testing_key: true },
        "challenge_ts": "2026-10-05T00:00:00.000Z",
      };
      staging.siteverify.answer = () => testing;
      const begun = await staging.begin({ h: newLoginHash() });
      assert.equal(begun.status, 302);
      await begun.arrayBuffer();

      // Answers without the mark are still held to this environment's hostname and action.
      const refused = {
        "failed": { ...testing, success: false },
        "unmarked, other hostname": { success: true, hostname: "example.com", action: TURNSTILE.ACTION },
      };
      for (const [name, verdict] of Object.entries(refused)) {
        staging.siteverify.answer = () => verdict;
        const res = await staging.begin({ h: newLoginHash() });
        assert.equal(res.status, 403, name);
        await res.arrayBuffer();
      }
      assert.equal(await staging.count("logins"), 1);
    } finally {
      await staging.dispose();
    }
  });

  test("keeps the begin cookies of two logins begun in one browser", async () => {
    const jar = new CookieJar();
    const [h1, h2] = [newLoginHash(), newLoginHash()];
    (await worker.begin({ h: h1 }, {}, jar)).body?.cancel();
    (await worker.begin({ h: h2 }, {}, jar)).body?.cancel();
    assert.deepEqual(jar.names(), [`uc_begin_${h1}`, `uc_begin_${h2}`].sort());
  });

  test("lets a second begin of the same h from the same browser replace the first", async () => {
    const jar = new CookieJar();
    const h = newLoginHash();
    const first = await worker.begin({ h }, {}, jar);
    await first.text();
    const firstCookie = jar.get(`uc_begin_${h}`).value;
    const second = await worker.begin({ h }, {}, jar);
    await second.text();
    assert.equal(first.status, 302);
    assert.equal(second.status, 302);
    const state = new URL(second.headers.get("location")).searchParams.get("state");
    assert.notEqual(state, new URL(first.headers.get("location")).searchParams.get("state"));

    assert.equal(await worker.count("logins"), 1);
    const row = await worker.login(h);
    assert.deepEqual(Buffer.from(row.state_hash), sha256(state));
    const cookie = jar.get(`uc_begin_${h}`).value;
    assert.notEqual(cookie, firstCookie);
    assert.deepEqual(Buffer.from(row.begin_hash), sha256(cookie));
    assert.equal(await dailyLogins(), 2);
  });

  test("refuses a begin of a live h from a browser without its begin cookie with 409 login_in_progress, keeping the row", async () => {
    const h = newLoginHash();
    const port = "49152";
    const owner = new CookieJar();
    (await worker.begin({ h, port }, {}, owner)).body?.cancel();
    const before = await worker.login(h);

    for (const cookie of [null, `uc_begin_${h}=${randomBytes(32).toString("base64url")}`]) {
      const res = await worker.begin({ h, port: "50000" }, cookie === null ? {} : { Cookie: cookie });
      await refusalPage(res, 409);
    }
    const res = await worker.begin({ h, port }, {}, new CookieJar());
    assert.equal(res.status, 409);
    assert.ok((await res.text()).includes(`data-error="login_in_progress"`));

    assert.deepEqual(await worker.login(h), before);
    assert.equal(await dailyLogins(), 1);
  });

  test("lets a begin from another browser replace a row of the same h once it has expired", async () => {
    const h = newLoginHash();
    (await worker.begin({ h, port: "49152" }, {}, new CookieJar())).body?.cancel();
    await worker.advanceClock(limits.LOGIN_TTL_SECONDS + 1);
    const other = new CookieJar();
    const res = await worker.begin({ h, port: "50000" }, {}, other);
    await res.text();
    assert.equal(res.status, 302);
    const row = await worker.login(h);
    assert.deepEqual(Buffer.from(row.begin_hash), sha256(other.get(`uc_begin_${h}`).value));
    assert.equal(row.port, 50000);
    assert.equal(row.stage, 0);
  });

  test("admits the day's last login and refuses the next with 429", async () => {
    const day = Math.floor((await worker.now()) / 86_400);
    await worker.db
      .prepare("INSERT INTO daily (day, logins) VALUES (?, ?)")
      .bind(day, limits.LOGIN_LIMIT - 1)
      .run();
    const last = await worker.begin({ h: newLoginHash() });
    assert.equal(last.status, 302);
    await last.text();

    const over = await worker.begin({ h: newLoginHash() });
    assert.ok(Number(over.headers.get("retry-after")) > 0);
    await refusalPage(over, 429);
    assert.equal(await worker.count("logins"), 1);
    assert.equal(await dailyLogins(), limits.LOGIN_LIMIT);
  });

  test("dates the login and its day from the Worker's clock", async () => {
    await worker.advanceClock(10 * 86_400);
    const h = newLoginHash();
    const before = await worker.now();
    (await worker.begin({ h })).body?.cancel();
    const after = await worker.now();
    const expiresAt = (await worker.login(h)).expires_at;
    assert.ok(expiresAt >= before + limits.LOGIN_TTL_SECONDS && expiresAt <= after + limits.LOGIN_TTL_SECONDS, `${expiresAt}`);
    const days = (await worker.db.prepare("SELECT day FROM daily").all()).results.map((r) => r.day);
    assert.deepEqual(days, [Math.floor(before / 86_400)]);
    assert.ok(before >= Math.floor(Date.now() / 1000) + 10 * 86_400 - 5);
  });
});

/** Waits until `condition()` holds, for work the Worker finishes after its response (a sweep). */
async function until(condition, what) {
  const deadline = Date.now() + 5_000;
  while (!(await condition())) {
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

describe("login callback, claim and sessions", () => {
  let worker;
  before(async () => (worker = await startWorker({ testEntry: true })));
  after(() => worker.dispose());
  beforeEach(async () => {
    const db = worker.db;
    await db.batch(
      ["sessions", "identities", "logins", "accounts", "daily"].map((table) => db.prepare(`DELETE FROM ${table}`)),
    );
    worker.google.calls.length = 0;
  });

  /** A login the app starts: its secret `s` and `h`, the hex SHA-256 of `s`. */
  const newLogin = () => {
    const s = newLoginSecret();
    return { s, h: sha256(s).toString("hex") };
  };

  /** Begins `login` in the browser `jar` and returns the begin's 302 Location. */
  async function beginIn(jar, login, fields = {}) {
    const res = await worker.begin({ h: login.h, ...fields }, {}, jar);
    await res.text();
    assert.equal(res.status, 302);
    return res.headers.get("location");
  }

  /** Begins `login` in `jar` and comes back through Google as `sub`; returns the callback's response. */
  async function signIn(jar, login, { sub, port } = {}) {
    const location = await beginIn(jar, login, port === undefined ? {} : { port: String(port) });
    return worker.visit(worker.authorize(location, { sub }), jar);
  }

  const stage = async (login) => (await worker.login(login.h))?.stage;
  const setCookieNames = (res) => res.headers.getSetCookie().map((line) => line.slice(0, line.indexOf("=")));

  /** Asserts `res` is a refusal page with `status` (and `error`, when given). */
  async function refused(res, status, error = null) {
    assert.equal(res.status, status);
    assert.equal(res.headers.get("referrer-policy"), "no-referrer");
    const html = await res.text();
    if (error !== null) assert.ok(html.includes(`data-error="${error}"`), html);
  }

  async function claimed(res) {
    assert.equal(res.status, 200);
    return res.json();
  }

  test("refuses a callback whose state no started login holds without calling Google", async () => {
    const jar = new CookieJar();
    await refused(await worker.visit(`/api/auth/callback/google?state=${newLoginSecret()}&code=x`, jar), 400);

    // Expired: the state was real, but LOGIN_TTL_SECONDS have passed.
    const late = newLogin();
    const lateCallback = worker.authorize(await beginIn(jar, late));
    await worker.advanceClock(limits.LOGIN_TTL_SECONDS + 1);
    await refused(await worker.visit(lateCallback, jar), 400);

    // Already completed: the same callback a second time.
    const done = newLogin();
    const callback = worker.authorize(await beginIn(jar, done));
    assert.equal((await worker.visit(callback, jar)).status, 302);
    const calls = worker.google.calls.length;
    await refused(await worker.visit(callback, jar), 400);
    assert.equal(worker.google.calls.length, calls);
    assert.equal(calls, 1);
  });

  test("refuses a callback without the begin cookie, or with another value, as login_browser_mismatch without calling Google", async () => {
    const login = newLogin();
    const callback = worker.authorize(await beginIn(new CookieJar(), login));

    const elsewhere = await worker.visit(callback, new CookieJar());
    assert.deepEqual(setCookieNames(elsewhere), [`uc_begin_${login.h}`]);
    await refused(elsewhere, 400, "login_browser_mismatch");

    const forged = new CookieJar();
    forged.store(new Response(null, { headers: { "Set-Cookie": `uc_begin_${login.h}=${newLoginSecret()}` } }));
    await refused(await worker.visit(callback, forged), 400, "login_browser_mismatch");

    assert.equal(worker.google.calls.length, 0);
    assert.equal(await stage(login), 0);
  });

  test("refuses an ID token whose nonce is not the begin's", async () => {
    const jar = new CookieJar();
    const login = newLogin();
    const location = await beginIn(jar, login);
    await refused(await worker.visit(worker.authorize(location, { nonce: newLoginSecret() }), jar), 400);
    assert.equal(worker.google.calls.length, 1);
    assert.equal(await stage(login), 0);
    assert.equal(await worker.count("accounts"), 0);
  });

  test("refuses an ID token from another issuer, for another audience, or expired on the Worker's clock", async () => {
    const now = await worker.now();
    for (const claims of [
      { iss: "https://evil.test" },
      { aud: "another-client.apps.googleusercontent.com" },
      { exp: now - 1 },
    ]) {
      const jar = new CookieJar();
      const login = newLogin();
      const location = await beginIn(jar, login);
      await refused(await worker.visit(worker.authorize(location, { claims }), jar), 400);
      assert.equal(await stage(login), 0, JSON.stringify(claims));
    }
    assert.equal(worker.google.calls.length, 3);
    assert.equal(await worker.count("accounts"), 0);
    assert.equal(await worker.count("identities"), 0);
  });

  test("brings two logins begun in one browser each to stage 1, each callback removing only its own begin cookie", async () => {
    const jar = new CookieJar();
    const [first, second] = [newLogin(), newLogin()];
    const firstCallback = worker.authorize(await beginIn(jar, first));
    const secondCallback = worker.authorize(await beginIn(jar, second));

    const res = await worker.visit(firstCallback, jar);
    assert.equal(res.status, 302);
    assert.deepEqual(setCookieNames(res).sort(), [`uc_begin_${first.h}`, `uc_login_${first.h}`]);
    assert.ok(jar.get(`uc_begin_${second.h}`));
    assert.equal((await worker.visit(secondCallback, jar)).status, 302);

    assert.equal(await stage(first), 1);
    assert.equal(await stage(second), 1);
  });

  test("creates an account for a new subject, storing only the HMAC of the subject, and finds it again", async () => {
    const jar = new CookieJar();
    const first = newLogin();
    assert.equal((await signIn(jar, first)).status, 302);
    const session = await claimed(await worker.claim({ s: first.s }, jar));
    assert.match(session.account_id, /^[0-9a-hjkmnp-tv-z]{16}$/);

    const identities = (await worker.db.prepare("SELECT * FROM identities").all()).results;
    assert.equal(identities.length, 1);
    assert.equal(identities[0].provider, "google");
    assert.equal(identities[0].account_id, session.account_id);
    assert.deepEqual(Buffer.from(identities[0].subject_hmac), subjectHmac(GOOGLE.SUB));
    assert.ok(!Buffer.from(identities[0].subject_hmac).includes(GOOGLE.SUB));

    const again = newLogin();
    assert.equal((await signIn(jar, again)).status, 302);
    assert.equal((await claimed(await worker.claim({ s: again.s }, jar))).account_id, session.account_id);
    const other = newLogin();
    assert.equal((await signIn(jar, other, { sub: "200000000000000000002" })).status, 302);
    assert.notEqual((await claimed(await worker.claim({ s: other.s }, jar))).account_id, session.account_id);
    assert.equal(await worker.count("accounts"), 2);
    assert.equal((await worker.db.prepare("SELECT SUM(accounts_created) AS n FROM daily").first()).n, 2);
  });

  test("refuses a new account past the day's limit, leaving the login at stage 0", async () => {
    const day = Math.floor((await worker.now()) / 86_400);
    await worker.db.prepare("INSERT INTO daily (day, accounts_created) VALUES (?, ?)").bind(day, limits.ACCOUNT_CREATE_LIMIT).run();
    const login = newLogin();
    const res = await signIn(new CookieJar(), login);
    assert.ok(Number(res.headers.get("retry-after")) > 0);
    await refused(res, 429);
    assert.equal(await stage(login), 0);
    assert.equal(await worker.count("accounts"), 0);
  });

  test("lets both web logins of one browser claim whichever completes first, each claim removing only its own handover cookie", async () => {
    const jar = new CookieJar();
    const [first, second] = [newLogin(), newLogin()];
    const firstCallback = worker.authorize(await beginIn(jar, first));
    const secondCallback = worker.authorize(await beginIn(jar, second));
    assert.equal((await worker.visit(secondCallback, jar)).status, 302);
    assert.equal((await worker.visit(firstCallback, jar)).status, 302);

    const res = await worker.claim({ s: first.s }, jar);
    assert.deepEqual(setCookieNames(res), [`uc_login_${first.h}`]);
    await claimed(res);
    assert.ok(jar.get(`uc_login_${second.h}`));
    await claimed(await worker.claim({ s: second.s }, jar));
    assert.equal(await worker.count("sessions"), 2);
    assert.equal(await worker.count("logins"), 0);
  });

  test("sends a web login's tab back to the app's account tab with its proof as a cookie, and claims with that cookie", async () => {
    const jar = new CookieJar();
    const login = newLogin();
    const res = await signIn(jar, login);
    assert.equal(res.status, 302);
    assert.equal(res.headers.get("location"), `${ORIGIN}/#/account`);
    assert.equal(res.headers.get("referrer-policy"), "no-referrer");
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.equal(await res.text(), "");
    assert.deepEqual(setCookieNames(res).sort(), [`uc_begin_${login.h}`, `uc_login_${login.h}`]);

    await claimed(await worker.claim({ s: login.s }, jar));
  });

  test("hands the Windows app's proof to its loopback port, and claims with that code", async () => {
    const jar = new CookieJar();
    const login = newLogin();
    const res = await signIn(jar, login, { port: 49152 });
    assert.equal(res.status, 302);
    assert.deepEqual(setCookieNames(res), [`uc_begin_${login.h}`]);
    const location = new URL(res.headers.get("location"));
    assert.equal(`${location.origin}${location.pathname}`, "http://127.0.0.1:49152/cb");
    assert.equal(location.searchParams.get("h"), login.h);

    assert.equal((await worker.claim({ s: login.s })).status, 403);
    await claimed(await worker.claim({ s: login.s, code: location.searchParams.get("code") }));
  });

  test("refuses with 403 a claim with no proof, a wrong proof or another login's proof", async () => {
    const jar = new CookieJar();
    const [mine, theirs] = [newLogin(), newLogin()];
    const codeOf = async (login) => new URL((await signIn(jar, login, { port: 49152 })).headers.get("location")).searchParams.get("code");
    const myCode = await codeOf(mine);
    const theirCode = await codeOf(theirs);

    for (const body of [{ s: mine.s }, { s: mine.s, code: newLoginSecret() }, { s: mine.s, code: theirCode }]) {
      const res = await worker.claim(body);
      assert.equal(res.status, 403, JSON.stringify(body));
      assert.deepEqual(await res.json(), { error: "forbidden" });
    }
    // The web's proof is the cookie of this login's h only.
    const web = newLogin();
    assert.equal((await signIn(jar, web)).status, 302);
    const stray = new CookieJar();
    stray.store(new Response(null, { headers: { "Set-Cookie": `uc_login_${mine.h}=${jar.get(`uc_login_${web.h}`).value}` } }));
    assert.equal((await worker.claim({ s: web.s }, stray)).status, 403);

    assert.equal(await worker.count("sessions"), 0);
    await claimed(await worker.claim({ s: mine.s, code: myCode }));
  });

  test("answers a claim before the callback login_incomplete, and one of an unknown login login_expired", async () => {
    const login = newLogin();
    await beginIn(new CookieJar(), login);
    const early = await worker.claim({ s: login.s });
    assert.equal(early.status, 409);
    assert.deepEqual(await early.json(), { error: "login_incomplete" });
    const unknown = await worker.claim({ s: newLoginSecret() });
    assert.equal(unknown.status, 410);
    assert.deepEqual(await unknown.json(), { error: "login_expired" });
  });

  test("refuses a begin of the same h after its callback completed, keeping the proof claimable", async () => {
    // The successful callback removed the begin cookie, so not even the browser it began in can
    // replace the completed login while it lives.
    const jar = new CookieJar();
    const login = newLogin();
    assert.equal((await signIn(jar, login)).status, 302);
    assert.equal(await stage(login), 1);
    assert.equal(jar.get(`uc_begin_${login.h}`), undefined);
    const completed = await worker.login(login.h);

    await refused(await worker.begin({ h: login.h }, {}, jar), 409, "login_in_progress");
    assert.deepEqual(await worker.login(login.h), completed);
    await claimed(await worker.claim({ s: login.s }, jar));
  });

  test("keeps the Windows app's login with the browser it began in when another browser begins its h and port", async () => {
    const login = newLogin();
    const port = "49152";
    const user = new CookieJar();
    const userLocation = await beginIn(user, login, { port });
    const before = await worker.login(login.h);

    // Someone else who saw the start URL begins the same h and port in their own browser.
    const other = new CookieJar();
    await refused(await worker.begin({ h: login.h, port }, {}, other), 409, "login_in_progress");
    assert.deepEqual(other.names(), []);
    const kept = await worker.login(login.h);
    for (const column of ["state_hash", "begin_hash", "port", "stage"]) assert.deepEqual(kept[column], before[column]);

    const back = await worker.visit(worker.authorize(userLocation, { sub: "the-user" }), user);
    await back.text();
    assert.equal(back.status, 302);
    const loopback = new URL(back.headers.get("location"));
    assert.equal(`${loopback.origin}${loopback.pathname}`, `http://127.0.0.1:${port}/cb`);
    const { token, account_id } = await claimed(await worker.claim({ s: login.s, code: loopback.searchParams.get("code") }));
    const identity = await worker.db
      .prepare("SELECT account_id FROM identities WHERE provider = 'google' AND subject_hmac = ?")
      .bind(subjectHmac("the-user"))
      .first();
    assert.equal(account_id, identity.account_id);
    const session = await worker.db.prepare("SELECT account_id FROM sessions WHERE token_hash = ?").bind(sha256(token)).first();
    assert.equal(session.account_id, identity.account_id);
  });

  test("builds the redirect_uri of the authorisation URL and of the token exchange from AUTH_REDIRECT_ORIGIN", async () => {
    // The harness gives AUTH_REDIRECT_ORIGIN another value than PUBLIC_ORIGIN, as staging has, so a
    // redirect_uri built from PUBLIC_ORIGIN would differ here.
    assert.notEqual(GOOGLE.REDIRECT_ORIGIN, ORIGIN);
    const expected = `${GOOGLE.REDIRECT_ORIGIN}/api/auth/callback/google`;
    const jar = new CookieJar();
    const location = await beginIn(jar, newLogin());
    assert.equal(new URL(location).searchParams.get("redirect_uri"), expected);
    assert.equal((await worker.visit(worker.authorize(location), jar)).status, 302);
    assert.equal(worker.google.calls.length, 1);
    const exchange = worker.google.calls[0].form;
    assert.equal(exchange.get("redirect_uri"), expected);
    assert.equal(exchange.get("client_secret"), GOOGLE.CLIENT_SECRET);
    assert.equal(createHash("sha256").update(exchange.get("code_verifier")).digest("base64url"), new URL(location).searchParams.get("code_challenge"));
  });

  /** A session token claimed through a fresh web login. */
  async function sessionToken() {
    const jar = new CookieJar();
    const login = newLogin();
    assert.equal((await signIn(jar, login)).status, 302);
    return (await claimed(await worker.claim({ s: login.s }, jar))).token;
  }

  test("ends a session on logout: 204, then 401 session_required", async () => {
    const token = await sessionToken();
    assert.equal((await worker.logout(token)).status, 204);
    const again = await worker.logout(token);
    assert.equal(again.status, 401);
    assert.deepEqual(await again.json(), { error: "session_required" });
    assert.equal(await worker.count("sessions"), 0);
    assert.equal((await worker.logout(randomBytes(32).toString("base64url"))).status, 401);
  });

  test("refuses a session once SESSION_TTL_SECONDS have passed", async () => {
    const [early, late] = [await sessionToken(), await sessionToken()];
    await worker.advanceClock(limits.SESSION_TTL_SECONDS - 60);
    assert.equal((await worker.logout(early)).status, 204);
    await worker.advanceClock(120);
    assert.equal((await worker.logout(late)).status, 401);
  });

  test("sweeps expired logins after a begin and expired sessions after a claim", async () => {
    await sessionToken();
    await beginIn(new CookieJar(), newLogin());
    await worker.advanceClock(limits.SESSION_TTL_SECONDS + 1);
    assert.equal(await worker.count("logins"), 1);
    await beginIn(new CookieJar(), newLogin());
    await until(async () => (await worker.count("logins")) === 1, "the expired login to be swept");

    await sessionToken();
    await until(async () => (await worker.count("sessions")) === 1, "the expired session to be swept");
  });
});
