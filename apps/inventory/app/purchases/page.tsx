"use client";
/**
 * Suppliers + Purchase Orders. The procure-to-stock loop:
 * draft -> ordered -> receive (partial fine) -> stock + cost update.
 * Last-purchase-price memory pre-fills line costs per supplier.
 */
import { useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/browser";
import { formatPaise } from "@newvora/pricing";
import { useDB, useRepo } from "@/lib/store";

type Supplier = { id: string; name: string; city: string | null; gstin: string | null };
type POLine = { id: string; variant_id: string; qty_ordered: number; qty_received: number; unit_cost_paise: number | null };
type PO = {
  id: string; code: string; status: string; supplier_id: string; location_id: string;
  expected_at: string | null; created_at: string;
  purchase_order_lines: POLine[];
};

export default function Purchases() {
  const db = useDB();
  const { refresh } = useRepo();
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [pos, setPos] = useState<PO[]>([]);
  const [loading, setLoading] = useState(true);
  const [showNewSup, setShowNewSup] = useState(false);
  const [sup, setSup] = useState({ name: "", city: "", gstin: "", phone: "" });
  const [showNewPo, setShowNewPo] = useState(false);
  const [poSupplier, setPoSupplier] = useState("");
  const [poLocation, setPoLocation] = useState("");
  const [lines, setLines] = useState<Array<{ variant_id: string; qty: string; cost: string }>>(
    [{ variant_id: "", qty: "", cost: "" }]);
  const [lastCosts, setLastCosts] = useState<Record<string, number>>({});
  const [receiving, setReceiving] = useState<string | null>(null);
  const [recv, setRecv] = useState<Record<string, { qty: string; cost: string }>>({});

  const supName = (id: string) => suppliers.find(s => s.id === id)?.name ?? "?";
  const locName = (id: string) => db.locations.find(l => l.id === id)?.name ?? "?";
  const variants = db.products.filter(p => p.status === "active")
    .flatMap(p => p.variants.map(v => ({
      id: v.id,
      label: `${p.name}${Object.values(v.attributes).length ? " · " + Object.values(v.attributes).join("/") : ""} (${v.sku})`,
    })));
  const vLabel = (id: string) => variants.find(v => v.id === id)?.label ?? id.slice(0, 8);

  async function load() {
    const supa = supabaseBrowser();
    const [s, p] = await Promise.all([
      supa.schema("core").from("parties").select("id, name, city, gstin")
        .in("kind", ["supplier", "both"]).eq("status", "active").order("name"),
      supa.schema("inventory").from("purchase_orders")
        .select("id, code, status, supplier_id, location_id, expected_at, created_at, purchase_order_lines(id, variant_id, qty_ordered, qty_received, unit_cost_paise)")
        .order("created_at", { ascending: false }).limit(50),
    ]);
    if (!s.error) setSuppliers((s.data ?? []) as Supplier[]);
    if (!p.error) setPos((p.data ?? []) as unknown as PO[]);
    setLoading(false);
  }
  useEffect(() => { load(); }, []);

  // last-purchase-price memory: pre-fill costs when the supplier changes
  useEffect(() => {
    if (!poSupplier) { setLastCosts({}); return; }
    supabaseBrowser().schema("inventory")
      .rpc("last_purchase_costs", { p_supplier: poSupplier })
      .then(({ data }) => {
        const m: Record<string, number> = {};
        (data ?? []).forEach((r: any) => { m[r.variant_id] = r.unit_cost_paise; });
        setLastCosts(m);
      });
  }, [poSupplier]);

  const irpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await supabaseBrowser().schema("inventory").rpc(fn, args);
    if (error) throw new Error(error.message);
    return data;
  };

  async function addSupplier() {
    if (sup.name.trim().length < 2) return alert("Supplier name required");
    const { data: { session } } = await supabaseBrowser().auth.getSession();
    const orgId = (session?.user?.app_metadata as any)?.org_id;
    const { error } = await supabaseBrowser().schema("core").from("parties").insert({
      org_id: orgId, kind: "supplier", name: sup.name.trim(),
      city: sup.city.trim() || null, gstin: sup.gstin.trim() || null, phone: sup.phone.trim() || null,
    });
    if (error) return alert(error.message);
    setSup({ name: "", city: "", gstin: "", phone: "" }); setShowNewSup(false); load();
  }

  async function createPo(andOrder: boolean) {
    const good = lines.filter(l => l.variant_id && parseFloat(l.qty) > 0);
    if (!poSupplier) return alert("Pick a supplier");
    if (!good.length) return alert("Add at least one line");
    try {
      const id = await irpc("create_po", {
        p_supplier: poSupplier,
        p_location: poLocation || db.locations.find(l => l.is_default)?.id,
        p_lines: good.map(l => ({
          variant_id: l.variant_id, qty: parseFloat(l.qty),
          unit_cost_paise: parseFloat(l.cost) > 0 ? Math.round(parseFloat(l.cost) * 100) : null,
        })),
      });
      if (andOrder) await irpc("order_po", { p_id: id });
      setShowNewPo(false); setLines([{ variant_id: "", qty: "", cost: "" }]);
      await load();
    } catch (e: any) { alert(e.message); }
  }

  async function receive(po: PO) {
    try {
      await irpc("receive_po", {
        p_id: po.id,
        p_lines: po.purchase_order_lines
          .map(l => {
            const r = recv[l.id];
            const qty = r ? parseFloat(r.qty) : 0;
            return {
              line_id: l.id, qty: Number.isFinite(qty) && qty > 0 ? qty : 0,
              unit_cost_paise: r && parseFloat(r.cost) > 0 ? Math.round(parseFloat(r.cost) * 100) : null,
            };
          })
          .filter(l => l.qty > 0),
      });
      setReceiving(null); setRecv({}); await load(); refresh();
    } catch (e: any) { alert(e.message); }
  }

  const badge = (s: string) =>
    s === "received" ? "badge green" : s === "cancelled" ? "badge red"
    : s === "draft" ? "badge warn" : "badge";

  return (
    <>
      <div className="topbar">
        <div>
          <h1>Purchases</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            Order from suppliers, receive what arrives — stock and cost update through the ledger.
          </p>
        </div>
        <div className="row">
          <button className="btn ghost" onClick={() => setShowNewSup(o => !o)}>+ Supplier</button>
          <button className="btn" onClick={() => setShowNewPo(o => !o)}
            disabled={suppliers.length === 0}>+ Purchase order</button>
        </div>
      </div>

      {suppliers.length === 0 && !showNewSup && !loading && (
        <div className="empty" style={{ marginBottom: 16 }}>
          <b>Add your first supplier</b>Purchase orders start with a supplier.
          <div style={{ marginTop: 12 }}>
            <button className="btn" onClick={() => setShowNewSup(true)}>+ Supplier</button>
          </div>
        </div>
      )}

      {showNewSup && (
        <div className="panel">
          <h2>New supplier</h2>
          <div className="row">
            <div className="field"><label>Name *</label>
              <input className="input" value={sup.name} onChange={e => setSup(s => ({ ...s, name: e.target.value }))} /></div>
            <div className="field"><label>City</label>
              <input className="input" value={sup.city} onChange={e => setSup(s => ({ ...s, city: e.target.value }))} /></div>
            <div className="field"><label>GSTIN</label>
              <input className="input" value={sup.gstin} onChange={e => setSup(s => ({ ...s, gstin: e.target.value }))} /></div>
            <div className="field"><label>Phone</label>
              <input className="input" value={sup.phone} onChange={e => setSup(s => ({ ...s, phone: e.target.value }))} /></div>
            <button className="btn sm" style={{ marginTop: 18 }} onClick={addSupplier}>Save</button>
          </div>
        </div>
      )}

      {showNewPo && (
        <div className="panel">
          <h2>New purchase order</h2>
          <div className="row" style={{ marginBottom: 12 }}>
            <div className="field"><label>Supplier *</label>
              <select className="input" value={poSupplier} onChange={e => setPoSupplier(e.target.value)}>
                <option value="">—</option>
                {suppliers.map(s => <option key={s.id} value={s.id}>{s.name}{s.city ? ` · ${s.city}` : ""}</option>)}
              </select></div>
            <div className="field"><label>Deliver to</label>
              <select className="input" value={poLocation} onChange={e => setPoLocation(e.target.value)}>
                <option value="">{db.locations.find(l => l.is_default)?.name ?? "—"}</option>
                {db.locations.filter(l => !l.is_default).map(l =>
                  <option key={l.id} value={l.id}>{l.name}</option>)}
              </select></div>
          </div>
          {lines.map((l, i) => (
            <div className="row" key={i} style={{ marginBottom: 8 }}>
              <div className="field" style={{ flex: 3 }}>
                <select className="input" value={l.variant_id}
                  onChange={e => {
                    const vid = e.target.value;
                    setLines(p => p.map((x, j) => j === i ? {
                      ...x, variant_id: vid,
                      cost: x.cost || (lastCosts[vid] != null ? String(lastCosts[vid] / 100) : ""),
                    } : x));
                  }}>
                  <option value="">— pick item —</option>
                  {variants.map(v => <option key={v.id} value={v.id}>{v.label}</option>)}
                </select>
              </div>
              <div className="field" style={{ maxWidth: 100 }}>
                <input className="input" placeholder="Qty" inputMode="numeric" value={l.qty}
                  onChange={e => setLines(p => p.map((x, j) => j === i ? { ...x, qty: e.target.value } : x))} />
              </div>
              <div className="field" style={{ maxWidth: 120 }}>
                <input className="input" placeholder="Cost ₹" inputMode="decimal" value={l.cost}
                  onChange={e => setLines(p => p.map((x, j) => j === i ? { ...x, cost: e.target.value } : x))} />
              </div>
              <button className="btn danger sm" onClick={() => setLines(p => p.length > 1 ? p.filter((_, j) => j !== i) : p)}>×</button>
            </div>
          ))}
          <div className="row">
            <button className="btn ghost sm" onClick={() => setLines(p => [...p, { variant_id: "", qty: "", cost: "" }])}>+ Line</button>
            <button className="btn ghost sm" onClick={() => createPo(false)}>Save draft</button>
            <button className="btn sm" onClick={() => createPo(true)}>Save &amp; mark ordered</button>
          </div>
        </div>
      )}

      {loading ? <div className="empty">Loading…</div>
        : pos.length === 0 ? (suppliers.length > 0 && <div className="empty"><b>No purchase orders yet</b></div>)
        : (
        <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
          <table className="table">
            <thead><tr><th>Code</th><th>Supplier</th><th>Deliver to</th>
              <th>Lines</th><th className="num">Value</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {pos.map(po => {
                const value = po.purchase_order_lines.reduce(
                  (s, l) => s + (l.unit_cost_paise ?? 0) * l.qty_ordered, 0);
                return (
                  <Frag key={po.id}>
                    <tr>
                      <td className="mono">{po.code}</td>
                      <td>{supName(po.supplier_id)}</td>
                      <td className="dim">{locName(po.location_id)}</td>
                      <td>{po.purchase_order_lines.map(l =>
                        `${vLabel(l.variant_id)} × ${l.qty_ordered}${l.qty_received > 0 ? ` (recd ${l.qty_received})` : ""}`
                      ).join(", ")}</td>
                      <td className="num mono">{value ? formatPaise(Math.round(value)) : "—"}</td>
                      <td><span className={badge(po.status)}>{po.status}</span></td>
                      <td className="num" style={{ whiteSpace: "nowrap" }}>
                        {po.status === "draft" && <>
                          <button className="btn sm" style={{ marginRight: 6 }}
                            onClick={async () => { try { await irpc("order_po", { p_id: po.id }); load(); } catch (e: any) { alert(e.message); } }}>
                            Mark ordered</button>
                          <button className="btn danger sm"
                            onClick={async () => { try { await irpc("cancel_po", { p_id: po.id }); load(); } catch (e: any) { alert(e.message); } }}>
                            Cancel</button>
                        </>}
                        {(po.status === "ordered" || po.status === "partial") &&
                          <button className="btn sm" onClick={() => {
                            setReceiving(receiving === po.id ? null : po.id);
                            setRecv(Object.fromEntries(po.purchase_order_lines.map(l => [
                              l.id, {
                                qty: String(l.qty_ordered - l.qty_received),
                                cost: l.unit_cost_paise != null ? String(l.unit_cost_paise / 100) : "",
                              }])));
                          }}>Receive</button>}
                      </td>
                    </tr>
                    {receiving === po.id && (
                      <tr><td colSpan={7} style={{ background: "var(--panel2)" }}>
                        <div className="row" style={{ padding: "6px 0", alignItems: "flex-end" }}>
                          {po.purchase_order_lines.map(l => (
                            <Frag key={l.id}>
                              <div className="field" style={{ maxWidth: 200 }}>
                                <label>{vLabel(l.variant_id)} · pending {l.qty_ordered - l.qty_received}</label>
                                <input className="input" inputMode="numeric" placeholder="Qty now"
                                  value={recv[l.id]?.qty ?? ""}
                                  onChange={e => setRecv(r => ({ ...r, [l.id]: { ...r[l.id], qty: e.target.value } }))} />
                              </div>
                              <div className="field" style={{ maxWidth: 120 }}>
                                <label>Cost ₹</label>
                                <input className="input" inputMode="decimal"
                                  value={recv[l.id]?.cost ?? ""}
                                  onChange={e => setRecv(r => ({ ...r, [l.id]: { ...r[l.id], cost: e.target.value } }))} />
                              </div>
                            </Frag>
                          ))}
                          <button className="btn sm" onClick={() => receive(po)}>Receive now</button>
                        </div>
                        <p className="sub" style={{ margin: "4px 0 6px" }}>
                          Receive less than pending and the PO stays open as <b>partial</b>.
                        </p>
                      </td></tr>
                    )}
                  </Frag>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
function Frag({ children }: { children: React.ReactNode }) { return <>{children}</>; }
