// The guard's notifications go to Sentry as one event each, in the envelope form the share Worker's
// report endpoint (src/report.mjs) uses. An event carries the notification's name and the aggregate
// values the run attaches to it (days, metrics, quantities, statuses), never a response's rows.

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");

/** `dsn` read as Sentry's envelope endpoint and key, or null when it is empty or not a DSN. */
export function sentrySink(dsn) {
  if (typeof dsn !== "string" || dsn === "") return null;
  let url;
  try {
    url = new URL(dsn);
  } catch {
    return null;
  }
  const project = url.pathname.replace(/^\//, "");
  if (url.username === "" || !/^\d+$/.test(project)) return null;
  return { dsn, key: url.username, endpoint: `${url.protocol}//${url.host}/api/${project}/envelope/` };
}

/**
 * The issue a notification groups into. A notification about one environment (production or staging)
 * carries it as `extra.env`, and each environment gets its own issue: a staging test's trip left
 * unresolved must not absorb production's trip, which Sentry would then not report as a new issue.
 * A notification about the guard as a whole carries no env and groups by name alone.
 */
export const fingerprintOf = ({ name, extra }) => (typeof extra?.env === "string" ? ["guard", name, extra.env] : ["guard", name]);

/**
 * The guard's `send`: posts `{ name, extra }` as one Sentry event and resolves to whether Sentry took it
 * (a 2xx). Without a sink nothing can be sent, so every notification resolves to false and stays
 * unconfirmed (the next run tries again).
 */
export function sentrySender(sink, { environment, timeoutMs }) {
  return async ({ name, extra }) => {
    if (sink === null) return false;
    const eventId = hex(crypto.getRandomValues(new Uint8Array(16)));
    const sentAt = new Date().toISOString();
    const event = {
      event_id: eventId,
      timestamp: sentAt,
      platform: "other",
      level: "warning",
      logger: "guard",
      message: { formatted: `guard: ${name}` },
      environment,
      tags: { event: name },
      extra,
      fingerprint: fingerprintOf({ name, extra }),
    };
    const body = [{ event_id: eventId, sent_at: sentAt, dsn: sink.dsn }, { type: "event" }, event].map((line) => JSON.stringify(line)).join("\n");
    try {
      const res = await fetch(sink.endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-sentry-envelope",
          "X-Sentry-Auth": `Sentry sentry_version=7, sentry_client=umacapture-guard/1, sentry_key=${sink.key}`,
        },
        body,
        signal: AbortSignal.timeout(timeoutMs),
      });
      await res.body?.cancel();
      return res.ok;
    } catch {
      return false;
    }
  };
}
