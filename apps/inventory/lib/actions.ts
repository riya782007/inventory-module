"use server";
import { supabaseServer, supabaseAdmin } from "@/lib/supabase/server";

/**
 * Create the business, then stamp org_id into the user's app_metadata so
 * every future JWT carries it — that claim is what RLS trusts. The client
 * must refresh its session afterwards to pick up the new token.
 */
export async function createOrganization(name: string, slug: string) {
  const supa = supabaseServer();
  const { data: { user } } = await supa.auth.getUser();
  if (!user) return { error: "Not signed in" };

  const { data, error } = await supa.schema("platform").rpc("create_organization", {
    p_name: name, p_slug: slug,
  });
  if (error) return { error: error.message };

  const orgId = (data as { org_id: string }).org_id;
  const { error: adminErr } = await supabaseAdmin().auth.admin.updateUserById(user.id, {
    app_metadata: { org_id: orgId },
  });
  if (adminErr) return { error: adminErr.message };
  return { org_id: orgId };
}
