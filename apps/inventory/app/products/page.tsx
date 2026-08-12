"use client";
import Link from "next/link";
import { useState } from "react";
import { formatPaise } from "@newvora/pricing";
import { useDB, useRepo, balanceAt, imageUrl } from "@/lib/store";

export default function Products() {
  const db = useDB();
  const { archiveProduct } = useRepo();
  const [q, setQ] = useState("");

  const products = db.products.filter(p =>
    p.status === "active" &&
    (q.trim() === "" ||
      p.name.toLowerCase().includes(q.toLowerCase()) ||
      p.variants.some(v => v.sku.toLowerCase().includes(q.toLowerCase()))));

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Products</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            One product master — Inventory, Catalogue and future POS all read it.
          </p>
        </div>
        <div className="row">
          <Link href="/products/labels" className="btn ghost">Labels</Link>
          <Link href="/products/import" className="btn ghost">Import file</Link>
          <Link href="/products/bulk" className="btn ghost">Bulk add</Link>
          <Link href="/products/new" className="btn">+ Add product</Link>
        </div>
      </div>

      <div className="row" style={{ marginBottom: 16 }}>
        <input className="input searchbar" placeholder="Search name or SKU…"
          value={q} onChange={(e) => setQ(e.target.value)} />
      </div>

      {db.loading ? (
        <div className="empty">Loading…</div>
      ) : products.length === 0 ? (
        <div className="empty">
          <b>{q ? "No matches" : "No products yet"}</b>
          {q ? "Try a different name or SKU." : "Add your first product to get started."}
        </div>
      ) : (
        <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
          <table className="table">
            <thead><tr>
              <th>Product</th><th>Variants</th><th>SKUs</th>
              <th className="num">Stock</th><th className="num">Selling price</th><th></th>
            </tr></thead>
            <tbody>
              {products.map(p => {
                const qty = p.variants.reduce((s, v) => s + balanceAt(db.balances, v.id), 0);
                const prices = p.variants.map(v => v.selling_price_paise).filter((x): x is number => x != null);
                const price = prices.length
                  ? (Math.min(...prices) === Math.max(...prices)
                      ? formatPaise(prices[0])
                      : `${formatPaise(Math.min(...prices))} – ${formatPaise(Math.max(...prices))}`)
                  : "—";
                return (
                  <tr key={p.id}>
                    <td>
                      <div className="row" style={{ flexWrap: "nowrap", gap: 10, alignItems: "center" }}>
                        {p.images[0] ? (
                          /* eslint-disable-next-line @next/next/no-img-element */
                          <img src={imageUrl(p.images[0].storage_path)} alt=""
                            style={{ width: 38, height: 38, objectFit: "cover",
                                     borderRadius: 8, border: "1px solid var(--line)" }} />
                        ) : (
                          <div style={{ width: 38, height: 38, borderRadius: 8,
                            background: "var(--panel2)", border: "1px solid var(--line)",
                            display: "flex", alignItems: "center", justifyContent: "center",
                            color: "var(--dim)", fontSize: 15, flexShrink: 0 }}>
                            {p.name.slice(0, 1).toUpperCase()}
                          </div>
                        )}
                        <div>
                          <Link href={`/products/${p.id}`} style={{ fontWeight: 600, color: "var(--accent-soft)" }}>{p.name}</Link>
                          <div className="dim" style={{ fontSize: 12 }}>
                            {[p.brand, p.category].filter(Boolean).join(" · ") || "—"}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td>{p.has_variants
                      ? p.options.map(o => `${o.name} (${o.values.length})`).join(", ")
                      : <span className="dim">simple</span>}</td>
                    <td className="mono">{p.variants.length}</td>
                    <td className={"num mono " + (qty <= 0 ? "" : "")}>
                      {qty <= 0 ? <span className="badge red">out</span> : qty}
                    </td>
                    <td className="num mono">{price}</td>
                    <td className="num">
                      <button className="btn danger sm" onClick={() => archiveProduct(p.id).catch(e => alert(e.message))}>Archive</button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
