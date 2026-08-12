-- ============================================================================
-- 0002 · PLATFORM FUNCTIONS + SEED
--
-- PERFORMANCE CONTRACT (do not "simplify" these):
--   * auth.uid() / auth.jwt() are ALWAYS wrapped as (select ...) so Postgres
--     evaluates them once as an InitPlan instead of once per row. On a large
--     tenant scan this is a 10-100x difference.
--   * Every helper is STABLE. Permission/entitlement readers are SECURITY
--     DEFINER so RLS on the tables they read cannot recurse.
-- ============================================================================

-- The active organization, taken from the JWT. NEVER from a request parameter.
create or replace function platform.current_org_id() returns uuid
language sql stable
set search_path = platform, public
as $$
  select nullif(((select auth.jwt()) -> 'app_metadata' ->> 'org_id'), '')::uuid
$$;

create or replace function platform.current_user_id() returns uuid
language sql stable as $$ select (select auth.uid()) $$;

-- Is the caller an active member of the active org?
create or replace function platform.is_member() returns boolean
language sql stable security definer
set search_path = platform, public
as $$
  select exists (
    select 1 from platform.org_members m
    where m.org_id  = platform.current_org_id()
      and m.user_id = (select auth.uid())
      and m.status  = 'active'
  )
$$;

-- Does the active org hold a usable entitlement for this app?
-- past_due is deliberately included: a failed mandate must not take a shop
-- offline mid-day. Downgrade to 'paused' happens on a schedule, not instantly.
create or replace function platform.has_entitlement(p_app text) returns boolean
language sql stable security definer
set search_path = platform, public
as $$
  select exists (
    select 1 from platform.app_entitlements e
    where e.org_id  = platform.current_org_id()
      and e.app_key = p_app
      and e.status in ('trialing','active','past_due')
  )
$$;

create or replace function platform.has_perm(p_perm text) returns boolean
language sql stable security definer
set search_path = platform, public
as $$
  select exists (
    select 1
    from platform.org_members m
    join platform.role_permissions rp on rp.role_id = m.role_id
    where m.org_id  = platform.current_org_id()
      and m.user_id = (select auth.uid())
      and m.status  = 'active'
      and rp.permission_key = p_perm
  )
$$;

-- Is `source_app` allowed to read `target_app` data for the active org?
create or replace function platform.is_connected(p_source text, p_target text) returns boolean
language sql stable security definer
set search_path = platform, public
as $$
  select exists (
    select 1 from platform.app_connections c
    where c.org_id = platform.current_org_id()
      and c.source_app = p_source
      and c.target_app = p_target
      and c.status = 'active'
  ) and platform.has_entitlement(p_target)
$$;

-- Location scoping. NULL location_ids on the membership = all locations.
create or replace function platform.can_access_location(p_location uuid) returns boolean
language sql stable security definer
set search_path = platform, public
as $$
  select coalesce((
    select m.location_ids is null or p_location = any(m.location_ids)
    from platform.org_members m
    where m.org_id  = platform.current_org_id()
      and m.user_id = (select auth.uid())
      and m.status  = 'active'
  ), false)
$$;

-- Convenience for server code: emit a domain event inside the caller's txn.
create or replace function platform.emit(p_topic text, p_payload jsonb)
returns bigint language sql
set search_path = platform, public
as $$
  insert into platform.outbox(org_id, topic, payload)
  values (platform.current_org_id(), p_topic, p_payload)
  returning id
$$;

-- ── seed: apps ─────────────────────────────────────────────────────────────
insert into platform.apps(key, name, description, is_sellable, sort) values
  ('inventory','Inventory','Stock, locations, movements, transfers and counts', true, 10),
  ('catalogue','Share Catalogue','Public digital catalogue with WhatsApp sharing', true, 20),
  ('pos','POS & Billing','Point of sale, GST invoicing and estimates',           false, 30)
on conflict (key) do nothing;

