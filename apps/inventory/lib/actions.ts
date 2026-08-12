"use server";
import { supabaseServer, supabaseAdmin } from "@/lib/supabase/server";

/**
 * Create the business, then stamp org_id into the user's app_metadata so
 * every future JWT carries it - that claim is what RLS trusts.
 *
 * Defensive by design:
 * - env checked FIRST, so a missing service key fails loudly in one second
 *   instead of crashing after the org row exists
 * - if the org already exists but metadata was never stamped (a previous
 *   half-failed attempt), we self-heal: look the org up and stamp it now
 * - never throws; always returns { org_id } or { error }
 */
export async function createOrganization(name: string, slug: string) {
  try {
    if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
      return { error: "Server is missing SUPABASE_SERVICE_ROLE_KEY. Add it in Vercel → Settings → Environment Variables and redeploy." };
    }
    const supa = supabaseServer();
    const { data: { user } } = await supa.auth.getUser();
    if (!user) return { error: "Not signed in" };

    let orgId: string | undefined;
    const { data, error } = await supa.schema("platform").rpc("create_organization", {
      p_name: name, p_slug: slug,
    });
    if (error) {
      if (error.message.includes("already belongs")) {
        // self-heal: the org exists from a previous half-failed attempt
        const { data: mo } = await supa.schema("platform").rpc("my_org");
        orgId = (mo as { org_id?: string } | null)?.org_id;
        if (!orgId) return { error: error.message };
      } else {
        return { error: error.message };
      }
    } else {
      orgId = (data as { org_id: string }).org_id;
    }

    const { error: adminErr } = await supabaseAdmin().auth.admin.updateUserById(user.id, {
      app_metadata: { org_id: orgId },
    });
    if (adminErr) return { error: adminErr.message };
    return { org_id: orgId };
  } catch (e) {
    return { error: e instanceof Error ? e.message : "Unexpected server error" };
  }
}
