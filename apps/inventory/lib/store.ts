"use client";
/**
 * LIVE repository — Supabase, RLS enforced with the signed-in user's JWT.
 * Replaces the localStorage demo. The hook surface (useDB / useRepo /
 * balanceOf) is unchanged, so the pages did not have to change shape.
 *
 * Ledger discipline is identical to before: stock is DERIVED from movements;
 * writes go through inventory.post_movement, which refuses oversell and
 * forged org ids at the database layer.
 */
import { useCallback, useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/browser";
import type { Product, Movement, ProductOption, Variant } from "./types";

export type NewProductPayload = {
  name: string; brand?: string; category?: string; hsn_sac?: string;
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

type DB = { products: Product[]; movements: Movement[]; loading: boolean };
let version = 0;
const bump = () => { version++; listeners.forEach((l) => l()); };
const listeners = new Set<() => void>();

async function fetchAll(): Promise<Omit<DB, "loading">> {
  const supa = supabaseBrowser();
  const [prod, mov] = await Promise.all([
    supa.schema("core").from("products")
      .select(`id, name, hsn_sac, has_variants, status, created_at,
               brands ( name ), categories ( name ),
               product_options ( name, position, product_option_values ( value, position ) ),
               product_variants ( id, sku, attributes, is_default,
                 base_cost_paise, selling_price_paise, mrp_paise )`)
      .order("created_at", { ascending: false }),
    supa.schema("inventory").from("stock_movements")
      .select("id, variant_id, qty_delta, reason, note, occurred_at")
      .order("occurred_at", { ascending: false }).limit(500),
  ]);
  if (prod.error) throw prod.error;
  if (mov.error) throw mov.error;

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
  const movements: Movement[] = (mov.data ?? []).map((m: any) => ({
    id: String(m.id), variant_id: m.variant_id, qty_delta: Number(m.qty_delta),
    reason: m.reason, note: m.note, occurred_at: m.occurred_at,
  }));
  return { products, movements };
}

export function useDB(): DB {
  const [db, setDb] = useState<DB>({ products: [], movements: [], loading: true });
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

async function orgAndLocation() {
  const supa = supabaseBrowser();
  const { data: { session } } = await supa.auth.getSession();
  const orgId = (session?.user?.app_metadata as any)?.org_id as string | undefined;
  const { data: loc } = await supa.schema("inventory").from("locations")
    .select("id").eq("is_default", true).limit(1).maybeSingle();
  return { orgId, locationId: loc?.id as string | undefined };
}

export function useRepo() {
  const createProduct = useCallback(async (payload: NewProductPayload) => {
    const { error } = await supabaseBrowser().schema("core")
      .rpc("create_product", { p: payload });
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
    variant_id: string; qty_delta: number; reason: string; note: string | null;
  }) => {
    const { orgId, locationId } = await orgAndLocation();
    if (!orgId || !locationId) throw new Error("No organization or location");
    const { error } = await supabaseBrowser().schema("inventory")
      .rpc("post_movement", {
        p_org: orgId, p_variant: m.variant_id, p_location: locationId,
        p_delta: m.qty_delta, p_reason: m.reason, p_note: m.note,
      });
    if (error) throw new Error(error.message);
    bump();
  }, []);

  const signOut = useCallback(async () => {
    await supabaseBrowser().auth.signOut();
    window.location.href = "/login";
  }, []);

  return { createProduct, archiveProduct, postMovement, signOut };
}

/** Balance = Σ ledger (client-side over the fetched window). */
export function balanceOf(movements: Movement[], variantId: string): number {
  let s = 0;
  for (const m of movements) if (m.variant_id === variantId) s += m.qty_delta;
  return s;
}
