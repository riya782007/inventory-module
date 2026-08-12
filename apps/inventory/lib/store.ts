"use client";
/**
 * LIVE repository — Supabase under the signed-in user's JWT, RLS enforced.
 * Balances come from inventory.stock_balances (trigger-maintained cache of
 * the ledger), movements are fetched only for history views.
 */
import { useCallback, useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/browser";
import type { Product, Movement, ProductOption, Variant, Location, Balance } from "./types";

export type NewProductPayload = {
  name: string; sku?: string; brand?: string; category?: string; hsn_sac?: string;
  description?: string;
  has_variants: boolean;
  options?: ProductOption[];
  variants?: Array<{
    attributes: Record<string, string>;
    base_cost_paise: number | null; selling_price_paise: number | null;
    mrp_paise: number | null; opening_qty: number; is_default?: boolean;
  }>;
  base_cost_paise?: number | null; selling_price_paise?: number | null;
  mrp_paise?: number | null; opening_qty?: number;
};

type DB = {
  products: Product[]; movements: Movement[];
  balances: Balance[]; locations: Location[];
  reorder: Record<string, number>;           // `${variant_id}:${location_id}` -> min_qty
  loading: boolean;
};
const listeners = new Set<() => void>();
const bump = () => listeners.forEach((l) => l());

async function fetchAll(): Promise<Omit<DB, "loading">> {
  const supa = supabaseBrowser();
  const [prod, mov, bal, loc, ror] = await Promise.all([
    supa.schema("core").from("products")
      .select(`id, name, hsn_sac, has_variants, status, created_at,
               brands ( name ), categories ( name ),
               product_options ( name, position, product_option_values ( value, position ) ),
               product_variants ( id, sku, attributes, is_default, status,
                 base_cost_paise, selling_price_paise, mrp_paise )`)
      .order("created_at", { ascending: false }),
    supa.schema("inventory").from("stock_movements")
      .select("id, variant_id, location_id, qty_delta, reason, note, occurred_at")
      .order("occurred_at", { ascending: false }).limit(500),
    supa.schema("inventory").from("stock_balances")
      .select("variant_id, location_id, qty_on_hand, qty_reserved, qty_available, moving_avg_cost_paise"),
    supa.schema("inventory").from("locations")
      .select("id, name, type, is_default").eq("status", "active").order("is_default", { ascending: false }),
    supa.schema("inventory").from("reorder_rules")
      .select("variant_id, location_id, min_qty"),
  ]);
  for (const r of [prod, mov, bal, loc, ror]) if (r.error) throw r.error;

  const products: Product[] = (prod.data ?? []).map((p: any) => ({
    id: p.id, name: p.name,
    brand: p.brands?.name ?? null, category: p.categories?.name ?? null,
    hsn_sac: p.hsn_sac, has_variants: p.has_variants, status: p.status,
    created_at: p.created_at,
    options: (p.product_options ?? [])
      .sort((a: any, b: any) => a.position - b.position)
      .map((o: any): ProductOption => ({
        name: o.name,
        values: (o.product_option_values ?? [])
          .sort((a: any, b: any) => a.position - b.position)
          .map((v: any) => v.value),
      })),
    variants: (p.product_variants ?? []).map((v: any): Variant => ({
      id: v.id, sku: v.sku, attributes: v.attributes ?? {},
      is_default: v.is_default,
      base_cost_paise: v.base_cost_paise,
      selling_price_paise: v.selling_price_paise, mrp_paise: v.mrp_paise,
    })),
  }));
  const reorder: Record<string, number> = {};
  (ror.data ?? []).forEach((r: any) => {
    reorder[`${r.variant_id}:${r.location_id}`] = Number(r.min_qty);
  });
  return {
    products,
    movements: (mov.data ?? []).map((m: any) => ({
      id: String(m.id), variant_id: m.variant_id, location_id: m.location_id,
      qty_delta: Number(m.qty_delta), reason: m.reason, note: m.note,
      occurred_at: m.occurred_at,
    })),
    balances: (bal.data ?? []).map((b: any) => ({
      variant_id: b.variant_id, location_id: b.location_id,
      qty_on_hand: Number(b.qty_on_hand), qty_reserved: Number(b.qty_reserved),
      qty_available: Number(b.qty_available),
      moving_avg_cost_paise: b.moving_avg_cost_paise,
    })),
    locations: (loc.data ?? []) as Location[],
    reorder,
  };
}

export function useDB(): DB {
  const [db, setDb] = useState<DB>({
    products: [], movements: [], balances: [], locations: [], reorder: {}, loading: true,
  });
  useEffect(() => {
    let live = true;
    const load = () =>
      fetchAll()
        .then((d) => live && setDb({ ...d, loading: false }))
        .catch(() => live && setDb((s) => ({ ...s, loading: false })));
    load();
    const l = () => load();
    listeners.add(l);
    return () => { live = false; listeners.delete(l); };
  }, []);
  return db;
}

async function orgId(): Promise<string> {
  const { data: { session } } = await supabaseBrowser().auth.getSession();
  const id = (session?.user?.app_metadata as any)?.org_id as string | undefined;
  if (!id) throw new Error("No organization in session");
  return id;
}

export function useRepo() {
  const createProduct = useCallback(async (payload: NewProductPayload) => {
    const { error } = await supabaseBrowser().schema("core")
      .rpc("create_product_v2", { p: payload });
    if (error) throw new Error(error.message);
    bump();
  }, []);

  const updateProduct = useCallback(async (id: string, patch: {
    name?: string; hsn_sac?: string | null; status?: string;
  }) => {
    const { error } = await supabaseBrowser().schema("core")
      .from("products").update(patch).eq("id", id);
    if (error) throw new Error(error.message);
    bump();
  }, []);

  const updateVariant = useCallback(async (id: string, patch: {
    sku?: string; base_cost_paise?: number | null;
    selling_price_paise?: number | null; mrp_paise?: number | null;
  }) => {
    const { error } = await supabaseBrowser().schema("core")
      .from("product_variants").update(patch).eq("id", id);
    if (error) throw new Error(error.message);
    bump();
  }, []);

  const archiveProduct = useCallback(async (id: string) => {
    const { error } = await supabaseBrowser().schema("core")
      .from("products").update({ status: "archived" }).eq("id", id);
    if (error) throw new Error(error.message);
    bump();
  }, []);

  const postMovement = useCallback(async (m: {
    variant_id: string; location_id: string; qty_delta: number;
    reason: string; note: string | null;
  }) => {
    const { error } = await supabaseBrowser().schema("inventory")
      .rpc("post_movement", {
        p_org: await orgId(), p_variant: m.variant_id, p_location: m.location_id,
        p_delta: m.qty_delta, p_reason: m.reason, p_note: m.note,
      });
    if (error) throw new Error(error.message);
    bump();
  }, []);

  const rpc = useCallback(async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await supabaseBrowser().schema("inventory").rpc(fn, args);
    if (error) throw new Error(error.message);
    bump();
    return data;
  }, []);

  const addLocation = useCallback(async (name: string, type: string) => {
    const { error } = await supabaseBrowser().schema("inventory")
      .from("locations").insert({ org_id: await orgId(), name, type });
    if (error) throw new Error(error.message);
    bump();
  }, []);

  const signOut = useCallback(async () => {
    await supabaseBrowser().auth.signOut();
    window.location.href = "/login";
  }, []);

  return { createProduct, updateProduct, updateVariant, archiveProduct,
           postMovement, rpc, addLocation, signOut, refresh: bump };
}

/** On-hand at one location, or across all when location is omitted. */
export function balanceAt(balances: { variant_id: string; location_id: string; qty_on_hand: number }[],
                          variantId: string, locationId?: string): number {
  let s = 0;
  for (const b of balances)
    if (b.variant_id === variantId && (!locationId || b.location_id === locationId))
      s += b.qty_on_hand;
  return s;
}
