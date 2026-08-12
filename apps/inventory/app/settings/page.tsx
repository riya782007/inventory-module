"use client";
import { useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/browser";
import { useRepo } from "@/lib/store";

export default function Settings() {
  const { signOut } = useRepo();
  const [org, setOrg] = useState<{ name: string; slug: string; role: string } | null>(null);
  const [email, setEmail] = useState<string | null>(null);

  useEffect(() => {
    const supa = supabaseBrowser();
    supa.auth.getUser().then(({ data }) => setEmail(data.user?.email ?? null));
    supa.schema("platform").rpc("my_org").then(({ data }) => data && setOrg(data as any));
  }, []);

  return (
    <>
      <h1>Settings</h1>
      <p className="sub">Locations, tax &amp; GST, pricing formulas, team and connected apps are next.</p>
      <div className="panel">
        <h2>Business</h2>
        <p className="sub" style={{ marginBottom: 6 }}>
          {org ? <>{org.name} · <span className="mono">{org.slug}</span> · you are <b>{org.role}</b></> : "…"}
        </p>
        <p className="sub" style={{ marginBottom: 0 }}>Signed in as {email ?? "…"}</p>
      </div>
      <div className="panel">
        <h2>Session</h2>
        <button className="btn ghost sm" onClick={signOut}>Sign out</button>
      </div>
    </>
  );
}
