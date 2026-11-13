// The node half of tool/cloudflare/guard.sh: runs one operator command (guard/src/operator.mjs) against the
// guard's remote D1 through `wrangler d1 execute umacapture-guard --remote --json --command`, which takes no
// parameters, so every statement goes with its values written in (inlineSql). A batch is one --command
// holding its statements in order.
//
//   node guard_cli.mjs <command> [<env>] [--allowance <USD>] [--for <duration>] [--base <USD>] [--through <day>]
//
// Environment: GUARD_WRANGLER_JS (the wrangler entry script node runs), GUARD_WRANGLER_CONFIG (the
// guard's wrangler config) and GUARD_BY (who is recorded as the operator).
// Exit status: 0 written or nothing to do, 1 refused or failed, 3 another writer changed the state first
// (nothing was written; read the state again and repeat the command).

import { spawnSync } from "node:child_process";
import { CFG } from "../src/config.mjs";
import {
  arm,
  closeEnv,
  durationToSeconds,
  inlineSql,
  ledgerBridge,
  limitBase,
  openEnv,
  reconAccept,
  status,
  usdToMicros,
} from "../src/operator.mjs";

const DATABASE = "umacapture-guard";

function wrangler(sql) {
  const args = [process.env.GUARD_WRANGLER_JS, "d1", "execute", DATABASE, "--remote", "-c", process.env.GUARD_WRANGLER_CONFIG, "--json", "--command", sql];
  const r = spawnSync(process.execPath, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`wrangler exited with ${r.status}: ${(r.stderr || r.stdout || "").trim().slice(0, 500)}`);
  const out = r.stdout;
  let results;
  try {
    results = JSON.parse(out.slice(out.indexOf("[")));
  } catch {
    throw new Error("wrangler printed no JSON result");
  }
  if (!Array.isArray(results) || !results.every((x) => x && x.success)) throw new Error(`D1 did not report success: ${out.trim().slice(0, 300)}`);
  return results;
}

/** The remote D1 as an executor. A batch whose result count does not match its statements is an error, not a loss. */
const remote = {
  query: async (sql, params = []) => wrangler(inlineSql(sql, params)).at(-1).results ?? [],
  batch: async (statements) => {
    const results = wrangler(statements.map((s) => inlineSql(s.sql, s.params)).join(";\n"));
    if (results.length !== statements.length) throw new Error(`D1 answered ${results.length} results for ${statements.length} statements`);
    return results.map((r) => ({ changes: r.meta?.changes ?? 0 }));
  },
};

function parse(argv) {
  const [command, ...rest] = argv;
  const o = { command, flags: {} };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a.startsWith("--")) {
      if (i + 1 >= rest.length) throw new Error(`${a} needs a value`);
      o.flags[a.slice(2)] = rest[++i];
    } else if (o.env === undefined) o.env = a;
    else throw new Error(`unexpected argument ${a}`);
  }
  return o;
}

async function main() {
  const { command, env, flags } = parse(process.argv.slice(2));
  const nowSec = Math.floor(Date.now() / 1000);
  const by = process.env.GUARD_BY || "operator";
  const money = (k) => {
    const v = usdToMicros(flags[k]);
    if (v === null) throw new Error(`--${k} must be USD with at most 6 decimal places`);
    return v;
  };
  let result;
  switch (command) {
    case "status":
      result = await status(remote);
      break;
    case "arm":
      result = await arm(remote, { nowSec, cfg: CFG });
      break;
    case "open": {
      let forS;
      if (flags.for !== undefined) {
        forS = durationToSeconds(flags.for);
        if (forS === null) throw new Error("--for must be <n>s, <n>m or <n>h");
      }
      result = await openEnv(remote, { env, allowanceMicros: money("allowance"), forS, nowSec, by, cfg: CFG });
      break;
    }
    case "close":
      result = await closeEnv(remote, { env, nowSec });
      break;
    case "limit":
      result = await limitBase(remote, { env, baseMicros: money("base"), nowSec });
      break;
    case "ledger-bridge":
      result = await ledgerBridge(remote, { nowSec, by, cfg: CFG });
      break;
    case "recon-accept":
      result = await reconAccept(remote, { env, through: flags.through, nowSec, by, cfg: CFG });
      break;
    default:
      throw new Error(`unknown command ${command}`);
  }
  console.log(JSON.stringify(result, null, 2));
  if (result.refuse !== undefined) {
    console.error(`refused: ${result.refuse}`);
    return 1;
  }
  if (result.lost || result.bridged?.some((b) => !b.moved)) {
    console.error("another writer changed the state first; nothing more was written. Read the status again and repeat the command.");
    return 3;
  }
  if (result.noop) console.error("nothing to do: the state already is what the command asks for.");
  return 0;
}

main().then(
  (code) => process.exit(code),
  (e) => {
    console.error(`error: ${e.message}`);
    process.exit(1);
  },
);
