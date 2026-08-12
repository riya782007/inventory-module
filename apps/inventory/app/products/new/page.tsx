"use client";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useRepo, type NewProductPayload } from "@/lib/store";
import type { ProductOption } from "@/lib/types";

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
  const { createProduct } = useRepo();

  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [category, setCategory] = useState("");
  const [hsn, setHsn] = useState("");
  const [hasVariants, setHasVariants] = useState(false);
  const [options, setOptions] = useState<ProductOption[]>([]);
  const [optName, setOptName] = useState("");
  const [valDraft, setValDraft] = useState<Record<number, string>>({});
  const [cost, setCost] = useState(""); const [sell, setSell] = useState("");
  const [mrp, setMrp] = useState(""); const [opening, setOpening] = useState("");
  const [rows, setRows] = useState<Record<string, { cost: string; sell: string; opening: string }>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const matrix = useMemo(
    () => (hasVariants && options.some(o => o.values.length) ? cartesian(options.filter(o => o.values.length)) : []),
    [hasVariants, options]);
  const keyOf = (a: Record<string, string>) => Object.values(a).join(" / ");

  async function save() {
    if (!name.trim()) return setErr("Product name is required");
    setBusy(true); setErr(null);
    const payload: NewProductPayload =
      hasVariants && matrix.length
        ? {
            name: name.trim(), brand: brand.trim() || undefined,
            category: category.trim() || undefined, hsn_sac: hsn.trim() || undefined,
            has_variants: true, options: options.filter(o => o.values.length),
            variants: matrix.map((attrs, i) => {
              const r = rows[keyOf(attrs)] ?? { cost: "", sell: "", opening: "" };
              return {
                attributes: attrs, is_default: i === 0,
                base_cost_paise: toPaise(r.cost || cost),
                selling_price_paise: toPaise(r.sell || sell),
                mrp_paise: toPaise(mrp),
                opening_qty: parseFloat(r.opening) > 0 ? parseFloat(r.opening) : 0,
              };
            }),
          }
        : {
            name: name.trim(), brand: brand.trim() || undefined,
            category: category.trim() || undefined, hsn_sac: hsn.trim() || undefined,
            has_variants: false,
            base_cost_paise: toPaise(cost), selling_price_paise: toPaise(sell),
            mrp_paise: toPaise(mrp),
            opening_qty: parseFloat(opening) > 0 ? parseFloat(opening) : 0,
          };
    try { await createProduct(payload); router.push("/products"); }
    catch (e: any) { setErr(e.message ?? "Could not save"); setBusy(false); }
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
                  {matrix.length} variants will be created with auto-generated SKUs.
                  Leave a cell empty to inherit the price above.
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

      {err && <p className="sub" style={{ color: "var(--red)" }}>{err}</p>}
      <div className="row">
        <button className="btn" disabled={busy} onClick={save}>{busy ? "Saving…" : "Save product"}</button>
        <button className="btn ghost" onClick={() => router.back()}>Cancel</button>
      </div>
    </>
  );
}