-- ── seed: permissions ──────────────────────────────────────────────────────
-- Ported and regrouped from the Yogendra build's lib/permissions.ts, which had
-- the right instincts: cost visibility separated from product editing, and the
-- destructive stock operation split out from the additive one.
insert into platform.permissions(key, app_key, label, description, is_sensitive) values
  ('products.view',        'core','View products',            null, false),
  ('products.create',      'core','Create products',          null, false),
  ('products.edit',        'core','Edit products',            null, false),
  ('products.delete',      'core','Delete products',          null, true),
  ('products.import',      'core','Bulk import products',     null, false),
  ('products.variants',    'core','Manage variants',          null, false),
  ('pricing.view_cost',    'core','See cost price',           'staff often edit products but must never see purchase price', true),
  ('pricing.edit',         'core','Edit prices',              null, true),
  ('pricing.manage_lists', 'core','Manage price lists',       null, true),
  ('settings.tax',         'core','Manage tax and GST setup', null, true),

  ('inventory.view',       'inventory','View stock',                   null, false),
  ('inventory.add',        'inventory','Add / increase stock',         null, false),
  ('inventory.remove',     'inventory','Remove / decrease stock',      'the destructive one', true),
  ('inventory.transfer',   'inventory','Transfer stock between locations', null, false),
  ('inventory.count',      'inventory','Run physical stock counts',    null, false),
  ('inventory.approve',    'inventory','Approve adjustments and counts', null, true),
  ('inventory.locations',  'inventory','Manage locations',             null, true),
  ('inventory.barcode',    'inventory','Generate and print barcodes',  null, false),

  ('catalogue.view',       'catalogue','View catalogues',              null, false),
  ('catalogue.edit',       'catalogue','Edit catalogues',              null, false),
  ('catalogue.publish',    'catalogue','Publish / unpublish',          null, true),
  ('catalogue.theme',      'catalogue','Manage theme and branding',    null, false),
  ('catalogue.domain',     'catalogue','Manage custom domain',         null, true),
  ('catalogue.enquiries',  'catalogue','View and answer enquiries',    null, false),
  ('orders.view',          'catalogue','View orders',                  null, false),
  ('orders.accept',        'catalogue','Accept / reject orders',       null, false),
  ('orders.cancel',        'catalogue','Cancel orders',                null, true),

  ('reports.view',         'core','View reports',            null, false),
  ('reports.export',       'core','Export data',             null, true),
  ('team.manage',          'core','Manage team members',     null, true),
  ('roles.manage',         'core','Manage roles',            null, true),
  ('connections.manage',   'core','Connect / disconnect apps', null, true),
  ('settings.manage',      'core','Manage business settings', null, true),
  ('billing.manage',       'core','Manage subscription and billing', null, true)
on conflict (key) do nothing;

-- ── seed: system roles ─────────────────────────────────────────────────────
insert into platform.roles(id, org_id, key, name, is_system) values
  (gen_random_uuid(), null, 'owner',             'Owner',             true),
  (gen_random_uuid(), null, 'admin',             'Admin',             true),
  (gen_random_uuid(), null, 'manager',           'Manager',           true),
  (gen_random_uuid(), null, 'inventory_manager', 'Inventory Manager', true),
  (gen_random_uuid(), null, 'catalogue_manager', 'Catalogue Manager', true),
  (gen_random_uuid(), null, 'staff',             'Staff',             true)
on conflict do nothing;

-- owner + admin: everything.
insert into platform.role_permissions(role_id, permission_key)
select r.id, p.key from platform.roles r cross join platform.permissions p
where r.org_id is null and r.key in ('owner','admin')
on conflict do nothing;

-- manager: everything except role/billing/connection control and cost.
insert into platform.role_permissions(role_id, permission_key)
select r.id, p.key from platform.roles r cross join platform.permissions p
where r.org_id is null and r.key = 'manager'
  and p.key not in ('roles.manage','billing.manage','connections.manage',
                    'settings.manage','products.delete','pricing.view_cost')
on conflict do nothing;

insert into platform.role_permissions(role_id, permission_key)
select r.id, k from platform.roles r
cross join unnest(array[
  'products.view','products.create','products.edit','products.import','products.variants',
  'pricing.view_cost','pricing.edit',
  'inventory.view','inventory.add','inventory.remove','inventory.transfer',
  'inventory.count','inventory.approve','inventory.locations','inventory.barcode',
  'reports.view'
]) as k
where r.org_id is null and r.key = 'inventory_manager'
on conflict do nothing;

insert into platform.role_permissions(role_id, permission_key)
select r.id, k from platform.roles r
cross join unnest(array[
  'products.view','products.edit',
  'catalogue.view','catalogue.edit','catalogue.publish','catalogue.theme',
  'catalogue.enquiries','orders.view','orders.accept',
  'inventory.view','reports.view'
]) as k
where r.org_id is null and r.key = 'catalogue_manager'
on conflict do nothing;

-- staff: deliberately cannot remove stock or see cost.
insert into platform.role_permissions(role_id, permission_key)
select r.id, k from platform.roles r
cross join unnest(array[
  'products.view','inventory.view','inventory.add','inventory.count',
  'catalogue.view','catalogue.enquiries','orders.view'
]) as k
where r.org_id is null and r.key = 'staff'
on conflict do nothing;
