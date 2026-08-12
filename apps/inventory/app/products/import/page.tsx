"use client";
/**
 * CSV / Excel import. Spec section 60, honoured strictly:
 *   Upload -> auto-map columns -> validate -> preview errors -> confirm -> import.
 * Nothing is imported silently: rows that will be skipped are listed with
 * reasons BEFORE the confirm button, and the import is chunked through the
 * same per-row-savepoint RPC the bulk grid uses.
 */
import { useMemo, useRef, useState } from "react";
import Link from "next/link";
import { supabaseBrowser } from "@/lib/supabase/browser";
import { parseFile, autoMap, FIELDS, type Mapping, type RawRow, type FieldKey } from "@/lib/importer";

type Step = "upload" | "map" | "preview" | "importing" | "done";
const CHUNK = 100;

const toPaise = (s: string | undefined) => {
  const n = parseFloat((s ?? "").replace(/[₹,\s]/g, ""));
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : null;
};
const toQty = (s: string | undefined) => {
  const n = parseFloat((s ?? "").replace(/[,\s]/g, ""));
  return Number.isFinite(n) && n > 0 ? n : 0;
};

export default function ImportPage() {
  const [step, setStep] = useState<Step>("upload");
  const [fileName, setFileName] = useState("");
  const [headers, setHeaders] = useState<string[]>([]);
  const [rows, setRows] = useState<RawRow[]>([]);
  const [mapping, setMapping] = useState<Mapping>({});
  const [existingSkus, setExistingSkus] = useState<Set<string>>(new Set());
  const [progress, setProgress] = useState({ done: 0, total: 0, created: 0, failed: 0 });
  const [failures, setFailures] = useState<Array<{ name: string; error: string }>>([]);
  const fileRef = useRef<HTMLInputElement>(null);

  const get = (r: RawRow, f: FieldKey) => (mapping[f] ? String(r[mapping[f]!] ?? "").trim() : "");

  // ── validation ───────────────────────────────────────────────────────────
  const analysis = useMemo(() => {
    if (step === "upload") return null;
    const seen = new Map<string, number>();
    for (const r of rows) {
      const s = get(r, "sku").toUpperCase();
      if (s) seen.set(s, (seen.get(s) ?? 0) + 1);
    }
    const valid: RawRow[] = [];
    const skipped: Array<{ row: number; name: string; reason: string }> = [];
    rows.forEach((r, i) => {
      const name = get(r, "name");
      const sku = get(r, "sku").toUpperCase();
      if (!name) { skipped.push({ row: i + 2, name: "(blank)", reason: "No product name" }); return; }
      if (sku && (seen.get(sku) ?? 0) > 1) {
        skipped.push({ row: i + 2, name, reason: `Duplicate SKU ${sku} inside the file` }); return;
      }
      if (sku && existingSkus.has(sku)) {
        skipped.push({ row: i + 2, name, reason: `SKU ${sku} already exists — skipping to prevent double import` }); return;
      }
      valid.push(r);
    });
    return { valid, skipped };
  }, [rows, mapping, existingSkus, step]);

  // ── steps ────────────────────────────────────────────────────────────────
  async function onFile(f: File) {
    setFileName(f.name);
    const parsed = await parseFile(f);
    if (!parsed.rows.length) return alert("No rows found in the file.");
    setHeaders(parsed.headers);
    setRows(parsed.rows);
    setMapping(autoMap(parsed.headers));
    setStep("map");
  }

  async function toPreview() {
    if (!mapping.name) return alert("Map the Product name column first.");
    // pre-check which of the file's SKUs already exist, so a re-imported file
    // cannot silently create duplicates
    const skus = Array.from(new Set(
      rows.map(r => get(r, "sku").toUpperCase()).filter(Boolean)));
    const found = new Set<string>();
    for (let i = 0; i < skus.length; i += 200) {
      const { data } = await supabaseBrowser().schema("core")
        .from("product_variants").select("sku").in("sku", skus.slice(i, i + 200));
      (data ?? []).forEach((v: any) => found.add(String(v.sku).toUpperCase()));
    }
    setExistingSkus(found);
    setStep("preview");
  }

  async function runImport() {
    if (!analysis) return;
    const payloadRows = analysis.valid.map(r => ({
      name: get(r, "name"),
      sku: get(r, "sku") || undefined,
      category: get(r, "category") || undefined,
      brand: get(r, "brand") || undefined,
      hsn_sac: get(r, "hsn") || undefined,
      has_variants: false,
      base_cost_paise: toPaise(get(r, "cost")),
      selling_price_paise: toPaise(get(r, "sell")),
      mrp_paise: toPaise(get(r, "mrp")),
      opening_qty: toQty(get(r, "qty")),
    }));
    setStep("importing");
    setProgress({ done: 0, total: payloadRows.length, created: 0, failed: 0 });
    const fails: Array<{ name: string; error: string }> = [];
    let created = 0;
    for (let i = 0; i < payloadRows.length; i += CHUNK) {
      const chunk = payloadRows.slice(i, i + CHUNK);
      const { data, error } = await supabaseBrowser().schema("core")
        .rpc("create_products_bulk", { p: { rows: chunk } });
      if (error) {
        chunk.forEach(c => fails.push({ name: c.name, error: error.message }));
      } else {
        const out = data as { created: number; results: Array<{ ok: boolean; name?: string; error?: string }> };
        created += out.created;
        out.results.forEach(r => { if (!r.ok) fails.push({ name: r.name ?? "?", error: r.error ?? "Failed" }); });
      }
      setProgress({ done: Math.min(i + CHUNK, payloadRows.length), total: payloadRows.length,
                    created, failed: fails.length });
    }
    setFailures(fails);
    setStep("done");
  }

  function downloadErrorCsv() {
    const lines = [["name", "error"], ...failures.map(f => [f.name, f.error])]
      .map(l => l.map(c => `"${String(c).replace(/"/g, '""')}"`).join(",")).join("\n");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([lines], { type: "text/csv" }));
    a.download = "import-errors.csv"; a.click();
  }

  // ── render ───────────────────────────────────────────────────────────────
  return (
    <>
      <div className="topbar">
        <div>
          <h1>Import products</h1>
          <p className="sub" style={{ marginBottom: 0 }}>
            CSV or Excel · one row per product · nothing imports without a preview.
          </p>
        </div>
        <Link href="/products" className="btn ghost">Back to products</Link>
      </div>

      {step === "upload" && (
        <div className="empty" style={{ cursor: "pointer" }}
          onClick={() => fileRef.current?.click()}
          onDragOver={e => e.preventDefault()}
          onDrop={e => { e.preventDefault(); const f = e.dataTransfer.files?.[0]; if (f) onFile(f); }}>
          <b>Drop a CSV or Excel file here</b>
          …or click to choose. First row must be column headings
          (e.g. Name, SKU, Cost, Selling Price, Qty, Category).
          <input ref={fileRef} type="file" accept=".csv,.xlsx,.xls" hidden
            onChange={e => { const f = e.target.files?.[0]; if (f) onFile(f); }} />
        </div>
      )}

      {step === "map" && (
        <>
          <div className="panel">
            <h2>Map columns — {fileName} · {rows.length} rows</h2>
            <p className="sub">Auto-matched where possible. Fix anything that's wrong.</p>
            <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(240px, 1fr))" }}>
              {FIELDS.map(f => (
                <div className="field" key={f.key}>
                  <label>{f.label}{f.required ? " *" : ""}</label>
                  <select className="input" value={mapping[f.key] ?? ""}
                    onChange={e => setMapping(m => ({ ...m, [f.key]: e.target.value || undefined }))}>
                    <option value="">— not in file —</option>
                    {headers.map(h => <option key={h} value={h}>{h}</option>)}
                  </select>
                </div>
              ))}
            </div>
          </div>
          <div className="row">
            <button className="btn" onClick={toPreview}>Validate &amp; preview</button>
            <button className="btn ghost" onClick={() => setStep("upload")}>Different file</button>
          </div>
        </>
      )}

      {step === "preview" && analysis && (
        <>
          <div className="panel">
            <h2>
              <span className="badge green">{analysis.valid.length} will import</span>{" "}
              {analysis.skipped.length > 0 &&
                <span className="badge warn">{analysis.skipped.length} will be skipped</span>}
            </h2>
            {analysis.skipped.length > 0 && (
              <div style={{ overflowX: "auto", marginTop: 10 }}>
                <table className="table">
                  <thead><tr><th>File row</th><th>Product</th><th>Why skipped</th></tr></thead>
                  <tbody>
                    {analysis.skipped.slice(0, 50).map((s, i) => (
                      <tr key={i}><td className="mono">{s.row}</td><td>{s.name}</td>
                        <td className="dim">{s.reason}</td></tr>
                    ))}
                  </tbody>
                </table>
                {analysis.skipped.length > 50 &&
                  <p className="sub" style={{ margin: 8 }}>…and {analysis.skipped.length - 50} more.</p>}
              </div>
            )}
          </div>
          <div className="panel" style={{ padding: 0, overflowX: "auto" }}>
            <table className="table">
              <thead><tr><th>Name</th><th>SKU</th><th className="num">Cost</th>
                <th className="num">Sell</th><th className="num">Qty</th><th>Category</th></tr></thead>
              <tbody>
                {analysis.valid.slice(0, 8).map((r, i) => (
                  <tr key={i}>
                    <td>{get(r, "name")}</td><td className="mono dim">{get(r, "sku") || "auto"}</td>
                    <td className="num mono">{get(r, "cost") || "—"}</td>
                    <td className="num mono">{get(r, "sell") || "—"}</td>
                    <td className="num mono">{get(r, "qty") || "0"}</td>
                    <td className="dim">{get(r, "category") || "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {analysis.valid.length > 8 &&
              <p className="sub" style={{ margin: 10 }}>…previewing 8 of {analysis.valid.length}.</p>}
          </div>
          <div className="row">
            <button className="btn" disabled={!analysis.valid.length} onClick={runImport}>
              Import {analysis.valid.length} products
            </button>
            <button className="btn ghost" onClick={() => setStep("map")}>Back to mapping</button>
          </div>
        </>
      )}

      {step === "importing" && (
        <div className="panel">
          <h2>Importing… {progress.done} / {progress.total}</h2>
          <div style={{ background: "var(--panel2)", borderRadius: 8, height: 10, overflow: "hidden" }}>
            <div style={{ width: `${progress.total ? (progress.done / progress.total) * 100 : 0}%`,
              background: "var(--accent)", height: "100%", transition: "width .3s" }} />
          </div>
          <p className="sub" style={{ marginTop: 10 }}>
            {progress.created} created{progress.failed ? ` · ${progress.failed} failed` : ""} — keep this tab open.
          </p>
        </div>
      )}

      {step === "done" && (
        <div className="panel">
          <h2>
            <span className="badge green">{progress.created} imported</span>{" "}
            {failures.length > 0 && <span className="badge red">{failures.length} failed</span>}
          </h2>
          {failures.length > 0 && (
            <>
              <p className="sub">Download the failures, fix them in the file, and import just that file again.</p>
              <button className="btn ghost sm" onClick={downloadErrorCsv}>Download error CSV</button>
            </>
          )}
          <div className="row" style={{ marginTop: 14 }}>
            <Link href="/products" className="btn">View products</Link>
            <button className="btn ghost" onClick={() => { setStep("upload"); setFailures([]); }}>
              Import another file
            </button>
          </div>
        </div>
      )}
    </>
  );
}
