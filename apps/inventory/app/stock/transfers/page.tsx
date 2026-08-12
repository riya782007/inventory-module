"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { supabaseBrowser } from "@/lib/supabase/browser";
import { useDB, useRepo, balanceAt } from "@/lib/store";

type TLine = { id: string; variant_id: string; qty_sent: number; qty_received: number | null };
type Transfer = {
  id: string; code: string; status: string;
  from_location_id: string; to_location_id: string;
  dispatched_at: string | null; received_at: string | null;
  transfer_lines: TLine[];
};

export default function Transfers() {
  const db = useDB();
  const { rpc, refresh } = useRepo();
  const [list, setList] = useState<Transfer[]>([]);
  const [loading, setLoading] = useState(true);
  const [openNew, setOpenNew] = useState(false);
  const [from, setFrom] = useState(""); const [to, setTo] = useState("");
  const [lines, setLines] = useState<Array<{ variant_id: string; qty: string }>>([{ variant_id: "", qty: "" }]);
  const [receiving, setReceiving] = useState<string | null>(null);
  const [recQty, setRecQty] = useState<Record<string, string>>({});

  const locName = (id: string) => db.locations.find(l => l.id === id)?.name ?? "?";
  const variants = db.products.filter(p => p.status === "active")
    .flatMap(p => p.variants.map(v => ({
      id: v.id, label: `${p.name}${Object.values(v.attributes).length ? " · " + Object.values(v.attributes).join("/") : ""} (${v.sku})`,
    })));
  const variantLabel = (id: string) => variants.find(v => v.id === id)?.label ?? id.slice(0, 8);

  async function load() {
    const { data, error } = await supabaseBrowser().schema("inventory")
      .from("transfers")
      .select("id, code, status, from_location_id, to_location_id, dispatched_at, received_at, transfer_lines(id, variant_id, qty_sent, qty_received)")
      .order("created_at", { ascending: false }).limit(50);
    if (!error) setList((data ?? []) as unknown as Transfer[]);
    setLoading(false);
  }
  useEffect(() => { load(); }, []);
  const act = async (fn: string, args: Record<string, unknown>) => {
    try { await rpc(fn, args); await load(); } catch (e: any) { alert(e.message); }
  };

  async function create() {
    const good = lines.filter(l => l.variant_id && parseFloat(l.qty) > 0);
    if (!from || !to) return alert("Pick both locations");
    if (from === to) return alert("Source and destination are the same");
    if (!good.length) return alert("Add at least one line");
    await act("create_transfer", {
      p_from: from, p_to: to,
      p_lines: good.map(l => ({ variant_id: l.variant_id, qty: parseFloat(l.qty) })),
    });
    setOpenNew(false); setLines([{ variant_id: "", qty: "" }]);
  }

  const badge = (s: string) =>
    s === "received" ? "badge green" : s === "cancelled" ? "badge red"
    : s === "draft" ? "badge warn" : "badge";

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Stock transfers</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            Dispatch deducts the source; receiving adds what ACTUALLY arrived —
            any shortfall stays on the record.
          </p>
        </div>
        <div className="row">
          <Link href="/stock" className="btn ghost">Back to stock</Link>
          <button className="btn" onClick={() => setOpenNew(o => !o)}
            disabled={db.locations.length < 2}>+ New transfer</button>
        </div>
      </div>

      {db.locations.length < 2 && (
        <div className="panel">
          <p className="sub" style={{ margin: 0 }}>
            Transfers need at least two locations. <Link href="/settings" style={{ color: "var(--accent-soft)" }}>Add one in Settings</Link>.
          </p>
        </div>
      )}

      {openNew && (
        <div className="panel">
          <h2>New transfer</h2>
          <div className="row" style={{ marginBottom: 12 }}>
            <div className="field"><label>From</label>
              <select className="input" value={from} onChange={e => setFrom(e.target.value)}>
                <option value="">—</option>
                {db.locations.map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
              </select></div>
            <div className="field"><label>To</label>
              <select className="input" value={to} onChange={e => setTo(e.target.value)}>
                <option value="">—</option>
                {db.locations.map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
              </select></div>
          </div>
          {lines.map((l, i) => (
            <div className="row" key={i} style={{ marginBottom: 8 }}>
              <div className="field" style={{ flex: 3 }}>
                <select className="input" value={l.variant_id}
                  onChange={e => setLines(p => p.map((x, j) => j === i ? { ...x, variant_id: e.target.value } : x))}>
                  <option value="">— pick item —</option>
                  {variants.map(v => <option key={v.id} value={v.id}>
                    {v.label}{from ? ` · ${balanceAt(db.balances, v.id, from)} in stock` : ""}
                  </option>)}
                </select>
              </div>
              <div className="field" style={{ maxWidth: 110 }}>
                <input className="input" placeholder="Qty" inputMode="numeric" value={l.qty}
                  onChange={e => setLines(p => p.map((x, j) => j === i ? { ...x, qty: e.target.value } : x))} />
              </div>
              <button className="btn danger sm" onClick={() => setLines(p => p.length > 1 ? p.filter((_, j) => j !== i) : p)}>×</button>
            </div>
          ))}
          <div className="row">
            <button className="btn ghost sm" onClick={() => setLines(p => [...p, { variant_id: "", qty: "" }])}>+ Line</button>
            <button className="btn sm" onClick={create}>Create draft</button>
          </div>
        </div>
      )}

      {loading ? <div className="empty">Loading…</div>
        : list.length === 0 ? <div className="empty"><b>No transfers yet</b></div>
        : (
        <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
          <table className="table">
            <thead><tr><th>Code</th><th>Route</th><th>Lines</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {list.map(t => (
                <Frag key={t.id}>
                  <tr>
                    <td className="mono">{t.code}</td>
                    <td>{locName(t.from_location_id)} → {locName(t.to_location_id)}</td>
                    <td>{t.transfer_lines.map(l =>
                      `${variantLabel(l.variant_id)} × ${l.qty_sent}${l.qty_received != null && l.qty_received !== l.qty_sent ? ` (recd ${l.qty_received})` : ""}`
                    ).join(", ")}</td>
                    <td><span className={badge(t.status)}>{t.status}</span></td>
                    <td className="num" style={{ whiteSpace: "nowrap" }}>
                      {t.status === "draft" && <>
                        <button className="btn sm" style={{ marginRight: 6 }}
                          onClick={() => act("dispatch_transfer", { p_id: t.id })}>Dispatch</button>
                        <button className="btn danger sm"
                          onClick={() => act("cancel_transfer", { p_id: t.id })}>Cancel</button>
                      </>}
                      {(t.status === "dispatched" || t.status === "in_transit") &&
                        <button className="btn sm" onClick={() => {
                          setReceiving(receiving === t.id ? null : t.id);
                          setRecQty(Object.fromEntries(t.transfer_lines.map(l => [l.id, String(l.qty_sent)])));
                        }}>Receive</button>}
                    </td>
                  </tr>
                  {receiving === t.id && (
                    <tr><td colSpan={5} style={{ background: "var(--panel2)" }}>
                      <div className="row" style={{ padding: "6px 0", alignItems: "flex-end" }}>
                        {t.transfer_lines.map(l => (
                          <div className="field" key={l.id} style={{ maxWidth: 220 }}>
                            <label>{variantLabel(l.variant_id)} (sent {l.qty_sent})</label>
                            <input className="input" inputMode="numeric"
                              value={recQty[l.id] ?? ""}
                              onChange={e => setRecQty(q => ({ ...q, [l.id]: e.target.value }))} />
                          </div>
                        ))}
                        <button className="btn sm" onClick={async () => {
                          await act("receive_transfer", {
                            p_id: t.id,
                            p_lines: t.transfer_lines.map(l => ({
                              line_id: l.id, qty_received: parseFloat(recQty[l.id] ?? "") || 0,
                            })),
                          });
                          setReceiving(null); refresh();
                        }}>Confirm receipt</button>
                      </div>
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
