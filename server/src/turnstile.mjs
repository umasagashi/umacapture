// Server-side verification of a Turnstile token (siteverify). The visitor's IP is not sent: the
// Worker never reads it.

const SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

/**
 * `vars.TURNSTILE_TESTING_KEY`: whether this environment runs on Turnstile's testing keys. "true"
 * or "false"; anything else is a configuration error.
 */
function testingKeyDeclared(env) {
  if (env.TURNSTILE_TESTING_KEY === "true") return true;
  if (env.TURNSTILE_TESTING_KEY === "false") return false;
  throw new Error(
    `TURNSTILE_TESTING_KEY must be "true" or "false", got ${JSON.stringify(env.TURNSTILE_TESTING_KEY)}`,
  );
}

/**
 * Whether `token` passed Turnstile on this environment's hostname with `action`, the action of the
 * page that issued it. A network failure, a non-JSON answer or any mismatch is a refusal.
 *
 * siteverify marks an answer issued for a testing secret with `metadata.result_with_testing_key`.
 * Such an answer names no hostname or action of this environment (it reports "example.com" and no
 * action), so an environment that declares the testing key accepts it on `success` alone, and every
 * other environment refuses it.
 */
export async function verifyTurnstile(token, env, action) {
  const testingKey = testingKeyDeclared(env);
  let outcome;
  try {
    const res = await fetch(SITEVERIFY, {
      method: "POST",
      body: new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token }),
    });
    if (!res.ok) return false;
    outcome = await res.json();
  } catch {
    return false;
  }
  if (outcome === null || outcome.success !== true) return false;
  if (outcome.metadata?.result_with_testing_key === true) return testingKey;
  return outcome.hostname === env.TURNSTILE_HOSTNAME && outcome.action === action;
}
