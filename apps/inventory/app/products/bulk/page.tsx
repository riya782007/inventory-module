"use client";
/**
 * Bulk Add — pattern studied from the Aggarwal build's BulkAddInventory:
 * common fields once, a row per product, blank rows skipped, in-batch
 * duplicate SKUs flagged live, and after save the FAILED rows stay in the
 * grid with their reason while successes leave. Improved here: the whole
 * batch is ONE database call with per-row savepoints, not N round trips.
 */
import { useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/browser";

type Row = {
  key: string;
  name: string; sku: string;
  cost: string; sell: string; mrp: string; qty: string;
  error?: string;
};
const newRow = (): Row => ({
  key: Math.random().toString(36).slice(2),
  name: "", sku: "", cost: "", sell: "", mrp: "", qty: "",
});
const toPaise = (s: string) => {
  const n = parseFloat(s); return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : null;
};
const isBlank = (r: Row) =>
  !r.name.trim() && !r.sku.trim() && !r.cost.trim() && !r.sell.trim() && !r.qty.trim();

export default function BulkAdd() {
  const router = useRouter();
  const [category, setCategory] = useState("");
  const [brand, setBrand] = useState("");
  const [rows, setRows] = useState<Row[]>([newRow(), newRow(), newRow(), newRow(), newRow()]);
  const [busy, setBusy] = useState(false);
  const [summary, setSummary] = useState<{ created: number; failed: number } | null>(null);

  const set = (i: number, patch: Partial<Row>) =>
    setRows(p => p.map((r, j) => j === i ? { ...r, ...patch, error: undefined } : r));
  const addRows = (n = 1) => setRows(p => [...p, ...Array.from({ length: n }, newRow)]);
  const removeRow = (i: number) =>
    setRows(p => (p.length > 1 ? p.filter((_, j) => j !== i) : [newRow()]));
  const duplicateRow = (i: number) => setRows(p => {
    const r = p[i];
    // copy values but FORCE a fresh SKU so two products never share a code
    const copy = { ...newRow(), name: r.name, cost: r.cost, sell: r.sell, mrp: r.mrp, qty: r.qty };
    return [...p.slice(0, i + 1), copy, ...p.slice(i + 1)];
  });

  // live validation — blank rows are skipped, not errors
  const skuCounts = useMemo(() => {
    const m = new Map<string, number>();
    for (const r of rows) {
      const s = r.sku.trim().toUpperCase();
      if (s) m.set(s, (m.get(s) ?? 0) + 1);
    }
    return m;
  }, [rows]);
  const problem = (r: Row): string | null => {
    if (isBlank(r)) return null;
    if (!r.name.trim()) return "Name required";
    const s = r.sku.trim().toUpperCase();
    if (s && (skuCounts.get(s) ?? 0) > 1) return "Duplicate SKU in this batch";
    return null;
  };
  const active = rows.filter(r => !isBlank(r));
  const ready = active.filter(r => !problem(r)).length;
  const errors = active.filter(r => problem(r)).length;

  async function saveAll() {
    if (!ready || errors) return;
    setBusy(true); setSummary(null);
    const payload = {
      rows: active.filter(r => !problem(r)).map(r => ({
        name: r.name.trim(),
        sku: r.sku.trim() || undefined,
        category: category.trim() || undefined,
        brand: brand.trim() || undefined,
        has_variants: false,
        base_cost_paise: toPaise(r.cost),
        selling_price_paise: toPaise(r.sell),
        mrp_paise: toPaise(r.mrp),
        opening_qty: parseFloat(r.qty) > 0 ? parseFloat(r.qty) : 0,
      })),
    };
    const { data, error } = await supabaseBrowser().schema("core")
      .rpc("create_products_bulk", { p: payload });
    setBusy(false);
    if (error) return alert(error.message);

    const out = data as { created: number; total: number;
      results: Array<{ row: number; ok: boolean; error?: string }> };
    // failed rows survive with their reason; successes leave the grid
    const sent = active.filter(r => !problem(r));
    const failed: Row[] = [];
    out.results.forEach(res => {
      if (!res.ok) failed.push({ ...sent[res.row], error: res.error ?? "Failed" });
    });
    const blanks = rows.filter(isBlank);
    setRows(failed.length || blanks.length ? [...failed, ...blanks] : [newRow()]);
    setSummary({ created: out.created, failed: out.total - out.created });
    if (!failed.length && out.created > 0) router.refresh();
  }

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Bulk add products</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            Each row becomes its own product with its own SKU, price and stock —
            never one product with a lumped quantity.
          </p>
        </div>
        <Link href="/products" className="btn ghost">Back to products</Link>
      </div>

      {summary && (
        <div className="panel" style={{ borderColor: summary.failed ? "rgba(251,191,36,.4)" : "rgba(16,185,129,.4)" }}>
          <span className="badge green">{summary.created} added</span>{" "}
          {summary.failed > 0 && <span className="badge red">{summary.failed} failed — fix the rows below and save again</span>}
        </div>
      )}

      <div className="panel">
        <h2>Common information (applied to every row)</h2>
        <div className="row">
          <div className="field"><label>Category</label>
            <input className="input" value={category} onChange={e => setCategory(e.target.value)} placeholder="Necklaces" /></div>
          <div className="field"><label>Brand</label>
            <input className="input" value={brand} onChange={e => setBrand(e.target.value)} /></div>
        </div>
      </div>

      <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
        <table className="table">
          <thead><tr>
            <th style={{ minWidth: 180 }}>Name *</th>
            <th style={{ minWidth: 110 }}>SKU (blank = auto)</th>
            <th className="num">Cost ₹</th>
            <th className="num">Sell ₹</th>
            <th className="num">MRP ₹</th>
            <th className="num">Opening qty</th>
            <th></th>
          </tr></thead>
          <tbody>
            {rows.map((r, i) => {
              const err = r.error ?? problem(r);
              return (
                <tr key={r.key} style={err && !isBlank(r) ? { outline: "1px solid rgba(248,113,113,.4)" } : undefined}>
                  <td>
                    <input className="input" value={r.name} placeholder={`Product ${i + 1}`}
                      onChange={e => set(i, { name: e.target.value })} />
                    {err && !isBlank(r) &&
                      <div style={{ color: "var(--red)", fontSize: 12, marginTop: 4 }}>{err}</div>}
                  </td>
                  <td><input className="input" value={r.sku} style={{ textTransform: "uppercase" }}
                    onChange={e => set(i, { sku: e.target.value })} /></td>
                  <td className="num"><input className="input" style={{ width: 84, textAlign: "right" }}
                    value={r.cost} inputMode="decimal" onChange={e => set(i, { cost: e.target.value })} /></td>
                  <td className="num"><input className="input" style={{ width: 84, textAlign: "right" }}
                    value={r.sell} inputMode="decimal" onChange={e => set(i, { sell: e.target.value })} /></td>
                  <td className="num"><input className="input" style={{ width: 84, textAlign: "right" }}
                    value={r.mrp} inputMode="decimal" onChange={e => set(i, { mrp: e.target.value })} /></td>
                  <td className="num"><input className="input" style={{ width: 84, textAlign: "right" }}
                    value={r.qty} inputMode="numeric"
                    onChange={e => set(i, { qty: e.target.value })}
                    onKeyDown={e => { if (e.key === "Enter" && i === rows.length - 1) addRows(1); }} /></td>
                  <td className="num" style={{ whiteSpace: "nowrap" }}>
                    <button className="btn ghost sm" title="Duplicate (fresh SKU)"
                      onClick={() => duplicateRow(i)} style={{ marginRight: 6 }}>⧉</button>
                    <button className="btn danger sm" onClick={() => removeRow(i)}>×</button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="row" style={{ marginTop: 16, justifyContent: "space-between" }}>
        <div className="row">
          <button className="btn ghost sm" onClick={() => addRows(1)}>+ Row</button>
          <button className="btn ghost sm" onClick={() => addRows(5)}>+ 5 rows</button>
        </div>
        <div className="row">
          <span className="sub" style={{ margin: 0 }}>
            {ready} ready{errors ? ` · ${errors} with errors` : ""}
          </span>
          <button className="btn" disabled={busy || !ready || errors > 0} onClick={saveAll}>
            {busy ? "Saving…" : `Save ${ready} product${ready === 1 ? "" : "s"}`}
          </button>
        </div>
      </div>
    </>
  );
}
