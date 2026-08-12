/**
 * Client-side mirrors of the core/inventory schema (supabase/migrations).
 * Field names match the DB columns 1:1 so the demo repository and the coming
 * Supabase repository are interchangeable.
 */
export type ProductOption = { name: string; values: string[] };

export type Variant = {
  id: string;
  sku: string;
  attributes: Record<string, string>;   // {"Size":"M","Colour":"Black"}
  is_default: boolean;
  base_cost_paise: number | null;
  selling_price_paise: number | null;
  mrp_paise: number | null;
};

export type Product = {
  id: string;
  name: string;
  category: string | null;
  brand: string | null;
  hsn_sac: string | null;
  has_variants: boolean;
  options: ProductOption[];
  variants: Variant[];
  status: "active" | "archived";
  created_at: string;
};

/** Mirrors inventory.stock_movements — append-only, signed deltas. */
export type Movement = {
  id: string;
  variant_id: string;
  qty_delta: number;
  reason: "opening" | "purchase" | "sale" | "sale_return" | "adjustment"
        | "damage" | "expiry" | "theft" | "count_correction";
  note: string | null;
  occurred_at: string;
};

export const REASONS_IN  = ["opening", "purchase", "sale_return", "count_correction"] as const;
export const REASONS_OUT = ["sale", "adjustment", "damage", "expiry", "theft"] as const;
