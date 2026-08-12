export default function Stock() {
  return (
    <>
      <h1>Stock</h1>
      <p className="sub">
        Every change is a ledger entry — adjustments, transfers and counts can
        never disagree with the balance.
      </p>
      <div className="empty">
        <b>No stock yet</b>
        Stock by location, movement ledger, adjustments, transfers and physical
        counts appear here.
      </div>
    </>
  );
}
