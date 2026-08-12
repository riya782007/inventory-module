"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { createOrganization } from "@/lib/actions";
import { supabaseBrowser } from "@/lib/supabase/browser";

const slugify = (s: string) =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 50);

export default function Onboarding() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugTouched, setSlugTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function go() {
    if (name.trim().length < 2) return setErr("Enter your business name");
    setBusy(true); setErr(null);
    try {
      // never spin forever: whatever happens server-side, give up at 20s
      const res = await Promise.race([
        createOrganization(name.trim(), slug || slugify(name)),
        new Promise<{ error: string }>(resolve => setTimeout(() =>
          resolve({ error: "Timed out. Check that SUPABASE_SERVICE_ROLE_KEY is set in Vercel, then try again — an existing business is picked up automatically." }), 20000)),
      ]);
      if ("error" in res && res.error) { setErr(res.error); return; }
      await supabaseBrowser().auth.refreshSession();
      router.push("/"); router.refresh();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Something went wrong — try again.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ maxWidth: 420, margin: "8vh auto 0" }}>
      <h1>Set up your business</h1>
      <p className="sub">Takes ten seconds. Everything else can change later.</p>
      <div className="panel">
        <div className="field"><label>Business name *</label>
          <input className="input" value={name} placeholder="Sharma Electronics"
            onChange={(e) => {
              setName(e.target.value);
              if (!slugTouched) setSlug(slugify(e.target.value));
            }} /></div>
        <div className="field"><label>Link name (for your future catalogue)</label>
          <input className="input" value={slug}
            onChange={(e) => { setSlugTouched(true); setSlug(slugify(e.target.value)); }} />
          <p className="sub" style={{ margin: "6px 0 0", fontSize: 12 }}>
            {slug ? `catalog.newvora.in/${slug}` : ""}</p></div>
        {err && <p className="sub" style={{ color: "var(--red)", marginBottom: 12 }}>{err}</p>}
        <button className="btn" style={{ width: "100%" }} disabled={busy} onClick={go}>
          {busy ? "Creating…" : "Create business"}
        </button>
      </div>
      <p className="sub" style={{ fontSize: 12 }}>
        You get a 14-day trial of Inventory and Share Catalogue, a Main Shop
        location, Indian GST slabs and a default pricing formula — all ready to use.
      </p>
    </div>
  );
}
