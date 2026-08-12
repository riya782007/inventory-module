"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { supabaseBrowser } from "@/lib/supabase/browser";
import { useDB, useRepo } from "@/lib/store";

type CLine = { variant_id: string; system_qty: number; counted_qty: number | null };
type Count = {
  id: string; code: string; status: string; location_id: string;
  started_at: string | null; approved_at: string | null;
  stock_count_lines: CLine[];
};

export default function StockCount() {
  const db = useDB();
  const { rpc } = useRepo();
  const [list, setList] = useState<Count[]>([]);
  const [loading, setLoading] = useState(true);
  const [openId, setOpenId] = useState<string | null>(null);
  const [entry, setEntry] = useState<Record<string, string>>({});
  const [onlyVariance, setOnlyVariance] = useState(true);
  const [startLoc, setStartLoc] = useState("");

  const locName = (id: string) => db.locations.find(l => l.id === id)?.name ?? "?";
  const vLabel = (id: string) => {
    for (const p of db.products) for (const v of p.variants)
      if (v.id === id) return `${p.name}${Object.values(v.attributes).length ? " · " + Object.values(v.attributes).join("/") : ""} (${v.sku})`;
    return id.slice(0, 8);
  };

  async function load() {
    const { data, error } = await supabaseBrowser().schema("inventory")
      .from("stock_counts")
      .select("id, code, status, location_id, started_at, approved_at, stock_count_lines(variant_id, system_qty, counted_qty)")
      .order("started_at", { ascending: false }).limit(20);
    if (!error) setList((data ?? []) as unknown as Count[]);
    setLoading(false);
  }
  useEffect(() => { load(); }, []);

  async function start() {
    const loc = startLoc || db.locations.find(l => l.is_default)?.id;
    if (!loc) return alert("Pick a location");
    try {
      const id = await rpc("start_count", { p_location: loc });
      await load(); setOpenId(id as string);
    } catch (e: any) { alert(e.message); }
  }

  async function saveLine(count: Count, variantId: string) {
    const raw = entry[`${count.id}:${variantId}`];
    if (raw == null || raw === "") return;
    const n = parseFloat(raw);
    if (!Number.isFinite(n) || n < 0) return alert("Enter a valid quantity");
    try {
      await rpc("save_count_line", { p_count: count.id, p_variant: variantId, p_qty: n });
      setList(p => p.map(c => c.id !== count.id ? c : {
        ...c,
        stock_count_lines: c.stock_count_lines.map(l =>
          l.variant_id === variantId ? { ...l, counted_qty: n } : l),
      }));
    } catch (e: any) { alert(e.message); }
  }

  async function approve(c: Count) {
    const variances = c.stock_count_lines.filter(l => l.counted_qty != null && l.counted_qty !== l.system_qty);
    if (!confirm(`Approve ${c.code}? ${variances.length} correction${variances.length === 1 ? "" : "s"} will be written to the ledger.`)) return;
    try { await rpc("approve_count", { p_id: c.id }); await load(); setOpenId(null); }
    catch (e: any) { alert(e.message); }
  }

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Physical stock count</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            System quantity is frozen when you start. Approving writes one
            ledger correction per variance — nothing is edited in place.
          </p>
        </div>
        <div className="row">
          <Link href="/stock" className="btn ghost">Back to stock</Link>
          <select className="input" style={{ maxWidth: 180 }} value={startLoc}
            onChange={e => setStartLoc(e.target.value)}>
            <option value="">{db.locations.find(l => l.is_default)?.name ?? "Location"}</option>
            {db.locations.filter(l => !l.is_default).map(l =>
              <option key={l.id} value={l.id}>{l.name}</option>)}
          </select>
          <button className="btn" onClick={start}>Start count</button>
        </div>
      </div>

      {loading ? <div className="empty">Loading…</div>
        : list.length === 0 ? <div className="empty"><b>No counts yet</b>Start one to reconcile physical stock with the system.</div>
        : list.map(c => {
          const lines = c.stock_count_lines;
          const counted = lines.filter(l => l.counted_qty != null).length;
          const variances = lines.filter(l => l.counted_qty != null && l.counted_qty !== l.system_qty);
          const show = openId === c.id;
          const visible = show ? lines.filter(l =>
            !onlyVariance || c.status !== "counting"
              ? true
              : l.counted_qty == null || l.counted_qty !== l.system_qty) : [];
          return (
            <div className="panel" key={c.id} style={{ padding: show ? undefined : 14 }}>
              <div className="row" style={{ justifyContent: "space-between" }}>
                <div>
                  <b className="mono">{c.code}</b>{" "}
                  <span className="dim">{locName(c.location_id)}</span>{" "}
                  <span className={c.status === "approved" ? "badge green" : "badge warn"}>{c.status}</span>{" "}
                  <span className="dim" style={{ fontSize: 13 }}>
                    {counted}/{lines.length} counted · {variances.length} variance{variances.length === 1 ? "" : "s"}
                  </span>
                </div>
                <div className="row">
                  {c.status === "counting" && show &&
                    <label className="sub" style={{ margin: 0, cursor: "pointer" }}>
                      <input type="checkbox" checked={onlyVariance}
                        onChange={e => setOnlyVariance(e.target.checked)} /> uncounted &amp; variances only
                    </label>}
                  {c.status === "counting" &&
                    <button className="btn sm" onClick={() => approve(c)} disabled={counted === 0}>Approve</button>}
                  <button className="btn ghost sm" onClick={() => setOpenId(show ? null : c.id)}>
                    {show ? "Close" : "Open"}
                  </button>
                </div>
              </div>
              {show && (
                <div style={{ overflowX: "auto", marginTop: 12 }}>
                  <table className="table">
                    <thead><tr>
                      <th>Item</th><th className="num">System</th>
                      <th className="num">Counted</th><th className="num">Difference</th>
                    </tr></thead>
                    <tbody>
                      {visible.map(l => {
                        const key = `${c.id}:${l.variant_id}`;
                        const diff = l.counted_qty != null ? l.counted_qty - l.system_qty : null;
                        return (
                          <tr key={l.variant_id}>
                            <td>{vLabel(l.variant_id)}</td>
                            <td className="num mono">{l.system_qty}</td>
                            <td className="num">
                              {c.status === "counting" ? (
                                <input className="input" style={{ width: 90, textAlign: "right" }}
                                  inputMode="numeric"
                                  defaultValue={l.counted_qty ?? ""}
                                  onChange={e => setEntry(x => ({ ...x, [key]: e.target.value }))}
                                  onBlur={() => saveLine(c, l.variant_id)}
                                  onKeyDown={e => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
                              ) : <span className="mono">{l.counted_qty ?? "—"}</span>}
                            </td>
                            <td className="num mono" style={{
                              color: diff == null || diff === 0 ? "var(--dim)"
                                : diff > 0 ? "#34D399" : "var(--red)" }}>
                              {diff == null ? "—" : diff > 0 ? `+${diff}` : diff}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          );
        })}
    </>
  );
}
