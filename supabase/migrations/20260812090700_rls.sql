-- ============================================================================
-- 0008 · ROW LEVEL SECURITY
--
-- Enforcement happens at FOUR layers; this is the one that cannot be bypassed
-- by an application bug: RLS -> server action guard -> connector guard -> UI.
--
-- org_id is ALWAYS derived from the JWT via platform.current_org_id().
-- It is NEVER accepted from a request body or query string. That single rule
-- prevents the most common multi-tenant data leak.
-- ============================================================================

-- ── grants: default deny ───────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on schema platform, core, inventory, catalogue from anon, authenticated;
    grant usage on schema platform, core, inventory, catalogue to authenticated;
    -- anon gets NO table access anywhere. The public catalogue reaches the DB
    -- only through two SECURITY DEFINER functions.
    grant usage on schema catalogue to anon;
    grant execute on function catalogue.public_snapshot(text)     to anon;
    grant execute on function catalogue.public_stock_status(text) to anon;
  end if;
end $$;

-- ── enable RLS everywhere (a table without RLS must fail CI) ───────────────
--
-- FORCE is applied to every table EXCEPT the five that the SECURITY DEFINER
-- authorization helpers read. FORCE applies RLS to the table owner as well, so
-- forcing it on those tables makes is_member()/has_perm()/has_entitlement()
-- evaluate their own policies, which depend on those same functions - the
-- policies silently return nothing and every authorized read yields zero rows.
-- Dropping FORCE on them is safe: the app never connects as the table owner,
-- so ordinary clients still get full RLS enforcement.
do $$
declare r record;
  auth_source text[] := array['org_members','role_permissions','roles',
                              'app_entitlements','app_connections'];
begin
  for r in
    select schemaname, tablename from pg_tables
    where schemaname in ('platform','core','inventory','catalogue')
  loop
    execute format('alter table %I.%I enable row level security', r.schemaname, r.tablename);
    if not (r.schemaname = 'platform' and r.tablename = any(auth_source)) then
      execute format('alter table %I.%I force row level security', r.schemaname, r.tablename);
    end if;
  end loop;
end $$;

-- ── generic tenant policy for tables that need only membership ─────────────
do $$
declare r record;
begin
  for r in
    select schemaname, tablename from pg_tables
    where (schemaname = 'platform' and tablename in (
             'organizations','org_members','roles','settings',
             'custom_field_defs','audit_logs','outbox','subscriptions',
             'app_entitlements','app_connections'))
       or (schemaname = 'core' and tablename in (
             'categories','brands','units','tax_rates','pricing_formulas'))
  loop
    execute format($f$
      create policy tenant_read on %I.%I for select
        using (%s platform.is_member());
    $f$, r.schemaname, r.tablename,
        case when r.tablename = 'organizations'
             then 'id = platform.current_org_id() and'
             else 'org_id = platform.current_org_id() and' end);
  end loop;
end $$;

-- Child tables keyed off a parent rather than org_id.
create policy tenant_read on platform.role_permissions for select
  using (exists (select 1 from platform.roles r
                 where r.id = role_id
                   and (r.org_id is null or r.org_id = platform.current_org_id()))
         and platform.is_member());
create policy tenant_read on platform.subscription_items for select
  using (exists (select 1 from platform.subscriptions s
                 where s.id = subscription_id and s.org_id = platform.current_org_id()));

-- Reference tables that are org-independent stay readable to any member.
create policy ref_read on platform.permissions for select using (platform.is_member());
create policy ref_read on platform.apps        for select using (platform.is_member());
create policy ref_read on platform.plans       for select using (platform.is_member());
create policy ref_read on platform.bundles     for select using (platform.is_member());
create policy ref_read on platform.bundle_contents for select using (platform.is_member());
create policy ref_read on platform.feature_flags   for select using (platform.is_member());
create policy ref_read on platform.industry_templates for select using (platform.is_member());
alter table platform.permissions          enable row level security;
alter table platform.apps                 enable row level security;
alter table platform.plans                enable row level security;
alter table platform.bundles              enable row level security;
alter table platform.bundle_contents      enable row level security;
alter table platform.feature_flags        enable row level security;
alter table platform.industry_templates   enable row level security;

-- ── platform writes: tightly held ─────────────────────────────────────────
create policy team_write on platform.org_members for all
  using      (org_id = platform.current_org_id() and platform.has_perm('team.manage'))
  with check (org_id = platform.current_org_id() and platform.has_perm('team.manage'));

create policy roles_write on platform.roles for all
  using      (org_id = platform.current_org_id() and platform.has_perm('roles.manage'))
  with check (org_id = platform.current_org_id() and platform.has_perm('roles.manage'));

