# Newvora

A family of **independently sellable** business applications for Indian SMBs,
sharing one platform. Apps work standalone, connect optionally, and are
customised by configuration — never by forking.

```
              PLATFORM   identity · orgs · roles · entitlements · connections
                 CORE    products · variants · barcodes · pricing · tax
   ┌───────────────┼───────────────┐
INVENTORY      CATALOGUE        POS/BILLING (V3)
stock ledger   public site      invoices
locations      snapshots        payments
transfers      enquiries
```

## Status

| Layer | State |
|---|---|
| Platform schema (tenancy, roles, entitlements, connections, flags, audit, outbox) | done, verified |
| Core schema (products, variant engine, barcodes, pricing formulas, tax) | done, verified |
| Inventory schema (ledger-first stock, reservations, transfers, counts) | done, verified |
| Catalogue schema (catalogues, items, snapshots, public read path) | done, verified |
| RLS + integrity guards | done, verified — 45/45 |
| `@newvora/pricing`, `@newvora/tax` | done, verified — 26/26 |
| Apps (Next.js) | not started |

## The four decisions everything else follows from

**1 · Products live in `core`, not `inventory`.** A Catalogue-only customer
needs products but has no Inventory subscription. Putting products in Inventory
forces Catalogue to grow a shadow product table — the exact duplication this
platform exists to end.

**2 · The stock ledger is the only source of truth.** `inventory.stock_movements`
is append-only (enforced by rule *and* by the absence of any UPDATE/DELETE
policy). `stock_balances` is a cache maintained by trigger in the same
transaction. They cannot drift, because there is one writer.

**3 · Entitlements, not plans.** Access is `(org, app) → status`. A bundle is a
pricing construct that expands into ordinary per-app entitlements. No code path
ever asks "is this a bundle customer?".

**4 · Customisation is configuration.** Settings, feature flags, custom-field
definitions, industry templates. If you ever write `if (org.id === '…')`, the
architecture has failed.

## Verify

```bash
python3 supabase/tests/run.py          # boots a throwaway Postgres, 45 assertions
node --experimental-strip-types packages/pricing/src/index.test.ts
node --experimental-strip-types packages/tax/src/index.test.ts
```

`supabase/tests/run.py` applies every migration to an empty database and asserts
the invariants that matter: ledger equals balance, oversell is refused rather
than silently floored, reservations hold without deducting, a forged `org_id` in
a JWT yields nothing, staff cannot remove stock, and
`platform.system_integrity` is empty.

## Applying to Supabase

```bash
supabase link --project-ref <ref>
supabase db push
```

Migrations are ordered by timestamp filename — never by a sequence number.
(Both legacy repos ended up with duplicate `0006`/`0031`…`0051` prefixes and
undefined apply order.)

## What is deliberately NOT here

Batch/expiry, serial/IMEI, price lists, purchase orders, catalogue orders,
barcode label printing, custom-field UI, custom roles, POS. All V2+. See the
roadmap discussion — V1 is smaller than the original brief on purpose.

## Provenance

The pricing and GST engines are ported from the `Yogendra` / Blythe Diva build,
which got integer-paise money, the formula-driven catalogue, and mirrored
SQL/TS pricing right. What changed: every business-specific constant became a
column, so the two legacy customer forks are now reproducible from
configuration alone — proven by the fixtures in both test suites.
