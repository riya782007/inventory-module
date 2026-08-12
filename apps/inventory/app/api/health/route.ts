import { computePrices } from "@newvora/pricing";
import { splitExclusive } from "@newvora/tax";

export const dynamic = "force-dynamic";

/** Liveness + proof the shared engines are linked into the app bundle. */
export async function GET() {
  const price = computePrices(20000, {
    mode: "multiplier", wholesale_markup_bp: 1000,
    retail_multiplier: 2.2, mrp_multiplier: 2.75,
    retail_rounding: "charm_9", mrp_rounding: "multiple_5", round_to_paise: 100,
  });
  const gst = splitExclusive(100000, 300, { state_code: "07" }, "07");
  return Response.json({
    ok: true,
    app: "inventory",
    engines: {
      pricing: price.retail_paise === 44900,
      tax: gst.cgst_paise === 1500 && gst.sgst_paise === 1500,
    },
    time: new Date().toISOString(),
  });
}
