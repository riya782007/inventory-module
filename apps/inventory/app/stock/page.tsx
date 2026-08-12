"use client";
import { useState } from "react";
import { useDB, useRepo, balanceOf } from "@/lib/store";
import { REASONS_IN, REASONS_OUT } from "@/lib/types";

export default function Stock() {
  const db = useDB();
  const { postMovement } = useRepo();
  const [open, setOpen] = useState<string | null>(null);       // variant id being adjusted
  const [hist, setHist] = useState<string | null>(null);       // variant id history shown
  const [qty, setQty] = useState("");
  const [dir, setDir] = useState<"in" | "out">("in");
  const [reason, setReason] = useState<string>("purchase");
  const [note, setNote] = useState("");

  const rows = db.products
    .filter(p => p.status === "active")
    .flatMap(p => p.variants.map(v => ({
      p, v,
      label: Object.values(v.attributes).join(" / "),
      qty: balanceOf(db.movements, v.id),
    })));

  function submit(variantId: string) {
    const n = parseFloat(qty);
    if (!Number.isFinite(n) || n <= 0) return alert("Enter a quantity");
    const target = rows.find(r => r.v.id === variantId);
    const delta = dir === "in" ? n : -n;
    if (dir === "out" && target && target.qty + delta < 0)
      return alert(`Only ${target.qty} in stock — the ledger refuses oversell.`);
    postMovement({
      variant_id: variantId, qty_delta: delta,
      reason: reason as any, note: note.trim() || null,
    });
    setOpen(null); setQty(""); setNote("");
  }

  return (
    <>
      <h1>Stock</h1>
      <p className="sub">
        Balances are the sum of the movement ledger — never a stored number.
        Adjust stock and watch the history: nothing is ever edited, only appended.
      </p>

      {rows.length === 0 ? (
        <div className="empty"><b>No stock to show</b>Add a product first.</div>
      ) : (
        <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
          <table className="table">
            <thead><tr>
              <th>Product</th><th>Variant</th><th>SKU</th>
              <th className="num">On hand</th><th></th>
            </tr></thead>
            <tbody>
              {rows.map(({ p, v, label, qty: q }) => (
                <FragmentRow key={v.id}>
                  <tr>
                    <td style={{ fontWeight: 600 }}>{p.name}</td>
                    <td>{label || <span className="dim">—</span>}</td>
                    <td className="mono dim">{v.sku}</td>
                    <td className="num mono">
                      {q <= 0 ? <span className="badge red">0</span>
                        : q <= 5 ? <span className="badge warn">{q}</span> : q}
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
                        <div className="field"><label>Note</label>
                          <input className="input" value={note} onChange={e => setNote(e.target.value)} /></div>
                        <button className="btn sm" style={{ marginTop: 16 }} onClick={() => submit(v.id)}>Post</button>
                      </div>
                    </td></tr>
                  )}
                  {hist === v.id && (
                    <tr><td colSpan={5} style={{ background: "var(--panel2)", padding: 0 }}>
                      <table className="table">
                        <tbody>
                          {db.movements.filter(m => m.variant_id === v.id).length === 0 && (
                            <tr><td className="dim">No movements yet.</td></tr>
                          )}
                          {db.movements.filter(m => m.variant_id === v.id).map(m => (
                            <tr key={m.id}>
                              <td className="dim" style={{ width: 170 }}>
                                {new Date(m.occurred_at).toLocaleString("en-IN", { dateStyle: "medium", timeStyle: "short" })}
                              </td>
                              <td>{m.reason.replace(/_/g, " ")}</td>
                              <td className="dim">{m.note ?? ""}</td>
                              <td className="num mono" style={{ width: 90, color: m.qty_delta > 0 ? "#34D399" : "var(--red)" }}>
                                {m.qty_delta > 0 ? "+" : ""}{m.qty_delta}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </td></tr>
                  )}
                </FragmentRow>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function FragmentRow({ children }: { children: React.ReactNode }) { return <>{children}</>; }
