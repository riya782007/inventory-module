"use client";
import { useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/browser";
import { useDB, useRepo } from "@/lib/store";

export default function Settings() {
  const db = useDB();
  const { signOut, addLocation } = useRepo();
  const [org, setOrg] = useState<{ name: string; slug: string; role: string } | null>(null);
  const [email, setEmail] = useState<string | null>(null);
  const [locName, setLocName] = useState("");
  const [locType, setLocType] = useState("warehouse");

  useEffect(() => {
    const supa = supabaseBrowser();
    supa.auth.getUser().then(({ data }) => setEmail(data.user?.email ?? null));
    supa.schema("platform").rpc("my_org").then(({ data }) => data && setOrg(data as any));
  }, []);

  return (
    <>
      <h1>Settings</h1>
      <p className="sub">Tax &amp; GST, pricing formulas, team and connected apps are next.</p>

      <div className="panel">
        <h2>Business</h2>
        <p className="sub" style={{ marginBottom: 6 }}>
          {org ? <>{org.name} · <span className="mono">{org.slug}</span> · you are <b>{org.role}</b></> : "…"}
        </p>
        <p className="sub" style={{ marginBottom: 0 }}>Signed in as {email ?? "…"}</p>
      </div>

      <div className="panel">
        <h2>Locations</h2>
        <p className="sub">Shops, warehouses and godowns. Stock is tracked per location.</p>
        {db.locations.map(l => (
          <span className="chip" key={l.id}>
            {l.name} <span className="dim">· {l.type}{l.is_default ? " · default" : ""}</span>
          </span>
        ))}
        <div className="row" style={{ marginTop: 12 }}>
          <div className="field" style={{ maxWidth: 220 }}>
            <input className="input" placeholder="e.g. Godown 2" value={locName}
              onChange={e => setLocName(e.target.value)} />
          </div>
          <div className="field" style={{ maxWidth: 160 }}>
            <select className="input" value={locType} onChange={e => setLocType(e.target.value)}>
              {["shop", "warehouse", "godown", "vehicle"].map(t =>
                <option key={t} value={t}>{t}</option>)}
            </select>
          </div>
          <button className="btn sm" onClick={async () => {
            if (locName.trim().length < 2) return;
            try { await addLocation(locName.trim(), locType); setLocName(""); }
            catch (e: any) { alert(e.message); }
          }}>Add location</button>
        </div>
      </div>

      <div className="panel">
        <h2>Session</h2>
        <button className="btn ghost sm" onClick={signOut}>Sign out</button>
      </div>
    </>
  );
}
