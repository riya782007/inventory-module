/**
 * @newvora/pricing — PURE pricing engine. No I/O.
 *
 * Ported from lib/pricing.ts in the Blythe Diva / Yogendra build, which was
 * the strongest asset in either legacy repo, and generalised so that the two
 * customer forks are reproducible from configuration alone.
 *
 * THIS MUST STAY IN LOCKSTEP WITH core.compute_prices() IN SQL. The catalogue
 * renders from here; the bill is computed there. If they diverge, a customer
 * is charged something different from what they were shown. src/index.test.ts
 * asserts the same fixtures the SQL test asserts.
 *
 * Money is integer paise everywhere. Never floats.
 */

export type RoundingStyle = "nearest" | "charm_9" | "multiple_5" | "multiple_10";

export type RetailTier = { below_paise?: number; multiplier: number };
export type QtyBreak   = { min_qty: number; pct_off_bp: number };

export type PricingFormula = {
  mode: "multiplier" | "buildup";

  // multiplier mode
  wholesale_markup_bp: number;
  retail_multiplier: number;
  mrp_multiplier: number;
  retail_tiers?: RetailTier[];

  // build-up mode (the owner's costing sheet)
  shipping_bp?: number;
  packing_flat_paise?: number;
  promotion_flat_paise?: number;
  reseller_bp?: number;
  customer_discount_bp?: number;
  mrp_bp?: number;

  retail_rounding: RoundingStyle;
  mrp_rounding: RoundingStyle;
  round_to_paise: number;

  qty_break_tiers?: QtyBreak[];
  wholesale_min_order_paise?: number;
};

export type PriceSet = {
  wholesale_paise: number;
  retail_paise: number;
  mrp_paise: number;
};

export type PriceTier = "wholesale" | "retail" | "mrp";

const bp = (n?: number) => 1 + (Number(n) || 0) / 10000;

export function roundStep(v: number, step: number): number {
  if (!step || step <= 0) return Math.round(v);
  return Math.round(v / step) * step;
}

/**
 * Round UP to the next whole rupee ending in 9. Never down: a charm price must
 * not dip below the formula output, or margin silently erodes.
 */
export function roundCharm9(v: number): number {
  if (!Number.isFinite(v) || v <= 0) return Math.round(v || 0);
  const rupees = Math.max(1, Math.round(v / 100));
  const bump = ((9 - (rupees % 10)) + 10) % 10;
  return (rupees + bump) * 100;
}

/**
 * Round to a whole rupee that is a multiple of n. `floorPaise` (used for MRP)
 * guarantees the printed MRP is never below the selling price.
 */
export function roundMultiple(v: number, n: number, floorPaise?: number): number {
  if (!Number.isFinite(v) || v <= 0) return Math.round(v || 0);
  let rupees = Math.round(v / 100 / n) * n;
  if (rupees <= 0) rupees = n;
  let out = rupees * 100;
  if (floorPaise != null && Number.isFinite(floorPaise) && out < floorPaise) {
    out = Math.ceil(Math.ceil(floorPaise / 100) / n) * n * 100;
  }
  return out;
}

export function applyRounding(v: number, style: RoundingStyle, step: number, floorPaise?: number): number {
  switch (style) {
    case "charm_9":     return roundCharm9(v);
    case "multiple_5":  return roundMultiple(v, 5, floorPaise);
    case "multiple_10": return roundMultiple(v, 10, floorPaise);
    default:            return roundStep(v, step);
  }
}

/** First matching band wins; a band with no `below_paise` is the catch-all. */
export function retailMultiplierFor(basePaise: number, f: PricingFormula): number {
  for (const t of f.retail_tiers ?? []) {
    if (t.below_paise == null || basePaise < t.below_paise) return t.multiplier;
  }
  return f.retail_multiplier;
}

export function computePrices(basePaise: number, f: PricingFormula): PriceSet {
  if (!Number.isFinite(basePaise) || basePaise <= 0) {
    return { wholesale_paise: NaN, retail_paise: NaN, mrp_paise: NaN };
  }
  let w: number, r: number, m: number;

  if (f.mode === "buildup") {
    w = basePaise;
    r = basePaise * bp(f.shipping_bp)
        + (f.packing_flat_paise ?? 0) + (f.promotion_flat_paise ?? 0);
    r = r * bp(f.reseller_bp);
    r = r * bp(f.customer_discount_bp);
    m = r * bp(f.mrp_bp);
  } else {
    w = basePaise * bp(f.wholesale_markup_bp);
    r = basePaise * retailMultiplierFor(basePaise, f);
    m = basePaise * f.mrp_multiplier;
  }

  const retail_paise = applyRounding(r, f.retail_rounding, f.round_to_paise);
  return {
    wholesale_paise: roundStep(w, f.round_to_paise),
    retail_paise,
    mrp_paise: applyRounding(m, f.mrp_rounding, f.round_to_paise, retail_paise),
  };
}

/** Best quantity break for a line, in basis points off. */
export function qtyBreakBp(f: PricingFormula, qty: number): number {
  let best = 0;
  for (const t of f.qty_break_tiers ?? []) {
    if (qty >= t.min_qty && t.pct_off_bp > best) best = t.pct_off_bp;
  }
  return Math.max(0, Math.min(10000, best));
}

export function applyBreak(unitPaise: number, pctOffBp: number): number {
  if (!pctOffBp) return unitPaise;
  return Math.max(0, Math.round(unitPaise * (1 - pctOffBp / 10000)));
}

/**
 * Never sell above the printed MRP; a wholesale buyer must always beat the
 * retail shopper. Kept from the legacy build - it caught real data errors.
 */
export function isValidPriceSet(p: PriceSet): boolean {
  const ok = (n: number) => Number.isFinite(n) && n > 0;
  return ok(p.wholesale_paise) && ok(p.retail_paise) && ok(p.mrp_paise)
      && p.retail_paise <= p.mrp_paise
      && p.wholesale_paise < p.retail_paise;
}

/** Explicit pins beat the formula. Order: variant -> product -> formula. */
export type PriceOverrides = Partial<Record<PriceTier, number | null>>;

export function resolvePrices(
  basePaise: number, f: PricingFormula, ...layers: (PriceOverrides | null | undefined)[]
): PriceSet {
  const c = computePrices(basePaise, f);
  const pick = (t: PriceTier, fallback: number) => {
    for (const l of layers) {
      const v = l?.[t];
      if (typeof v === "number" && Number.isFinite(v) && v > 0) return v;
    }
    return fallback;
  };
  return {
    wholesale_paise: pick("wholesale", c.wholesale_paise),
    retail_paise:    pick("retail",    c.retail_paise),
    mrp_paise:       pick("mrp",       c.mrp_paise),
  };
}

export function priceForTier(p: PriceSet, tier: PriceTier): number {
  return tier === "wholesale" ? p.wholesale_paise
       : tier === "retail"    ? p.retail_paise
       : p.mrp_paise;
}

export function tierForCustomer(customerType?: string | null): PriceTier {
  return customerType === "wholesale" ? "wholesale" : "retail";
}

/** Display only. Indian digit grouping. */
export function formatPaise(paise: number): string {
  if (!Number.isFinite(paise)) return "—";
  return "₹" + (paise / 100).toLocaleString("en-IN",
    { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}
