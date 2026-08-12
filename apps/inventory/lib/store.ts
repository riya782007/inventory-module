"use client";
/**
 * DEMO repository — localStorage, this browser only.
 *
 * This file is the ONLY thing that changes when Supabase is connected: the
 * hook keeps its signature and the Supabase implementation takes over. The
 * ledger discipline is identical to the DB: stock is never stored, it is
 * DERIVED from the sum of movements, and movements are append-only.
 */
import { useSyncExternalStore, useCallback } from "react";
import type { Product, Movement } from "./types";

const KEY = "newvora.inventory.demo.v1";

type DB = { products: Product[]; movements: Movement[] };
const EMPTY: DB = { products: [], movements: [] };

let cache: DB | null = null;
const listeners = new Set<() => void>();

function read(): DB {
  if (cache) return cache;
  if (typeof window === "undefined") return EMPTY;
  try { cache = JSON.parse(localStorage.getItem(KEY) ?? "") as DB; }
  catch { cache = { ...EMPTY }; }
  if (!cache || !Array.isArray(cache.products)) cache = { products: [], movements: [] };
  return cache;
}
function write(mut: (db: DB) => void) {
  const db = structuredClone(read());
  mut(db);
  cache = db;
  localStorage.setItem(KEY, JSON.stringify(db));
  listeners.forEach((l) => l());
}
function subscribe(l: () => void) { listeners.add(l); return () => { listeners.delete(l); }; }

export const uid = () =>
  (crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2)) as string;

export function useDB(): DB {
  return useSyncExternalStore(subscribe, read, () => EMPTY);
}

export function useRepo() {
  const addProduct = useCallback((p: Product) => write((db) => { db.products.unshift(p); }), []);
  const archiveProduct = useCallback((id: string) => write((db) => {
    const p = db.products.find((x) => x.id === id); if (p) p.status = "archived";
  }), []);
  /** The only way stock changes — mirrors inventory.post_movement. */
  const postMovement = useCallback((m: Omit<Movement, "id" | "occurred_at">) => {
    if (!m.qty_delta) return;
    write((db) => {
      db.movements.unshift({ ...m, id: uid(), occurred_at: new Date().toISOString() });
    });
  }, []);
  const reset = useCallback(() => write((db) => { db.products = []; db.movements = []; }), []);
  return { addProduct, archiveProduct, postMovement, reset };
}

/** Balance = Σ ledger. Never stored. Cannot drift. */
export function balanceOf(movements: Movement[], variantId: string): number {
  let s = 0;
  for (const m of movements) if (m.variant_id === variantId) s += m.qty_delta;
  return s;
}
