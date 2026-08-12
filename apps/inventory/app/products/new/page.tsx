"use client";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useRepo, uid } from "@/lib/store";
import type { Product, ProductOption, Variant } from "@/lib/types";

/** "Nike T-Shirt", {"Size":"M","Colour":"Black"} -> NIK-M-BLK style SKUs */
function autoSku(name: string, attrs: Record<string, string>, taken: Set<string>) {
  const part = (s: string) => s.replace(/[^a-z0-9]/gi, "").slice(0, 3).toUpperCase() || "X";
  let base = [part(name), ...Object.values(attrs).map(part)].join("-");
  if (!Object.keys(attrs).length) base = part(name) + "-" + Math.random().toString(36).slice(2, 6).toUpperCase();
  let sku = base, n = 2;
  while (taken.has(sku)) sku = `${base}-${n++}`;
  taken.add(sku);
  return sku;
}

function cartesian(options: ProductOption[]): Record<string, string>[] {
  return options.reduce<Record<string, string>[]>(
    (acc, o) => acc.flatMap(row => o.values.map(v => ({ ...row, [o.name]: v }))),
    [{}]);
}

const toPaise = (s: string) => {
  const n = parseFloat(s); return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : null;
};

export default function NewProduct() {
  const router = useRouter();
  const { addProduct, postMovement } = useRepo();

  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [category, setCategory] = useState("");
  const [hsn, setHsn] = useState("");
  const [hasVariants, setHasVariants] = useState(false);
  const [options, setOptions] = useState<ProductOption[]>([]);
  const [optName, setOptName] = useState("");
  const [valDraft, setValDraft] = useState<Record<number, string>>({});
  // simple-product fields
  const [cost, setCost] = useState(""); const [sell, setSell] = useState("");
  const [mrp, setMrp] = useState(""); const [opening, setOpening] = useState("");
  // per-variant overrides in the matrix
  const [rows, setRows] = useState<Record<string, { cost: string; sell: string; opening: string }>>({});

  const matrix = useMemo(
    () => (hasVariants && options.some(o => o.values.length) ? cartesian(options.filter(o => o.values.length)) : []),
    [hasVariants, options]);

  const keyOf = (a: Record<string, string>) => Object.values(a).join(" / ");

  function save() {
    if (!name.trim()) return alert("Product name is required");
    const taken = new Set<string>();
    let variants: Variant[];
    if (hasVariants && matrix.length) {
      variants = matrix.map((attrs, i) => {
        const r = rows[keyOf(attrs)] ?? { cost, sell, opening: "" };
        return {
          id: uid(), sku: autoSku(name, attrs, taken), attributes: attrs,
          is_default: i === 0,
          base_cost_paise: toPaise(r.cost || cost),
          selling_price_paise: toPaise(r.sell || sell),
          mrp_paise: toPaise(mrp),
        };
      });
    } else {
      variants = [{
        id: uid(), sku: autoSku(name, {}, taken), attributes: {}, is_default: true,
        base_cost_paise: toPaise(cost), selling_price_paise: toPaise(sell), mrp_paise: toPaise(mrp),
      }];
    }
    const p: Product = {
      id: uid(), name: name.trim(), brand: brand.trim() || null,
      category: category.trim() || null, hsn_sac: hsn.trim() || null,
      has_variants: hasVariants && matrix.length > 0,
      options: hasVariants ? options.filter(o => o.values.length) : [],
      variants, status: "active", created_at: new Date().toISOString(),
    };
    addProduct(p);
    // opening stock → ledger entries, never a stored quantity
    for (const v of variants) {
      const o = p.has_variants ? rows[keyOf(v.attributes)]?.opening : opening;
      const qty = parseFloat(o ?? "");
      if (Number.isFinite(qty) && qty > 0)
        postMovement({ variant_id: v.id, qty_delta: qty, reason: "opening", note: "Opening stock" });
    }
    router.push("/products");
  }

  return (
    <>
      <h1>Add product</h1>
      <p className="sub">Create it once — every connected app reuses it.</p>

      <div className="panel">
        <h2>Basics</h2>
        <div className="row" style={{ marginBottom: 14 }}>
          <div className="field"><label>Product name *</label>
            <input className="input" value={name} onChange={e => setName(e.target.value)} placeholder="Cotton Kurta" /></div>
          <div className="field"><label>Brand</label>
            <input className="input" value={brand} onChange={e => setBrand(e.target.value)} /></div>
        </div>
        <div className="row">
          <div className="field"><label>Category</label>
            <input className="input" value={category} onChange={e => setCategory(e.target.value)} placeholder="Apparel" /></div>
          <div className="field"><label>HSN / SAC</label>
            <input className="input" value={hsn} onChange={e => setHsn(e.target.value)} placeholder="6203" /></div>
        </div>
      </div>

      <div className="panel">
        <h2>Pricing (₹)</h2>
        <div className="row">
          <div className="field"><label>Purchase cost</label>
            <input className="input" value={cost} onChange={e => setCost(e.target.value)} inputMode="decimal" /></div>
          <div className="field"><label>Selling price</label>
            <input className="input" value={sell} onChange={e => setSell(e.target.value)} inputMode="decimal" /></div>
          <div className="field"><label>MRP</label>
            <input className="input" value={mrp} onChange={e => setMrp(e.target.value)} inputMode="decimal" /></div>
          {!hasVariants && (
            <div className="field"><label>Opening stock</label>
              <input className="input" value={opening} onChange={e => setOpening(e.target.value)} inputMode="numeric" /></div>
          )}
        </div>
      </div>

      <div className="panel">
        <h2>
          <label style={{ cursor: "pointer", display: "flex", alignItems: "center", gap: 9 }}>
            <input type="checkbox" checked={hasVariants} onChange={e => setHasVariants(e.target.checked)} />
            This product has variants (size, colour, design…)
          </label>
        </h2>

        {hasVariants && (
          <>
            <div className="row" style={{ marginBottom: 12 }}>
              <div className="field" style={{ maxWidth: 220 }}>
                <label>Add an option (axis)</label>
                <input className="input" value={optName} placeholder="Size"
                  onChange={e => setOptName(e.target.value)}
                  onKeyDown={e => {
                    if (e.key === "Enter" && optName.trim()) {
                      setOptions(o => [...o, { name: optName.trim(), values: [] }]); setOptName("");
                    }
                  }} />
              </div>
              <button className="btn ghost sm" style={{ marginTop: 18 }}
                onClick={() => { if (optName.trim()) { setOptions(o => [...o, { name: optName.trim(), values: [] }]); setOptName(""); } }}>
                Add option
              </button>
            </div>

            {options.map((o, i) => (
              <div key={i} style={{ marginBottom: 12 }}>
                <div style={{ fontSize: 13, marginBottom: 6 }}>
                  <b>{o.name}</b>{" "}
                  <button className="chip" style={{ cursor: "pointer" }}
                    onClick={() => setOptions(os => os.filter((_, j) => j !== i))}>remove axis</button>
                </div>
                {o.values.map(v => (
                  <span className="chip" key={v}>{v}
                    <button onClick={() => setOptions(os => os.map((x, j) => j === i
                      ? { ...x, values: x.values.filter(y => y !== v) } : x))}>×</button>
                  </span>
                ))}
                <input className="input" style={{ maxWidth: 200, display: "inline-block" }}
                  placeholder={`Add ${o.name} + Enter`}
                  value={valDraft[i] ?? ""}
                  onChange={e => setValDraft(d => ({ ...d, [i]: e.target.value }))}
                  onKeyDown={e => {
                    const val = (valDraft[i] ?? "").trim();
                    if (e.key === "Enter" && val && !o.values.includes(val)) {
                      setOptions(os => os.map((x, j) => j === i ? { ...x, values: [...x.values, val] } : x));
                      setValDraft(d => ({ ...d, [i]: "" }));
                    }
                  }} />
              </div>
            ))}

            {matrix.length > 0 && (
              <>
                <div className="sub" style={{ margin: "14px 0 8px" }}>
                  {matrix.length} variants will be created. Leave a cell empty to inherit the price above.
                </div>
                <div style={{ overflowX: "auto" }}>
                  <table className="table">
                    <thead><tr>
                      <th>Variant</th><th className="num">Cost ₹</th>
                      <th className="num">Sell ₹</th><th className="num">Opening qty</th>
                    </tr></thead>
                    <tbody>
                      {matrix.map(attrs => {
                        const k = keyOf(attrs);
                        const r = rows[k] ?? { cost: "", sell: "", opening: "" };
                        const set = (patch: Partial<typeof r>) =>
                          setRows(rs => ({ ...rs, [k]: { ...r, ...patch } }));
                        return (
                          <tr key={k}>
                            <td>{k}</td>
                            <td className="num"><input className="input" style={{ width: 90, textAlign: "right" }}
                              value={r.cost} placeholder={cost || "—"} inputMode="decimal"
                              onChange={e => set({ cost: e.target.value })} /></td>
                            <td className="num"><input className="input" style={{ width: 90, textAlign: "right" }}
                              value={r.sell} placeholder={sell || "—"} inputMode="decimal"
                              onChange={e => set({ sell: e.target.value })} /></td>
                            <td className="num"><input className="input" style={{ width: 90, textAlign: "right" }}
                              value={r.opening} placeholder="0" inputMode="numeric"
                              onChange={e => set({ opening: e.target.value })} /></td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </>
            )}
          </>
        )}
      </div>

      <div className="row">
        <button className="btn" onClick={save}>Save product</button>
        <button className="btn ghost" onClick={() => router.back()}>Cancel</button>
      </div>
    </>
  );
}
