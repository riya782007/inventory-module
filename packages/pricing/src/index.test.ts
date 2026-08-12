// Parity fixtures. These are the SAME numbers asserted by the SQL test in
// supabase/tests/run.py. If TypeScript and SQL ever disagree, one of these
// two suites fails and the bug is caught before a customer is mischarged.
import assert from "node:assert/strict";
import { computePrices, qtyBreakBp, isValidPriceSet, roundCharm9, roundMultiple,
         resolvePrices, formatPaise, type PricingFormula } from "./index.ts";

let n = 0; const t = (name: string, fn: () => void) => {
  fn(); n++; console.log("  PASS  " + name);
};

const YOGENDRA: PricingFormula = {
  mode: "multiplier", wholesale_markup_bp: 1000,
  retail_multiplier: 2.2, mrp_multiplier: 2.75,
  retail_rounding: "charm_9", mrp_rounding: "multiple_5", round_to_paise: 100,
  qty_break_tiers: [{ min_qty: 12, pct_off_bp: 500 }, { min_qty: 50, pct_off_bp: 1000 }],
};

const AGGARWAL: PricingFormula = {
  mode: "multiplier", wholesale_markup_bp: 0,
  retail_multiplier: 1.5, mrp_multiplier: 4,
  retail_tiers: [{ below_paise: 150000, multiplier: 1.6 }, { multiplier: 1.5 }],
  retail_rounding: "multiple_10", mrp_rounding: "multiple_10", round_to_paise: 100,
};

console.log("\n@newvora/pricing");
t("Yogendra: Rs200 x2.2 = Rs440 -> charm Rs449",
  () => assert.equal(computePrices(20000, YOGENDRA).retail_paise, 44900));
t("Yogendra: Rs200 x2.75 = Rs550 (multiple of 5)",
  () => assert.equal(computePrices(20000, YOGENDRA).mrp_paise, 55000));
t("Yogendra: wholesale = base + 10%",
  () => assert.equal(computePrices(20000, YOGENDRA).wholesale_paise, 22000));
t("Aggarwal: Rs1000 (<Rs1500) uses the 1.6x band -> Rs1600",
  () => assert.equal(computePrices(100000, AGGARWAL).retail_paise, 160000));
t("Aggarwal: Rs2000 (>=Rs1500) uses the 1.5x band -> Rs3000",
  () => assert.equal(computePrices(200000, AGGARWAL).retail_paise, 300000));
t("MRP is never printed below retail", () => {
  const p = computePrices(100000, AGGARWAL);
  assert.ok(p.mrp_paise >= p.retail_paise);
});
t("price-set validity rule holds",
  () => assert.equal(isValidPriceSet(computePrices(20000, YOGENDRA)), true));
t("charm rounding always ends in 9 and never rounds down", () => {
  for (const v of [12600, 13000, 44000, 90, 100]) {
    const r = roundCharm9(v);
    assert.equal((r / 100) % 10, 9, `${v} -> ${r}`);
    assert.ok(r >= v - 100);
  }
});
t("multiple-of-5 rounding respects the retail floor",
  () => assert.equal(roundMultiple(40000, 5, 44900), 45000));
t("qty breaks pick the best applicable tier", () => {
  assert.equal(qtyBreakBp(YOGENDRA, 5), 0);
  assert.equal(qtyBreakBp(YOGENDRA, 12), 500);
  assert.equal(qtyBreakBp(YOGENDRA, 60), 1000);
});
t("explicit overrides beat the formula, variant before product", () => {
  const p = resolvePrices(20000, YOGENDRA, { retail: 39900 }, { retail: 30000, mrp: 60000 });
  assert.equal(p.retail_paise, 39900);
  assert.equal(p.mrp_paise, 60000);
});
t("build-up mode yields wholesale < retail <= mrp", () => {
  const p = computePrices(20000, {
    mode: "buildup", wholesale_markup_bp: 0, retail_multiplier: 1, mrp_multiplier: 1,
    shipping_bp: 500, packing_flat_paise: 2000, promotion_flat_paise: 1000,
    reseller_bp: 4000, customer_discount_bp: 500, mrp_bp: 2500,
    retail_rounding: "nearest", mrp_rounding: "nearest", round_to_paise: 100 });
  assert.ok(p.wholesale_paise < p.retail_paise && p.retail_paise <= p.mrp_paise);
});
t("Indian digit grouping", () => assert.equal(formatPaise(12345600), "₹1,23,456"));
console.log(`  ${n}/${n} passed`);
