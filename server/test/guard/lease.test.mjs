// Rule G's expression (guard/src/lease.mjs): what a write may carry, reading the rule back, and the value
// a kept lease is written back as. Pure; nothing is sent anywhere.

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { CFG } from "../../guard/src/config.mjs";
import { formatLease, keptLease, leaseExpression, parseLease } from "../../guard/src/lease.mjs";

const cfg = CFG;
const NOW = 1_800_000_000;
const MAX = NOW + cfg.D_S + cfg.WRITE_MARGIN_S;

describe("rule G expression", () => {
  test("leaseExpression refuses milliseconds, out-of-range times and a bad Ea, and parseLease reads back what it wrote", () => {
    const ok = { Ep: NOW + 600, Es: 0, Ea: cfg.EA_OFF };
    assert.deepEqual(parseLease(leaseExpression(ok, NOW, cfg), cfg), ok);
    assert.deepEqual(parseLease(leaseExpression({ Ep: MAX, Es: NOW + 1, Ea: 0 }, NOW, cfg), cfg), { Ep: MAX, Es: NOW + 1, Ea: 0 });
    for (const bad of [
      { Ep: (NOW + 600) * 1000, Es: 0, Ea: cfg.EA_OFF }, // milliseconds
      { Ep: 0, Es: (NOW + 600) * 1000, Ea: cfg.EA_OFF },
      { Ep: NOW, Es: 0, Ea: cfg.EA_OFF }, // not after now
      { Ep: MAX + 1, Es: 0, Ea: cfg.EA_OFF }, // beyond now + D + margin
      { Ep: 0, Es: -5, Ea: cfg.EA_OFF },
      { Ep: NOW + 600.5, Es: 0, Ea: cfg.EA_OFF },
      { Ep: 0, Es: 0, Ea: 1 }, // Ea neither 0 nor EA_OFF
      { Ep: 0, Es: 0, Ea: NOW + 600 },
    ]) {
      assert.throws(() => leaseExpression(bad, NOW, cfg), RangeError, JSON.stringify(bad));
    }
    const text = formatLease(ok, cfg);
    for (const edited of [
      text.replace(" or (http.host ne", " or  (http.host ne"),
      text.replace('"data.umacapture.com"', '"x.umacapture.com"'),
      text.replace(`ge ${NOW + 600}`, `ge 0${NOW + 600}`),
      text.replace('"/api/"', '"/API/"'),
      `${text} or true`,
    ]) {
      assert.equal(parseLease(edited, cfg), null, edited);
    }
  });

  test("a kept lease that is already past is written back as 0", () => {
    assert.equal(keptLease(NOW - 5, NOW, cfg), 0);
    assert.equal(keptLease(NOW, NOW, cfg), 0);
    assert.equal(keptLease(null, NOW, cfg), 0);
    assert.equal(keptLease(MAX + 1, NOW, cfg), 0);
    assert.equal(keptLease(NOW + 100, NOW, cfg), NOW + 100);
    assert.equal(keptLease(0, NOW, cfg), 0);
  });

  test("parseLease returns past and far-future times, which leaseExpression refuses to write", () => {
    for (const values of [
      { Ep: NOW - 3_600, Es: 0, Ea: cfg.EA_OFF },
      { Ep: NOW + cfg.D_S + 61, Es: 0, Ea: cfg.EA_OFF },
      { Ep: 0, Es: NOW + 86_400, Ea: 0 },
    ]) {
      assert.deepEqual(parseLease(formatLease(values, cfg), cfg), values);
      assert.throws(() => leaseExpression(values, NOW, cfg), RangeError);
    }
  });
});
