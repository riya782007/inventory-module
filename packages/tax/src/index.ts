/**
 * @newvora/tax — Indian GST engine. PURE. No I/O, no hard-coded business.
 *
 * Ported from lib/business.ts in the Yogendra build. That file had the tax
 * maths right but baked one business into source control - GSTIN, bank
 * account, HSN and rate were constants, which is a large part of why the
 * codebase had to be forked for a second customer. Here every one of those is
 * an argument or an org row.
 *
 * All money is integer paise. Rates are integer basis points (300 = 3.00%).
 */

export type TaxMode = "inclusive" | "exclusive" | "none";

/** Per-document override. null = decide from the channel, as the legacy
 *  orders.gst_mode column did (wholesale exclusive, retail inclusive). */
export type DocumentTaxMode = TaxMode | null;

export type SellerProfile = {
  gstin?: string | null;
  state_code?: string | null;   // '07' Delhi, '29' Karnataka …
  is_composition?: boolean;
};

export type TaxSplit = {
  taxable_paise: number;
  cgst_paise: number;
  sgst_paise: number;
  igst_paise: number;
  cess_paise: number;
  tax_paise: number;
  total_paise: number;
  inter_state: boolean;
};

export const GST_STATE_NAMES: Record<string, string> = {
  "01":"Jammu & Kashmir","02":"Himachal Pradesh","03":"Punjab","04":"Chandigarh",
  "05":"Uttarakhand","06":"Haryana","07":"Delhi","08":"Rajasthan","09":"Uttar Pradesh",
  "10":"Bihar","11":"Sikkim","12":"Arunachal Pradesh","13":"Nagaland","14":"Manipur",
  "15":"Mizoram","16":"Tripura","17":"Meghalaya","18":"Assam","19":"West Bengal",
  "20":"Jharkhand","21":"Odisha","22":"Chhattisgarh","23":"Madhya Pradesh","24":"Gujarat",
  "25":"Daman & Diu","26":"Dadra & Nagar Haveli and Daman & Diu","27":"Maharashtra",
  "28":"Andhra Pradesh","29":"Karnataka","30":"Goa","31":"Lakshadweep","32":"Kerala",
  "33":"Tamil Nadu","34":"Puducherry","35":"Andaman & Nicobar Islands","36":"Telangana",
  "37":"Andhra Pradesh (New)","38":"Ladakh","97":"Other Territory",
};

export function stateCodeFromGstin(gstin?: string | null): string | null {
  if (!gstin) return null;
  const code = gstin.trim().slice(0, 2);
  return /^\d{2}$/.test(code) ? code : null;
}

export function stateNameFromCode(code?: string | null): string {
  return (code && GST_STATE_NAMES[code]) || "—";
}

/** GSTIN structural check. Not a government lookup - format only. */
export function isValidGstinFormat(gstin?: string | null): boolean {
  if (!gstin) return false;
  return /^\d{2}[A-Z]{5}\d{4}[A-Z][A-Z0-9]Z[A-Z0-9]$/.test(gstin.trim().toUpperCase());
}

/** Same state -> CGST + SGST. Different state -> IGST. */
export function isInterState(seller: SellerProfile, buyerStateCode?: string | null): boolean {
  const s = seller.state_code ?? stateCodeFromGstin(seller.gstin);
  if (!s || !buyerStateCode) return false;
  return s !== buyerStateCode;
}

/** Split a GST-INCLUSIVE amount: the price already contains the tax. */
export function splitInclusive(
  grossPaise: number, rateBp: number, seller: SellerProfile,
  buyerStateCode?: string | null, cessBp = 0
): TaxSplit {
  const totalBp = rateBp + cessBp;
  const taxable = Math.round(grossPaise * 10000 / (10000 + totalBp));
  const tax     = grossPaise - taxable;
  const cess    = cessBp ? Math.round(taxable * cessBp / 10000) : 0;
  const gst     = tax - cess;
  return assemble(taxable, gst, cess, seller, buyerStateCode, grossPaise);
}

/** Add GST on top of a taxable value. */
export function splitExclusive(
  taxablePaise: number, rateBp: number, seller: SellerProfile,
  buyerStateCode?: string | null, cessBp = 0
): TaxSplit {
  const gst  = Math.round(taxablePaise * rateBp / 10000);
  const cess = cessBp ? Math.round(taxablePaise * cessBp / 10000) : 0;
  return assemble(taxablePaise, gst, cess, seller, buyerStateCode, taxablePaise + gst + cess);
}

function assemble(
  taxable: number, gst: number, cess: number,
  seller: SellerProfile, buyerStateCode: string | null | undefined, total: number
): TaxSplit {
  const inter = isInterState(seller, buyerStateCode);
  // CGST takes the rounding remainder so cgst + sgst is exactly the GST amount.
  const cgst = inter ? 0 : Math.round(gst / 2);
  const sgst = inter ? 0 : gst - cgst;
  return {
    taxable_paise: taxable,
    cgst_paise: cgst, sgst_paise: sgst,
    igst_paise: inter ? gst : 0,
    cess_paise: cess,
    tax_paise: gst + cess,
    total_paise: total,
    inter_state: inter,
  };
}

/**
 * Resolve the mode for a document. Mirrors the legacy orders.gst_mode:
 * null means "auto" - wholesale exclusive, retail/POS inclusive.
 */
export function resolveTaxMode(
  explicit: DocumentTaxMode, channel: "retail" | "wholesale" | "pos"
): TaxMode {
  if (explicit) return explicit;
  return channel === "wholesale" ? "exclusive" : "inclusive";
}

export function computeLineTax(
  amountPaise: number, rateBp: number, mode: TaxMode,
  seller: SellerProfile, buyerStateCode?: string | null, cessBp = 0
): TaxSplit {
  if (mode === "none" || rateBp <= 0) {
    return { taxable_paise: amountPaise, cgst_paise: 0, sgst_paise: 0, igst_paise: 0,
             cess_paise: 0, tax_paise: 0, total_paise: amountPaise, inter_state: false };
  }
  return mode === "inclusive"
    ? splitInclusive(amountPaise, rateBp, seller, buyerStateCode, cessBp)
    : splitExclusive(amountPaise, rateBp, seller, buyerStateCode, cessBp);
}

/** Round a document total to the nearest rupee; returns the round-off applied. */
export function roundOff(totalPaise: number): { total_paise: number; round_off_paise: number } {
  const rounded = Math.round(totalPaise / 100) * 100;
  return { total_paise: rounded, round_off_paise: rounded - totalPaise };
}
