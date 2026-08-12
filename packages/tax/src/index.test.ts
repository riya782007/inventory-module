import assert from "node:assert/strict";
import { splitInclusive, splitExclusive, isInterState, stateCodeFromGstin,
         isValidGstinFormat, resolveTaxMode, computeLineTax, roundOff,
         stateNameFromCode } from "./index.ts";

let n = 0; const t = (name: string, fn: () => void) => { fn(); n++; console.log("  PASS  " + name); };
const DELHI = { gstin: "07AAIPJ3244P1ZD", state_code: "07" };

console.log("\n@newvora/tax");
t("GSTIN yields its state code", () => assert.equal(stateCodeFromGstin("07AAIPJ3244P1ZD"), "07"));
t("state code names resolve", () => assert.equal(stateNameFromCode("29"), "Karnataka"));
t("GSTIN format validation", () => {
  assert.equal(isValidGstinFormat("07AAIPJ3244P1ZD"), true);
  assert.equal(isValidGstinFormat("BOGUS"), false);
});
t("same state is intra-state", () => assert.equal(isInterState(DELHI, "07"), false));
t("different state is inter-state", () => assert.equal(isInterState(DELHI, "29"), true));

t("3% inclusive on Rs1030 -> taxable Rs1000, CGST+SGST Rs15 each", () => {
  const s = splitInclusive(103000, 300, DELHI, "07");
  assert.equal(s.taxable_paise, 100000);
  assert.equal(s.cgst_paise, 1500);
  assert.equal(s.sgst_paise, 1500);
  assert.equal(s.igst_paise, 0);
  assert.equal(s.total_paise, 103000);
});
t("3% exclusive on Rs1000 -> total Rs1030", () => {
  const s = splitExclusive(100000, 300, DELHI, "07");
  assert.equal(s.tax_paise, 3000);
  assert.equal(s.total_paise, 103000);
});
t("inter-state uses IGST, never CGST/SGST", () => {
  const s = splitExclusive(100000, 1800, DELHI, "29");
  assert.equal(s.igst_paise, 18000);
  assert.equal(s.cgst_paise, 0);
  assert.equal(s.sgst_paise, 0);
});
t("CGST+SGST always sums exactly to the GST amount (no lost paise)", () => {
  for (const amt of [100001, 33333, 77777, 1, 999999]) {
    for (const rate of [300, 500, 1200, 1800, 2800]) {
      const s = splitExclusive(amt, rate, DELHI, "07");
      assert.equal(s.cgst_paise + s.sgst_paise, s.tax_paise - s.cess_paise);
    }
  }
});
t("inclusive split is exactly reversible", () => {
  for (const gross of [103000, 118000, 50000, 12345]) {
    const s = splitInclusive(gross, 1800, DELHI, "07");
    assert.equal(s.taxable_paise + s.tax_paise, gross);
  }
});
t("auto mode: wholesale exclusive, retail inclusive", () => {
  assert.equal(resolveTaxMode(null, "wholesale"), "exclusive");
  assert.equal(resolveTaxMode(null, "retail"), "inclusive");
  assert.equal(resolveTaxMode("exclusive", "retail"), "exclusive");
});
t("non-GST documents carry zero tax", () => {
  const s = computeLineTax(100000, 0, "none", DELHI, "07");
  assert.equal(s.tax_paise, 0);
  assert.equal(s.total_paise, 100000);
});
t("round-off to the nearest rupee is reported", () => {
  const r = roundOff(103049);
  assert.equal(r.total_paise, 103000);
  assert.equal(r.round_off_paise, -49);
});
console.log(`  ${n}/${n} passed`);
