"use client";
import { useState } from "react";
import Link from "next/link";
import { useDB, useRepo, balanceAt } from "@/lib/store";
import { REASONS_IN, REASONS_OUT } from "@/lib/types";

export default function Stock() {
  const db = useDB();
  const { postMovement } = useRepo();
  const [locId, setLocId] = useState<string>("");           // "" = all locations
  const [open, setOpen] = useState<string | null>(null);
  const [hist, setHist] = useState<string | null>(null);
  const [qty, setQty] = useState("");
  const [dir, setDir] = useState<"in" | "out">("in");
  const [reason, setReason] = useState<string>("purchase");
  const [note, setNote] = useState("");

  const multiLoc = db.locations.length > 1;
  const activeLoc = locId || db.locations.find(l => l.is_default)?.id || "";
  const locName = (id: string) => db.locations.find(l => l.id === id)?.name ?? "?";

  const rows = db.products
    .filter(p => p.status === "active")
    .flatMap(p => p.variants.map(v => ({
      p, v,
      label: Object.values(v.attributes).join(" / "),
      qty: balanceAt(db.balances, v.id, locId || undefined),
      min: db.reorder[`${v.id}:${activeLoc}`],
    })));

  async function submit(variantId: string) {
    const n = parseFloat(qty);
    if (!Number.isFinite(n) || n <= 0) return alert("Enter a quantity");
    if (!activeLoc) return alert("Pick a location");
    try {
      await postMovement({
        variant_id: variantId, location_id: activeLoc,
        qty_delta: dir === "in" ? n : -n, reason, note: note.trim() || null,
      });
      setOpen(null); setQty(""); setNote("");
    } catch (e: any) { alert(e.message); }
  }

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Stock</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            Balances are the sum of the movement ledger — never a stored number.
          </p>
        </div>
        <div className="row">
          <Link href="/stock/transfers" className="btn ghost">Transfers</Link>
          <Link href="/stock/count" className="btn ghost">Stock count</Link>
        </div>
      </div>

      {multiLoc && (
        <div className="row" style={{ marginBottom: 14 }}>
          <select className="input" style={{ maxWidth: 240 }} value={locId}
            onChange={e => setLocId(e.target.value)}>
            <option value="">All locations (total)</option>
            {db.locations.map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
          </select>
          {locId === "" &&
            <span className="sub" style={{ margin: 0 }}>Adjustments post to {locName(activeLoc)}.</span>}
        </div>
      )}

      {db.loading ? (
        <div className="empty">Loading…</div>
      ) : rows.length === 0 ? (
        <div className="empty"><b>No stock to show</b>Add a product first.</div>
      ) : (
        <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
          <table className="table">
            <thead><tr>
              <th>Product</th><th>Variant</th><th>SKU</th>
              <th className="num">On hand</th><th></th>
            </tr></thead>
            <tbody>
              {rows.map(({ p, v, label, qty: q, min }) => (
                <Frag key={v.id}>
                  <tr>
                    <td style={{ fontWeight: 600 }}>{p.name}</td>
                    <td>{label || <span className="dim">—</span>}</td>
                    <td className="mono dim">{v.sku}</td>
                    <td className="num mono">
                      {q <= 0 ? <span className="badge red">0</span>
                        : min != null && q <= min ? <span className="badge warn">{q}</span> : q}
                    </td>
                    <td className="num" style={{ whiteSpace: "nowrap" }}>
                      <button className="btn ghost sm" style={{ marginRight: 8 }}
                        onClick={() => setHist(hist === v.id ? null : v.id)}>History</button>
                      <button className="btn sm" onClick={() => { setOpen(open === v.id ? null : v.id); setDir("in"); setReason("purchase"); }}>
                        Adjust
                      </button>
                    </td>
                  </tr>
                  {open === v.id && (
                    <tr><td colSpan={5} style={{ background: "var(--panel2)" }}>
                      <div className="row" style={{ padding: "6px 0" }}>
                        <div className="field" style={{ maxWidth: 130 }}>
                          <label>Direction</label>
                          <select className="input" value={dir}
                            onChange={e => { const d = e.target.value as "in" | "out"; setDir(d); setReason(d === "in" ? "purchase" : "adjustment"); }}>
                            <option value="in">Stock in (+)</option>
                            <option value="out">Stock out (−)</option>
                          </select>
                        </div>
                        <div className="field" style={{ maxWidth: 110 }}>
                          <label>Qty</label>
                          <input className="input" value={qty} inputMode="numeric"
                            onChange={e => setQty(e.target.value)} />
                        </div>
                        <div className="field" style={{ maxWidth: 180 }}>
                          <label>Reason</label>
                          <select className="input" value={reason} onChange={e => setReason(e.target.value)}>
                            {(dir === "in" ? REASONS_IN : REASONS_OUT).map(r =>
                              <option key={r} value={r}>{r.replace(/_/g, " ")}</option>)}
                          </select>
                        </div>
                        {multiLoc && (
                          <div className="field" style={{ maxWidth: 170 }}>
                            <label>Location</label>
                            <select className="input" value={activeLoc} onChange={e => setLocId(e.target.value)}>
                              {db.locations.map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
                            </select>
                          </div>
                        )}
                        <div className="field"><label>Note</label>
                          <input className="input" value={note} onChange={e => setNote(e.target.value)} /></div>
                        <button className="btn sm" style={{ marginTop: 16 }} onClick={() => submit(v.id)}>Post</button>
                      </div>
                    </td></tr>
                  )}
                  {hist === v.id && (
                    <tr><td colSpan={5} style={{ background: "var(--panel2)", padding: 0 }}>
                      <table className="table"><tbody>
                        {db.movements.filter(m => m.variant_id === v.id).length === 0 && (
                          <tr><td className="dim">No movements yet.</td></tr>
                        )}
                        {db.movements.filter(m => m.variant_id === v.id).map(m => (
                          <tr key={m.id}>
                            <td className="dim" style={{ width: 165 }}>
                              {new Date(m.occurred_at).toLocaleString("en-IN", { dateStyle: "medium", timeStyle: "short" })}
                            </td>
                            <td>{m.reason.replace(/_/g, " ")}</td>
                            <td className="dim">{multiLoc ? locName(m.location_id) : ""}</td>
                            <td className="dim">{m.note ?? ""}</td>
                            <td className="num mono" style={{ width: 80, color: m.qty_delta > 0 ? "#34D399" : "var(--red)" }}>
                              {m.qty_delta > 0 ? "+" : ""}{m.qty_delta}
                            </td>
                          </tr>
                        ))}
                      </tbody></table>
                    </td></tr>
                  )}
                </Frag>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
function Frag({ children }: { children: React.ReactNode }) { return <>{children}</>; }