create policy conn_write on platform.app_connections for all
  using      (org_id = platform.current_org_id() and platform.has_perm('connections.manage'))
  with check (org_id = platform.current_org_id() and platform.has_perm('connections.manage'));

create policy settings_write on platform.settings for all
  using      (org_id = platform.current_org_id() and platform.has_perm('settings.manage'))
  with check (org_id = platform.current_org_id() and platform.has_perm('settings.manage'));

create policy org_write on platform.organizations for update
  using      (id = platform.current_org_id() and platform.has_perm('settings.manage'))
  with check (id = platform.current_org_id() and platform.has_perm('settings.manage'));

-- audit_logs and outbox are append-only from the app's perspective: no update
-- or delete policy is ever created for them.
create policy audit_insert on platform.audit_logs for insert
  with check (org_id = platform.current_org_id() and platform.is_member());

-- ── core: products are a platform capability, not an Inventory feature ─────
-- Note there is deliberately NO entitlement check on core.products. A
-- Catalogue-only customer must be able to create products.
create policy products_read on core.products for select
  using (org_id = platform.current_org_id() and platform.has_perm('products.view'));
create policy products_insert on core.products for insert
  with check (org_id = platform.current_org_id() and platform.has_perm('products.create'));
create policy products_update on core.products for update
  using      (org_id = platform.current_org_id() and platform.has_perm('products.edit'))
  with check (org_id = platform.current_org_id() and platform.has_perm('products.edit'));
create policy products_delete on core.products for delete
  using (org_id = platform.current_org_id() and platform.has_perm('products.delete'));

create policy variants_read on core.product_variants for select
  using (org_id = platform.current_org_id() and platform.has_perm('products.view'));
create policy variants_write on core.product_variants for all
  using      (org_id = platform.current_org_id() and platform.has_perm('products.variants'))
  with check (org_id = platform.current_org_id() and platform.has_perm('products.variants'));

do $$
declare t text;
begin
  foreach t in array array['product_options','product_option_values','product_barcodes','product_images']
  loop
    if t = 'product_option_values' then
      execute format($f$
        create policy child_read on core.%I for select using (platform.is_member());
        create policy child_write on core.%I for all
          using (platform.has_perm('products.variants'))
          with check (platform.has_perm('products.variants'));
      $f$, t, t);
    else
      execute format($f$
        create policy child_read on core.%I for select
          using (org_id = platform.current_org_id() and platform.has_perm('products.view'));
        create policy child_write on core.%I for all
          using      (org_id = platform.current_org_id() and platform.has_perm('products.edit'))
          with check (org_id = platform.current_org_id() and platform.has_perm('products.edit'));
      $f$, t, t);
    end if;
  end loop;
end $$;

-- Cost price is gated SEPARATELY from product editing. In Indian SMBs staff
-- routinely edit products but must never see purchase price.
create policy price_overrides_read on core.price_overrides for select
  using (org_id = platform.current_org_id() and platform.has_perm('products.view'));
create policy price_overrides_write on core.price_overrides for all
  using      (org_id = platform.current_org_id() and platform.has_perm('pricing.edit'))
  with check (org_id = platform.current_org_id() and platform.has_perm('pricing.edit'));

create policy tax_write on core.tax_rates for all
  using      (org_id = platform.current_org_id() and platform.has_perm('settings.tax'))
  with check (org_id = platform.current_org_id() and platform.has_perm('settings.tax'));
create policy formula_write on core.pricing_formulas for all
  using      (org_id = platform.current_org_id() and platform.has_perm('pricing.edit'))
  with check (org_id = platform.current_org_id() and platform.has_perm('pricing.edit'));

do $$
declare t text;
begin
  foreach t in array array['categories','brands','units'] loop
    execute format($f$
      create policy taxonomy_write on core.%I for all
        using      (org_id = platform.current_org_id() and platform.has_perm('products.edit'))
        with check (org_id = platform.current_org_id() and platform.has_perm('products.edit'));
    $f$, t);
  end loop;
end $$;

-- ── inventory: entitlement + permission + location scope ───────────────────
create policy locations_read on inventory.locations for select
  using (org_id = platform.current_org_id()
         and platform.has_entitlement('inventory')
         and platform.has_perm('inventory.view'));
create policy locations_write on inventory.locations for all
  using      (org_id = platform.current_org_id()
              and platform.has_entitlement('inventory')
              and platform.has_perm('inventory.locations'))
  with check (org_id = platform.current_org_id()
              and platform.has_entitlement('inventory')
              and platform.has_perm('inventory.locations'));

create policy movements_read on inventory.stock_movements for select
  using (org_id = platform.current_org_id()
         and platform.has_entitlement('inventory')
         and platform.has_perm('inventory.view')
         and platform.can_access_location(location_id));
