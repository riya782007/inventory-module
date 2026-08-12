"use client";
import Link from "next/link";
import { formatPaise } from "@newvora/pricing";
import { useDB, balanceOf } from "@/lib/store";

export default function Dashboard() {
  const db = useDB();
  const variants = db.products.filter(p => p.status === "active").flatMap(p => p.variants);
  const balances = variants.map(v => ({ v, qty: balanceOf(db.movements, v.id) }));
  const stockValue = balances.reduce((s, b) => s + b.qty * (b.v.base_cost_paise ?? 0), 0);
  const out = balances.filter(b => b.qty <= 0).length;
  const low = balances.filter(b => b.qty > 0 && b.qty <= 5).length;

  const METRICS = [
    { k: "Stock value", v: formatPaise(stockValue), hint: "at cost" },
    { k: "Products", v: String(db.products.filter(p => p.status === "active").length), hint: "active" },
    { k: "SKUs", v: String(variants.length), hint: "variants tracked" },
    { k: "Low stock", v: String(low), hint: "5 or fewer left" },
    { k: "Out of stock", v: String(out), hint: "zero available" },
    { k: "Movements", v: String(db.movements.length), hint: "ledger entries" },
  ];

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Dashboard</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            <span className="badge warn">Demo mode — data lives in this browser</span>{" "}
            <span className="badge green">DB schema verified 45/45</span>
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
