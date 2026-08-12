"use client";
import { useMemo, useState } from "react";
import { formatPaise } from "@newvora/pricing";
import { useDB, balanceAt } from "@/lib/store";

type Tab = "valuation" | "low" | "movements";

function downloadCsv(name: string, header: string[], rows: (string | number)[][]) {
  const esc = (c: string | number) => `"${String(c).replace(/"/g, '""')}"`;
  const body = [header, ...rows].map(r => r.map(esc).join(",")).join("\n");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob(["﻿" + body], { type: "text/csv;charset=utf-8" }));
  a.download = name; a.click();
}

export default function Reports() {
  const db = useDB();
  const [tab, setTab] = useState<Tab>("valuation");
  const locName = (id: string) => db.locations.find(l => l.id === id)?.name ?? "?";
  const vInfo = useMemo(() => {
    const m = new Map<string, { product: string; sku: string; label: string; cost: number | null }>();
    for (const p of db.products) for (const v of p.variants)
      m.set(v.id, {
        product: p.name, sku: v.sku,
        label: Object.values(v.attributes).join("/"),
        cost: v.base_cost_paise,
      });
    return m;
  }, [db.products]);

  // ── valuation: per location, qty × moving average cost (fallback: variant cost)
  const valuation = useMemo(() => {
    const rows = db.balances
      .filter(b => b.qty_on_hand !== 0 && vInfo.has(b.variant_id))
      .map(b => {
        const v = vInfo.get(b.variant_id)!;
        const unit = b.moving_avg_cost_paise ?? v.cost ?? 0;
        return { ...b, ...v, unit, value: Math.round(b.qty_on_hand * unit) };
      })
      .sort((a, b) => b.value - a.value);
    const total = rows.reduce((s, r) => s + r.value, 0);
    return { rows, total };
  }, [db.balances, vInfo]);

  // ── low & out of stock (min level when set, else out-only)
  const low = useMemo(() => {
    const out: Array<{ id: string; product: string; sku: string; label: string; qty: number; min: number | null; status: string }> = [];
    for (const p of db.products.filter(p => p.status === "active"))
      for (const v of p.variants) {
        const qty = balanceAt(db.balances, v.id);
        const mins = Object.entries(db.reorder)
          .filter(([k]) => k.startsWith(v.id + ":")).map(([, n]) => n);
        const min = mins.length ? Math.max(...mins) : null;
        if (qty <= 0) out.push({ id: v.id, product: p.name, sku: v.sku,
          label: Object.values(v.attributes).join("/"), qty, min, status: "out" });
        else if (min != null && qty <= min) out.push({ id: v.id, product: p.name, sku: v.sku,
          label: Object.values(v.attributes).join("/"), qty, min, status: "low" });
      }
    return out.sort((a, b) => a.qty - b.qty);
  }, [db.products, db.balances, db.reorder]);

  const TABS: Array<[Tab, string]> = [
    ["valuation", "Stock valuation"], ["low", "Low & out of stock"], ["movements", "Movement log"],
  ];

  return (
    <>
      <h1>Reports</h1>
      <p className="sub">Everything derives from the ledger — export any view as CSV.</p>
      <div className="row" style={{ marginBottom: 16 }}>
        {TABS.map(([k, label]) => (
          <button key={k} className={tab === k ? "btn sm" : "btn ghost sm"} onClick={() => setTab(k)}>
            {label}
          </button>
        ))}
      </div>

      {db.loading ? <div className="empty">Loading…</div> : <>
        {tab === "valuation" && (
          <>
            <div className="row" style={{ justifyContent: "space-between", marginBottom: 12 }}>
              <span className="badge green">Total stock value {formatPaise(valuation.total)}</span>
              <button className="btn ghost sm" onClick={() =>
                downloadCsv("stock-valuation.csv",
                  ["Product", "Variant", "SKU", "Location", "Qty", "Unit cost ₹", "Value ₹"],
                  valuation.rows.map(r => [r.product, r.label, r.sku, locName(r.location_id),
                    r.qty_on_hand, (r.unit / 100).toFixed(2), (r.value / 100).toFixed(2)]))
              }>Export CSV</button>
            </div>
            <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
              <table className="table">
                <thead><tr><th>Product</th><th>SKU</th><th>Location</th>
                  <th className="num">Qty</th><th className="num">Unit cost</th><th className="num">Value</th></tr></thead>
                <tbody>
                  {valuation.rows.map((r, i) => (
                    <tr key={i}>
                      <td>{r.product}{r.label && <span className="dim"> · {r.label}</span>}</td>
                      <td className="mono dim">{r.sku}</td>
                      <td>{locName(r.location_id)}</td>
                      <td className="num mono">{r.qty_on_hand}</td>
                      <td className="num mono">{formatPaise(r.unit)}</td>
                      <td className="num mono" style={{ fontWeight: 600 }}>{formatPaise(r.value)}</td>
                    </tr>
                  ))}
                  {valuation.rows.length === 0 && <tr><td className="dim">No stock yet.</td></tr>}
                </tbody>
              </table>
            </div>
          </>
        )}

        {tab === "low" && (
          <>
            <div className="row" style={{ justifyContent: "flex-end", marginBottom: 12 }}>
              <button className="btn ghost sm" onClick={() =>
                downloadCsv("low-stock.csv", ["Product", "Variant", "SKU", "Qty", "Min level", "Status"],
                  low.map(r => [r.product, r.label, r.sku, r.qty, r.min ?? "", r.status]))
              }>Export CSV</button>
            </div>
            <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
              <table className="table">
                <thead><tr><th>Product</th><th>SKU</th>
                  <th className="num">On hand</th><th className="num">Min level</th><th>Status</th></tr></thead>
                <tbody>
                  {low.map(r => (
                    <tr key={r.id}>
                      <td>{r.product}{r.label && <span className="dim"> · {r.label}</span>}</td>
                      <td className="mono dim">{r.sku}</td>
                      <td className="num mono">{r.qty}</td>
                      <td className="num mono">{r.min ?? "—"}</td>
                      <td>{r.status === "out"
                        ? <span className="badge red">out of stock</span>
                        : <span className="badge warn">low</span>}</td>
                    </tr>
                  ))}
                  {low.length === 0 && <tr><td className="dim">
                    Nothing low. Set min levels on a product page to get warnings before you run out.</td></tr>}
                </tbody>
              </table>
            </div>
          </>
        )}

        {tab === "movements" && (
          <>
            <div className="row" style={{ justifyContent: "flex-end", marginBottom: 12 }}>
              <button className="btn ghost sm" onClick={() =>
                downloadCsv("movements.csv", ["Time", "Product", "SKU", "Location", "Reason", "Qty", "Note"],
                  db.movements.map(m => {
                    const v = vInfo.get(m.variant_id);
                    return [new Date(m.occurred_at).toLocaleString("en-IN"),
                      v?.product ?? "?", v?.sku ?? "?", locName(m.location_id),
                      m.reason, m.qty_delta, m.note ?? ""];
                  }))
              }>Export CSV (last 500)</button>
            </div>
            <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
              <table className="table">
                <thead><tr><th>Time</th><th>Product</th><th>Location</th>
                  <th>Reason</th><th className="num">Qty</th><th>Note</th></tr></thead>
                <tbody>
                  {db.movements.slice(0, 100).map(m => {
                    const v = vInfo.get(m.variant_id);
                    return (
                      <tr key={m.id}>
                        <td className="dim" style={{ whiteSpace: "nowrap" }}>
                          {new Date(m.occurred_at).toLocaleString("en-IN", { dateStyle: "medium", timeStyle: "short" })}</td>
                        <td>{v?.product ?? "?"} <span className="mono dim">{v?.sku}</span></td>
                        <td className="dim">{locName(m.location_id)}</td>
                        <td>{m.reason.replace(/_/g, " ")}</td>
                        <td className="num mono" style={{ color: m.qty_delta > 0 ? "#34D399" : "var(--red)" }}>
                          {m.qty_delta > 0 ? "+" : ""}{m.qty_delta}</td>
                        <td className="dim">{m.note ?? ""}</td>
                      </tr>
                    );
                  })}
                  {db.movements.length === 0 && <tr><td className="dim">No movements yet.</td></tr>}
                </tbody>
              </table>
            </div>
          </>
        )}
      </>}
    </>
  );
}
