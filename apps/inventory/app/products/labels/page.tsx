"use client";
/**
 * Barcode label sheets — pattern from the Yogendra build's /admin/barcodes:
 * search items, set how many labels each, print a sheet for a tag gun or
 * label printer. Labels carry name, SKU (as Code-128) and MRP/price.
 */
import { useMemo, useState } from "react";
import Link from "next/link";
import { formatPaise } from "@newvora/pricing";
import { barcodeSvg } from "@/lib/barcode";
import { useDB } from "@/lib/store";

export default function Labels() {
  const db = useDB();
  const [q, setQ] = useState("");
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [showPrice, setShowPrice] = useState(true);

  const items = useMemo(() =>
    db.products.filter(p => p.status === "active").flatMap(p =>
      p.variants.map(v => ({
        id: v.id, sku: v.sku,
        name: p.name + (Object.values(v.attributes).length ? " · " + Object.values(v.attributes).join("/") : ""),
        price: v.mrp_paise ?? v.selling_price_paise,
        code: v.barcodes[0] ?? v.sku,       // prefer a registered EAN, else SKU
      }))
    ), [db.products]);

  const visible = items.filter(i =>
    !q.trim() || i.name.toLowerCase().includes(q.toLowerCase())
    || i.sku.toLowerCase().includes(q.toLowerCase()));

  const sheet = items.flatMap(i => Array(counts[i.id] ?? 0).fill(i));

  return (
    <>
      <style>{`
        @media print {
          .no-print, .sidebar { display: none !important; }
          .main { padding: 0 !important; max-width: none !important; }
          body { background: #fff !important; }
          .label-grid { gap: 2mm !important; }
          .label {
            border: 1px dashed #bbb !important; background: #fff !important;
            break-inside: avoid;
          }
          .label * { color: #000 !important; }
        }
        .label-grid {
          display: grid; grid-template-columns: repeat(auto-fill, minmax(48mm, 1fr));
          gap: 8px;
        }
        .label {
          background: #fff; color: #000; border-radius: 4px;
          padding: 6px 8px; text-align: center; overflow: hidden;
        }
        .label .nm { font-size: 10px; font-weight: 600; color: #000;
          white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .label .sk { font-size: 10px; color: #333; letter-spacing: 1px; }
        .label .pr { font-size: 12px; font-weight: 700; color: #000; }
      `}</style>

      <div className="no-print">
        <div className="topbar">
          <div>
            <h1>Barcode labels</h1>
            <p className="sub" style={{ marginBottom: 0 }}>
              Code-128, scannable by any ₹1,500 USB scanner. Registered barcodes
              are used when present, otherwise the SKU.
            </p>
          </div>
          <div className="row">
            <Link href="/products" className="btn ghost">Back</Link>
            <button className="btn" disabled={sheet.length === 0}
              onClick={() => window.print()}>Print {sheet.length || ""} labels</button>
          </div>
        </div>

        <div className="row" style={{ marginBottom: 14 }}>
          <input className="input searchbar" placeholder="Search name or SKU…"
            value={q} onChange={e => setQ(e.target.value)} />
          <label className="sub" style={{ margin: 0, cursor: "pointer" }}>
            <input type="checkbox" checked={showPrice}
              onChange={e => setShowPrice(e.target.checked)} /> show price
          </label>
        </div>

        {db.loading ? <div className="empty">Loading…</div> : (
          <div className="panel" style={{ padding: 0, overflowX: "auto", marginBottom: 20 }}>
            <table className="table">
              <thead><tr><th>Item</th><th>SKU</th><th>Code</th>
                <th className="num">Labels</th></tr></thead>
              <tbody>
                {visible.slice(0, 100).map(i => (
                  <tr key={i.id}>
                    <td>{i.name}</td>
                    <td className="mono dim">{i.sku}</td>
                    <td className="mono dim">{i.code}</td>
                    <td className="num">
                      <input className="input" style={{ width: 80, textAlign: "right" }}
                        inputMode="numeric" value={counts[i.id] ?? ""}
                        placeholder="0"
                        onChange={e => setCounts(c => ({
                          ...c, [i.id]: Math.max(0, Math.min(500, Math.floor(Number(e.target.value) || 0))),
                        }))} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {sheet.length > 0 && (
        <div className="label-grid">
          {sheet.map((i, k) => (
            <div className="label" key={k}>
              <div className="nm">{i.name}</div>
              <div dangerouslySetInnerHTML={{ __html: barcodeSvg(i.code, 40) }} />
              <div className="sk mono">{i.code}</div>
              {showPrice && i.price != null && <div className="pr">{formatPaise(i.price)}</div>}
            </div>
          ))}
        </div>
      )}
    </>
  );
}
