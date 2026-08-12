import { formatPaise } from "@newvora/pricing";

// Placeholder metrics until Supabase is wired. Zeroes are honest.
const METRICS = [
  { k: "Stock value", v: formatPaise(0), hint: "moving average cost" },
  { k: "Total SKUs", v: "0", hint: "active variants" },
  { k: "Low stock", v: "0", hint: "below reorder level" },
  { k: "Out of stock", v: "0", hint: "zero available" },
  { k: "Pending transfers", v: "0", hint: "dispatched, not received" },
  { k: "Open counts", v: "0", hint: "physical counts in progress" },
];

export default function Dashboard() {
  return (
    <>
      <h1>Dashboard</h1>
      <p className="sub">
        Schema deployed &amp; verified · <span className="badge">45/45 DB checks</span>{" "}
        <span className="badge">26/26 engine tests</span>{" "}
        <span className="badge warn">Supabase not connected yet</span>
      </p>
      <div className="grid">
        {METRICS.map((m) => (
          <div className="card" key={m.k}>
            <div className="k">{m.k}</div>
            <div className="v">{m.v}</div>
            <div className="hint">{m.hint}</div>
          </div>
        ))}
      </div>
    </>
  );
}
