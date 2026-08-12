"use client";
/**
 * File -> rows for the bulk importer. CSV via papaparse; .xlsx/.xls via a
 * dynamically imported SheetJS so the library is only downloaded on the
 * import route. Header mapping is fuzzy-matched, then user-correctable.
 */
import Papa from "papaparse";

export type RawRow = Record<string, string>;
export const FIELDS = [
  { key: "name",     label: "Product name", required: true,
    hints: ["name", "product", "item", "productname", "itemname", "title"] },
  { key: "sku",      label: "SKU / code", required: false,
    hints: ["sku", "code", "itemcode", "barcode", "productcode"] },
  { key: "cost",     label: "Cost ₹", required: false,
    hints: ["cost", "purchase", "purchaseprice", "buy", "wholesale", "rate", "costprice"] },
  { key: "sell",     label: "Selling ₹", required: false,
    hints: ["sell", "selling", "sellingprice", "price", "saleprice", "retail"] },
  { key: "mrp",      label: "MRP ₹", required: false, hints: ["mrp", "maxretail"] },
  { key: "qty",      label: "Opening qty", required: false,
    hints: ["qty", "quantity", "stock", "opening", "openingstock", "pcs", "pieces"] },
  { key: "category", label: "Category", required: false, hints: ["category", "cat", "group"] },
  { key: "brand",    label: "Brand", required: false, hints: ["brand", "company", "make"] },
  { key: "hsn",      label: "HSN/SAC", required: false, hints: ["hsn", "sac", "hsncode"] },
] as const;
export type FieldKey = (typeof FIELDS)[number]["key"];
export type Mapping = Partial<Record<FieldKey, string>>;   // field -> source header

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

export function autoMap(headers: string[]): Mapping {
  const m: Mapping = {};
  const used = new Set<string>();
  for (const f of FIELDS) {
    const hints = f.hints as readonly string[];
    const hit = headers.find(h => !used.has(h) && hints.includes(norm(h)))
             ?? headers.find(h => !used.has(h) && hints.some(x => norm(h).includes(x)));
    if (hit) { m[f.key] = hit; used.add(hit); }
  }
  return m;
}

export async function parseFile(file: File): Promise<{ headers: string[]; rows: RawRow[] }> {
  const isExcel = /\.(xlsx|xls)$/i.test(file.name);
  if (isExcel) {
    const XLSX = await import("xlsx");
    const wb = XLSX.read(await file.arrayBuffer(), { type: "array" });
    const ws = wb.Sheets[wb.SheetNames[0]];
    const rows = XLSX.utils.sheet_to_json<RawRow>(ws, { raw: false, defval: "" });
    return { headers: rows.length ? Object.keys(rows[0]) : [], rows };
  }
  return new Promise((resolve, reject) => {
    Papa.parse<RawRow>(file, {
      header: true, skipEmptyLines: "greedy",
      complete: r => resolve({ headers: r.meta.fields ?? [], rows: r.data }),
      error: reject,
    });
  });
}
