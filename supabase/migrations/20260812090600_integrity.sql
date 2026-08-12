-- ============================================================================
-- 0007 · INTEGRITY GUARDS
--
-- Adopted from the Yogendra build's best idea: one query proves the whole
-- system is healthy. Any row returned = a business rule is being violated.
-- Empty = every rule holds. Wire this to a daily alert.
--
-- The difference from the legacy version: there it was a rescue mechanism for
-- a design that drifted. Here it is a tripwire for a design that shouldn't.
-- ============================================================================

-- RULE: cached balance must equal the sum of the ledger, and never be negative.
create or replace view inventory.stock_integrity as
  select b.org_id, b.variant_id, b.location_id, v.sku,
         b.qty_on_hand,
         coalesce(m.ledger_sum, 0) as ledger_sum,
         b.qty_on_hand - coalesce(m.ledger_sum, 0) as drift
  from inventory.stock_balances b
  join core.product_variants v on v.id = b.variant_id
  left join (
    select variant_id, location_id, sum(qty_delta) as ledger_sum
    from inventory.stock_movements group by variant_id, location_id
  ) m on m.variant_id = b.variant_id and m.location_id = b.location_id
  where b.qty_on_hand <> coalesce(m.ledger_sum, 0)
     or b.qty_on_hand < 0;

-- RULE: reserved must equal the sum of open holds.
create or replace view inventory.reservation_integrity as
  select b.org_id, b.variant_id, b.location_id,
         b.qty_reserved,
         coalesce(r.held, 0) as open_holds,
         b.qty_reserved - coalesce(r.held, 0) as drift
  from inventory.stock_balances b
  left join (
    select org_id, variant_id, location_id, sum(qty) as held
    from inventory.reservations where status = 'held'
    group by org_id, variant_id, location_id
  ) r on r.org_id = b.org_id and r.variant_id = b.variant_id and r.location_id = b.location_id
  where b.qty_reserved <> coalesce(r.held, 0);

-- RULE: every product has exactly one default variant.
create or replace view core.variant_integrity as
  select p.org_id, p.id as product_id, p.name, count(v.id) filter (where v.is_default) as defaults
  from core.products p
  left join core.product_variants v on v.product_id = p.id
  group by p.org_id, p.id, p.name
  having count(v.id) filter (where v.is_default) <> 1;

-- RULE: a published catalogue must have a matching snapshot.
create or replace view catalogue.publish_integrity as
  select c.org_id, c.id as catalogue_id, c.slug, c.current_version
  from catalogue.catalogues c
  where c.status = 'published'
    and not exists (
      select 1 from catalogue.published_snapshots s
      where s.catalogue_id = c.id and s.version = c.current_version);

-- ONE PLACE to prove the system is healthy.
create or replace view platform.system_integrity as
  select org_id, 'stock_ledger (balance <> movements, or negative)'::text as rule,
         (variant_id::text || ' @ ' || location_id::text) as what, drift::text as detail
  from inventory.stock_integrity
  union all
  select org_id, 'reservations (reserved <> open holds)',
         (variant_id::text || ' @ ' || location_id::text), drift::text
  from inventory.reservation_integrity
  union all
  select org_id, 'variants (product without exactly one default variant)',
         (product_id::text || ' · ' || name), defaults::text
  from core.variant_integrity
  union all
  select org_id, 'catalogue (published without a snapshot)',
         slug, current_version::text
  from catalogue.publish_integrity;
