/**
 * Client-side mirrors of the core/inventory schema (supabase/migrations).
 * Field names match the DB columns 1:1 so the demo repository and the coming
 * Supabase repository are interchangeable.
 */
export type ProductOption = { name: string; values: string[] };

export type Variant = {
  id: string;
  sku: string;
  barcodes: string[];
  attributes: Record<string, string>;   // {"Size":"M","Colour":"Black"}
  is_default: boolean;
  base_cost_paise: number | null;
  selling_price_paise: number | null;
  mrp_paise: number | null;
};

export type ProductImage = { id: string; storage_path: string; variant_id: string | null; position: number };

export type Product = {
  id: string;
  images: ProductImage[];
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

export type Location = { id: string; name: string; type: string; is_default: boolean };

export type Balance = {
  variant_id: string; location_id: string;
  qty_on_hand: number; qty_reserved: number; qty_available: number;
  moving_avg_cost_paise: number | null;
};

/** Mirrors inventory.stock_movements — append-only, signed deltas. */
export type Movement = {
  id: string;
  variant_id: string;
  location_id: string;
  qty_delta: number;
  reason: "opening" | "purchase" | "sale" | "sale_return" | "adjustment"
        | "damage" | "expiry" | "theft" | "count_correction";
  note: string | null;
  occurred_at: string;
};

export const REASONS_IN  = ["opening", "purchase", "sale_return", "count_correction"] as const;
export const REASONS_OUT = ["sale", "adjustment", "damage", "expiry", "theft"] as const;
