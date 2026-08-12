"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { supabaseBrowser } from "@/lib/supabase/browser";

export default function Login() {
  const router = useRouter();
  const [mode, setMode] = useState<"in" | "up">("in");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function go() {
    setBusy(true); setErr(null);
    const supa = supabaseBrowser();
    const { error } = mode === "in"
      ? await supa.auth.signInWithPassword({ email, password })
      : await supa.auth.signUp({ email, password });
    setBusy(false);
    if (error) return setErr(error.message);
    router.push("/"); router.refresh();
  }

  return (
    <div style={{ maxWidth: 380, margin: "8vh auto 0" }}>
      <div className="brand" style={{ fontSize: 24, padding: 0, marginBottom: 6 }}>
        new<span>vora</span>
      </div>
      <h1 style={{ marginBottom: 4 }}>{mode === "in" ? "Sign in" : "Create your account"}</h1>
      <p className="sub">Inventory for Indian businesses.</p>
      <div className="panel">
        <div className="field"><label>Email</label>
          <input className="input" type="email" value={email}
            onChange={(e) => setEmail(e.target.value)} autoComplete="email" /></div>
        <div className="field"><label>Password</label>
          <input className="input" type="password" value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete={mode === "in" ? "current-password" : "new-password"}
            onKeyDown={(e) => e.key === "Enter" && go()} /></div>
        {err && <p className="sub" style={{ color: "var(--red)", marginBottom: 12 }}>{err}</p>}
        <button className="btn" style={{ width: "100%" }} disabled={busy} onClick={go}>
          {busy ? "…" : mode === "in" ? "Sign in" : "Sign up"}
        </button>
      </div>
      <p className="sub" style={{ textAlign: "center" }}>
        {mode === "in" ? "New here? " : "Already have an account? "}
        <a style={{ color: "var(--accent-soft)", cursor: "pointer" }}
          onClick={() => { setMode(mode === "in" ? "up" : "in"); setErr(null); }}>
          {mode === "in" ? "Create an account" : "Sign in"}
        </a>
      </p>
    </div>
  );
}