-- Direction decides the permission: adding stock is routine, removing is not.
create policy movements_insert on inventory.stock_movements for insert
  with check (org_id = platform.current_org_id()
              and platform.has_entitlement('inventory')
              and platform.can_access_location(location_id)
              and case when qty_delta > 0 then platform.has_perm('inventory.add')
                                          else platform.has_perm('inventory.remove') end);
-- No update/delete policy exists. The ledger is append-only, by omission and
-- by the rules declared in 0005.

create policy balances_read on inventory.stock_balances for select
  using (org_id = platform.current_org_id()
         and platform.has_entitlement('inventory')
         and platform.has_perm('inventory.view')
         and platform.can_access_location(location_id));

create policy reservations_read on inventory.reservations for select
  using (org_id = platform.current_org_id() and platform.has_entitlement('inventory'));
-- Another app may hold stock only when the connection is live.
create policy reservations_write on inventory.reservations for all
  using      (org_id = platform.current_org_id()
              and (platform.has_perm('inventory.remove')
                   or platform.is_connected(source_app, 'inventory')))
  with check (org_id = platform.current_org_id()
              and (platform.has_perm('inventory.remove')
                   or platform.is_connected(source_app, 'inventory')));

do $$
declare t text; p text;
begin
  for t, p in
    select * from (values
      ('transfers','inventory.transfer'), ('adjustments','inventory.remove'),
      ('stock_counts','inventory.count'), ('reorder_rules','inventory.view')) v(a,b)
  loop
    execute format($f$
      create policy inv_read on inventory.%I for select
        using (org_id = platform.current_org_id()
               and platform.has_entitlement('inventory')
               and platform.has_perm('inventory.view'));
      create policy inv_write on inventory.%I for all
        using      (org_id = platform.current_org_id()
                    and platform.has_entitlement('inventory') and platform.has_perm(%L))
        with check (org_id = platform.current_org_id()
                    and platform.has_entitlement('inventory') and platform.has_perm(%L));
    $f$, t, t, p, p);
  end loop;
end $$;

-- Line tables inherit access from their header.
create policy lines_all on inventory.transfer_lines for all
  using (exists (select 1 from inventory.transfers h
                 where h.id = transfer_id and h.org_id = platform.current_org_id()))
  with check (exists (select 1 from inventory.transfers h
                 where h.id = transfer_id and h.org_id = platform.current_org_id()));
create policy lines_all on inventory.adjustment_lines for all
  using (exists (select 1 from inventory.adjustments h
                 where h.id = adjustment_id and h.org_id = platform.current_org_id()))
  with check (exists (select 1 from inventory.adjustments h
                 where h.id = adjustment_id and h.org_id = platform.current_org_id()));
create policy lines_all on inventory.stock_count_lines for all
  using (exists (select 1 from inventory.stock_counts h
                 where h.id = count_id and h.org_id = platform.current_org_id()))
  with check (exists (select 1 from inventory.stock_counts h
                 where h.id = count_id and h.org_id = platform.current_org_id()));

-- ── catalogue ──────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['catalogues','catalogue_categories','catalogue_items'] loop
    execute format($f$
      create policy cat_read on catalogue.%I for select
        using (org_id = platform.current_org_id()
               and platform.has_entitlement('catalogue')
               and platform.has_perm('catalogue.view'));
      create policy cat_write on catalogue.%I for all
        using      (org_id = platform.current_org_id()
                    and platform.has_entitlement('catalogue') and platform.has_perm('catalogue.edit'))
        with check (org_id = platform.current_org_id()
                    and platform.has_entitlement('catalogue') and platform.has_perm('catalogue.edit'));
    $f$, t, t);
  end loop;
end $$;

create policy snapshots_read on catalogue.published_snapshots for select
  using (exists (select 1 from catalogue.catalogues c
                 where c.id = catalogue_id and c.org_id = platform.current_org_id()));
create policy snapshots_write on catalogue.published_snapshots for insert
  with check (platform.has_perm('catalogue.publish')
              and exists (select 1 from catalogue.catalogues c
                          where c.id = catalogue_id and c.org_id = platform.current_org_id()));

create policy enquiries_read on catalogue.enquiries for select
  using (org_id = platform.current_org_id()
         and platform.has_entitlement('catalogue')
         and platform.has_perm('catalogue.enquiries'));
create policy enquiries_update on catalogue.enquiries for update
  using      (org_id = platform.current_org_id() and platform.has_perm('catalogue.enquiries'))
  with check (org_id = platform.current_org_id() and platform.has_perm('catalogue.enquiries'));
-- Public enquiry submission goes through a rate-limited SECURITY DEFINER
-- function in 0009, never a direct anon insert.
