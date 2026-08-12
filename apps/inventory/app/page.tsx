"use client";
import Link from "next/link";
import { formatPaise } from "@newvora/pricing";
import { useDB, balanceAt } from "@/lib/store";

export default function Dashboard() {
  const db = useDB();
  const variants = db.products.filter(p => p.status === "active").flatMap(p => p.variants);
  const totals = variants.map(v => ({ v, qty: balanceAt(db.balances, v.id) }));
  const stockValue = db.balances.reduce((s, b) => {
    const v = variants.find(x => x.id === b.variant_id);
    return s + Math.round(b.qty_on_hand * (b.moving_avg_cost_paise ?? v?.base_cost_paise ?? 0));
  }, 0);
  const out = totals.filter(b => b.qty <= 0).length;
  const low = totals.filter(b => {
    if (b.qty <= 0) return false;
    const mins = Object.entries(db.reorder)
      .filter(([k]) => k.startsWith(b.v.id + ":")).map(([, n]) => n);
    return mins.length > 0 && b.qty <= Math.max(...mins);
  }).length;

  const METRICS = [
    { k: "Stock value", v: formatPaise(stockValue), hint: "at cost" },
    { k: "Products", v: String(db.products.filter(p => p.status === "active").length), hint: "active" },
    { k: "SKUs", v: String(variants.length), hint: "variants tracked" },
    { k: "Low stock", v: String(low), hint: "at or below min level" },
    { k: "Out of stock", v: String(out), hint: "zero available" },
    { k: "Movements", v: String(db.movements.length), hint: "ledger entries" },
  ];

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Dashboard</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            <span className="badge green">Live — connected to Supabase</span>
          </p>
        </div>
        <Link href="/products/new" className="btn">+ Add product</Link>
      </div>
      <div className="grid">
        {METRICS.map((m) => (
          <div className="card" key={m.k}>
            <div className="k">{m.k}</div>
            <div className="v">{m.v}</div>
            <div className="hint">{m.hint}</div>
          </div>
        ))}
      </div>
      {db.products.length === 0 && (
        <div className="empty" style={{ marginTop: 18 }}>
          <b>Start with your first product</b>
          Add a product with variants — sizes, colours, designs — and stock it
          from the Stock page. Every change is a ledger entry.
          <div style={{ marginTop: 14 }}>
            <Link href="/products/new" className="btn">Add product</Link>
          </div>
        </div>
      )}
    </>
  );
}
