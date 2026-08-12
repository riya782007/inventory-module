"use client";
import { useRepo } from "@/lib/store";

export default function Settings() {
  const { reset } = useRepo();
  return (
    <>
      <h1>Settings</h1>
      <p className="sub">Locations, tax &amp; GST, pricing formulas, team and connected apps unlock once Supabase is linked.</p>
      <div className="panel">
        <h2>Demo data</h2>
        <p className="sub" style={{ marginBottom: 12 }}>
          Everything you enter is stored in this browser only.
        </p>
        <button className="btn danger sm"
          onClick={() => { if (confirm("Clear all demo products and movements?")) reset(); }}>
          Clear demo data
        </button>
      </div>
    </>
  );
}
