"use client";
import { useMemo, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { formatPaise } from "@newvora/pricing";
import { useDB, useRepo, balanceAt, imageUrl } from "@/lib/store";

const toPaise = (s: string) => {
  const n = parseFloat(s); return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : null;
};
const fromPaise = (p: number | null) => (p == null ? "" : String(p / 100));

export default function ProductDetail() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const db = useDB();
  const { updateProduct, updateVariant, archiveProduct, rpc, addBarcode, addImage, deleteImage } = useRepo();
  const product = useMemo(() => db.products.find(p => p.id === id), [db.products, id]);
  const [name, setName] = useState<string | null>(null);
  const [hsn, setHsn] = useState<string | null>(null);
  const [edit, setEdit] = useState<string | null>(null);   // variant id being edited
  const [draft, setDraft] = useState({ sku: "", cost: "", sell: "", mrp: "", min: "" });
  const [newCode, setNewCode] = useState("");
  const [uploading, setUploading] = useState(false);
  const defaultLoc = db.locations.find(l => l.is_default)?.id ?? "";

  if (db.loading) return <div className="empty">Loading…</div>;
  if (!product) return (
    <div className="empty"><b>Product not found</b>
      <Link href="/products" className="btn ghost sm" style={{ marginTop: 10 }}>Back</Link></div>
  );

  async function saveBasics() {
    try {
      await updateProduct(product!.id, {
        ...(name != null ? { name: name.trim() } : {}),
        ...(hsn != null ? { hsn_sac: hsn.trim() || null } : {}),
      });
      setName(null); setHsn(null);
    } catch (e: any) { alert(e.message); }
  }

  function openEdit(vId: string) {
    const v = product!.variants.find(x => x.id === vId)!;
    setDraft({
      sku: v.sku, cost: fromPaise(v.base_cost_paise),
      sell: fromPaise(v.selling_price_paise), mrp: fromPaise(v.mrp_paise),
      min: db.reorder[`${vId}:${defaultLoc}`] != null ? String(db.reorder[`${vId}:${defaultLoc}`]) : "",
    });
    setEdit(vId);
  }

  async function saveVariant(vId: string) {
    try {
      await updateVariant(vId, {
        sku: draft.sku.trim().toUpperCase(),
        base_cost_paise: toPaise(draft.cost),
        selling_price_paise: toPaise(draft.sell),
        mrp_paise: toPaise(draft.mrp),
      });
      if (defaultLoc) {
        const n = parseFloat(draft.min);
        await rpc("set_reorder_level", {
          p_variant: vId, p_location: defaultLoc,
          p_min: Number.isFinite(n) && n > 0 ? n : null,
        });
      }
      setEdit(null);
    } catch (e: any) { alert(e.message); }
  }

  const dirty = name != null || hsn != null;
  return (
    <>
      <div className="topbar">
        <div>
          <h1>{product.name}</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            {[product.brand, product.category, product.hsn_sac && `HSN ${product.hsn_sac}`]
              .filter(Boolean).join(" · ") || "—"}{" "}
            <span className={product.status === "active" ? "badge green" : "badge red"}>{product.status}</span>
          </p>
        </div>
        <div className="row">
          <Link href="/products" className="btn ghost">Back</Link>
          {product.status === "active" &&
            <button className="btn danger sm" onClick={async () => {
              if (confirm("Archive this product? It disappears from lists but history stays.")) {
                await archiveProduct(product.id); router.push("/products");
              }
            }}>Archive</button>}
        </div>
      </div>

      <div className="panel">
        <h2>Photos</h2>
        <div className="row" style={{ alignItems: "flex-start" }}>
          {product.images.map(img => (
            <div key={img.id} style={{ position: "relative" }}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={imageUrl(img.storage_path)} alt=""
                style={{ width: 92, height: 92, objectFit: "cover",
                         borderRadius: 10, border: "1px solid var(--line2)" }} />
              <button className="btn danger sm"
                style={{ position: "absolute", top: 4, right: 4, padding: "0 7px" }}
                onClick={async () => {
                  try { await deleteImage(img.id, img.storage_path); }
                  catch (e: any) { alert(e.message); }
                }}>×</button>
            </div>
          ))}
          <label className="empty" style={{ width: 92, height: 92, padding: 0,
              display: "flex", alignItems: "center", justifyContent: "center",
              cursor: "pointer", fontSize: 26, color: "var(--dim)" }}>
            {uploading ? "…" : "+"}
            <input type="file" accept="image/*" multiple hidden
              onChange={async e => {
                const files = Array.from(e.target.files ?? []);
                if (!files.length) return;
                setUploading(true);
                try { for (const f of files) await addImage(product.id, f); }
                catch (err: any) { alert(err.message); }
                finally { setUploading(false); e.target.value = ""; }
              }} />
          </label>
        </div>
        <p className="sub" style={{ margin: "8px 0 0", fontSize: 12 }}>
          Photos compress in your browser before upload (max 1200px). The first
          photo becomes the main one in lists and the future catalogue.
        </p>
      </div>

      <div className="panel">
        <h2>Basics</h2>
        <div className="row">
          <div className="field"><label>Name</label>
            <input className="input" value={name ?? product.name}
              onChange={e => setName(e.target.value)} /></div>
          <div className="field"><label>HSN / SAC</label>
            <input className="input" value={hsn ?? (product.hsn_sac ?? "")}
              onChange={e => setHsn(e.target.value)} /></div>
          <button className="btn sm" style={{ marginTop: 18 }} disabled={!dirty} onClick={saveBasics}>
            Save
          </button>
        </div>
      </div>

      <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
        <table className="table">
          <thead><tr>
            <th>Variant</th><th>SKU</th>
            <th className="num">Cost</th><th className="num">Sell</th><th className="num">MRP</th>
            <th className="num">Min level</th>
            {db.locations.map(l => <th className="num" key={l.id}>{l.name}</th>)}
            <th className="num">Total</th><th></th>
          </tr></thead>
          <tbody>
            {product.variants.map(v => {
              const label = Object.values(v.attributes).join(" / ") || "default";
              const min = db.reorder[`${v.id}:${defaultLoc}`];
              const editing = edit === v.id;
              return (
                <Frag key={v.id}>
                  <tr>
                    <td>{label}</td>
                    <td className="mono dim">{v.sku}</td>
                    <td className="num mono">{v.base_cost_paise != null ? formatPaise(v.base_cost_paise) : "—"}</td>
                    <td className="num mono">{v.selling_price_paise != null ? formatPaise(v.selling_price_paise) : "—"}</td>
                    <td className="num mono">{v.mrp_paise != null ? formatPaise(v.mrp_paise) : "—"}</td>
                    <td className="num mono">{min ?? "—"}</td>
                    {db.locations.map(l =>
                      <td className="num mono" key={l.id}>{balanceAt(db.balances, v.id, l.id)}</td>)}
                    <td className="num mono" style={{ fontWeight: 600 }}>{balanceAt(db.balances, v.id)}</td>
                    <td className="num">
                      <button className="btn ghost sm" onClick={() => editing ? setEdit(null) : openEdit(v.id)}>
                        {editing ? "Close" : "Edit"}
                      </button>
                    </td>
                  </tr>
                  {editing && (
                    <tr><td colSpan={8 + db.locations.length} style={{ background: "var(--panel2)" }}>
                      <div className="row" style={{ padding: "6px 0" }}>
                        <div className="field" style={{ maxWidth: 160 }}><label>SKU</label>
                          <input className="input" value={draft.sku} style={{ textTransform: "uppercase" }}
                            onChange={e => setDraft(d => ({ ...d, sku: e.target.value }))} /></div>
                        <div className="field" style={{ maxWidth: 110 }}><label>Cost ₹</label>
                          <input className="input" value={draft.cost} inputMode="decimal"
                            onChange={e => setDraft(d => ({ ...d, cost: e.target.value }))} /></div>
                        <div className="field" style={{ maxWidth: 110 }}><label>Sell ₹</label>
                          <input className="input" value={draft.sell} inputMode="decimal"
                            onChange={e => setDraft(d => ({ ...d, sell: e.target.value }))} /></div>
                        <div className="field" style={{ maxWidth: 110 }}><label>MRP ₹</label>
                          <input className="input" value={draft.mrp} inputMode="decimal"
                            onChange={e => setDraft(d => ({ ...d, mrp: e.target.value }))} /></div>
                        <div className="field" style={{ maxWidth: 120 }}><label>Min level</label>
                          <input className="input" value={draft.min} inputMode="numeric"
                            onChange={e => setDraft(d => ({ ...d, min: e.target.value }))} /></div>
                        <button className="btn sm" style={{ marginTop: 16 }} onClick={() => saveVariant(v.id)}>Save</button>
                      </div>
                      <div className="row" style={{ paddingBottom: 6 }}>
                        <span className="sub" style={{ margin: 0 }}>Barcodes:</span>
                        {v.barcodes.length === 0 && <span className="dim" style={{ fontSize: 13 }}>none — SKU is used on labels</span>}
                        {v.barcodes.map(b => <span className="chip mono" key={b}>{b}</span>)}
                        <input className="input" style={{ maxWidth: 180 }} placeholder="Add EAN/code + Enter"
                          value={newCode} onChange={e => setNewCode(e.target.value)}
                          onKeyDown={async e => {
                            if (e.key === "Enter" && newCode.trim()) {
                              try { await addBarcode(v.id, product.id, newCode); setNewCode(""); }
                              catch (err: any) { alert(err.message); }
                            }
                          }} />
                      </div>
                    </td></tr>
                  )}
                </Frag>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}
function Frag({ children }: { children: React.ReactNode }) { return <>{children}</>; }
