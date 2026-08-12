-- ============================================================================
-- NEWVORA — complete database setup, combined from the 8 verified migrations.
-- Paste into the Supabase SQL editor and Run ONCE, top to bottom.
-- (Safe on a brand-new project only. Do not run on a database with data.)
-- ============================================================================

-- ▶▶▶ 20260812090000_platform.sql

-- ============================================================================
-- 0001 · PLATFORM
-- Identity, tenancy, roles, entitlements, subscriptions, app connections,
-- configuration, custom-field definitions, audit, and the event outbox.
--
-- Contains NO business logic. If a function here needed to know what a stock
-- transfer is, it would belong in the inventory schema instead.
-- ============================================================================

-- gen_random_uuid() is core Postgres since v13 - no pgcrypto dependency.
-- pg_trgm powers product search; it is available on Supabase but optional
-- here so the migration set also applies to a bare Postgres in CI.
do $$ begin
  create extension if not exists pg_trgm;
exception when others then
  raise notice 'pg_trgm unavailable; product trigram search index will be skipped';
end $$;

create schema if not exists platform;

-- ── helpers ────────────────────────────────────────────────────────────────
create or replace function platform.set_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- ── organizations (one per business) ───────────────────────────────────────
create table platform.organizations (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique
                   check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
  name           text not null,
  legal_name     text,
  industry_key   text,
  -- India-first, but not India-only.
  country        char(2) not null default 'IN',
  currency       char(3) not null default 'INR',
  state_code     char(2),                       -- GST state code, e.g. '07' Delhi
  gstin          text,
  pan            text,
  fiscal_year_start text not null default '04-01',
  status         text not null default 'active'
                   check (status in ('active','suspended','deleted')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger trg_org_updated before update on platform.organizations
  for each row execute function platform.set_updated_at();

-- GSTIN, when present, must agree with the org's state code.
alter table platform.organizations add constraint org_gstin_matches_state
  check (gstin is null or state_code is null or left(gstin,2) = state_code);

-- ── roles & permissions ────────────────────────────────────────────────────
-- org_id NULL = a system role available to every org.
create table platform.roles (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid references platform.organizations(id) on delete cascade,
  key        text not null,
  name       text not null,
  is_system  boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index roles_system_key_uq on platform.roles(key) where org_id is null;
create unique index roles_org_key_uq     on platform.roles(org_id, key) where org_id is not null;

create table platform.permissions (
  key         text primary key,
  app_key     text not null,
  label       text not null,
  description text,
  is_sensitive boolean not null default false
);

create table platform.role_permissions (
  role_id        uuid not null references platform.roles(id) on delete cascade,
  permission_key text not null references platform.permissions(key) on delete cascade,
  primary key (role_id, permission_key)
);

-- ── membership ─────────────────────────────────────────────────────────────
-- location_ids NULL = all locations. A branch cashier must not see HO stock.
create table platform.org_members (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references platform.organizations(id) on delete cascade,
  user_id      uuid not null,                    -- auth.users.id
  role_id      uuid not null references platform.roles(id),
  location_ids uuid[],
  status       text not null default 'active'
                 check (status in ('invited','active','suspended')),
  invited_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (org_id, user_id)
);
create index org_members_user_idx on platform.org_members(user_id) where status = 'active';
create index org_members_org_idx  on platform.org_members(org_id, status);
create trigger trg_member_updated before update on platform.org_members
  for each row execute function platform.set_updated_at();

-- ── apps, plans, bundles ───────────────────────────────────────────────────
create table platform.apps (
  key          text primary key,                 -- 'inventory' | 'catalogue' | 'pos'
  name         text not null,
  description  text,
  is_sellable  boolean not null default true,
  sort         int not null default 0
);

create table platform.plans (
  key               text primary key,
  app_key           text not null references platform.apps(key) on delete cascade,
  name              text not null,
  price_monthly_paise bigint not null default 0,
  price_annual_paise  bigint not null default 0,
  included_users     int,                        -- null = unlimited
  included_locations int,
  limits            jsonb not null default '{}'::jsonb,
  features          jsonb not null default '{}'::jsonb,
  is_public         boolean not null default true,
  sort              int not null default 0
);

-- A bundle is a PRICING construct only. It never creates an app.
create table platform.bundles (
  key                 text primary key,
  name                text not null,
  price_monthly_paise bigint not null default 0,
  price_annual_paise  bigint not null default 0,
  is_public           boolean not null default true
);
create table platform.bundle_contents (
  bundle_key text not null references platform.bundles(key) on delete cascade,
  app_key    text not null references platform.apps(key)    on delete cascade,
  plan_key   text not null references platform.plans(key)   on delete cascade,
  primary key (bundle_key, app_key)
);

-- ── subscriptions ──────────────────────────────────────────────────────────
create table platform.subscriptions (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references platform.organizations(id) on delete cascade,
  provider       text not null default 'razorpay',
  provider_ref   text,
  interval       text not null default 'annual' check (interval in ('monthly','annual')),
  status         text not null default 'trialing'
                   check (status in ('trialing','active','past_due','paused','cancelled')),
  current_period_start timestamptz,
  current_period_end   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (org_id)
);
create trigger trg_sub_updated before update on platform.subscriptions
  for each row execute function platform.set_updated_at();

create table platform.subscription_items (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references platform.subscriptions(id) on delete cascade,
  app_key         text not null references platform.apps(key),
  plan_key        text not null references platform.plans(key),
  bundle_key      text references platform.bundles(key),
  quantity        int not null default 1 check (quantity > 0),
  unit_amount_paise bigint not null default 0,
  created_at      timestamptz not null default now(),
  unique (subscription_id, app_key)
);

-- ── entitlements: the single source of truth for app access ────────────────
create table platform.app_entitlements (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references platform.organizations(id) on delete cascade,
  app_key       text not null references platform.apps(key) on delete cascade,
  plan_key      text references platform.plans(key),
  status        text not null default 'trialing'
                  check (status in ('trialing','active','past_due','paused','cancelled')),
  seats         int,
  locations     int,
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, app_key)
);
create index app_entitlements_active_idx on platform.app_entitlements(org_id, app_key)
  where status in ('trialing','active','past_due');
create trigger trg_ent_updated before update on platform.app_entitlements
  for each row execute function platform.set_updated_at();

-- ── app connections: explicit, revocable, gated ────────────────────────────
create table platform.app_connections (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references platform.organizations(id) on delete cascade,
  source_app   text not null references platform.apps(key) on delete cascade,
  target_app   text not null references platform.apps(key) on delete cascade,
  status       text not null default 'active'
                 check (status in ('pending','active','paused','revoked')),
  config       jsonb not null default '{}'::jsonb,
  connected_at timestamptz not null default now(),
  connected_by uuid,
  revoked_at   timestamptz,
  updated_at   timestamptz not null default now(),
  unique (org_id, source_app, target_app),
  check (source_app <> target_app)
);
create trigger trg_conn_updated before update on platform.app_connections
  for each row execute function platform.set_updated_at();

-- ── configuration ──────────────────────────────────────────────────────────
create table platform.settings (
  org_id  uuid not null references platform.organizations(id) on delete cascade,
  app_key text not null,
  key     text not null,
  value   jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (org_id, app_key, key)
);

-- Resolution precedence: user > location > org > plan > global > code default.
create table platform.feature_flags (
  id        uuid primary key default gen_random_uuid(),
  scope     text not null check (scope in ('global','plan','org','user','location')),
  scope_id  text,
  app_key   text not null,
  flag_key  text not null,
  value     jsonb not null default 'true'::jsonb,
  updated_at timestamptz not null default now(),
  unique (scope, scope_id, app_key, flag_key)
);

-- Every custom field must be declared. No free-form writes into `custom` jsonb.
create table platform.custom_field_defs (
  id       uuid primary key default gen_random_uuid(),
  org_id   uuid not null references platform.organizations(id) on delete cascade,
  entity   text not null,                       -- 'product' | 'variant' | 'party' | ...
  key      text not null check (key ~ '^[a-z][a-z0-9_]{0,38}$'),
  label    text not null,
  type     text not null check (type in ('text','number','date','boolean','select','multiselect')),
  options  jsonb not null default '[]'::jsonb,
  required boolean not null default false,
  position int not null default 0,
  apps     text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (org_id, entity, key)
);

-- Industry editions are seeded configuration, never a code branch.
create table platform.industry_templates (
  key           text primary key,
  name          text not null,
  settings      jsonb not null default '{}'::jsonb,
  flags         jsonb not null default '{}'::jsonb,
  custom_fields jsonb not null default '[]'::jsonb,
  categories    jsonb not null default '[]'::jsonb,
  tax_rates     jsonb not null default '[]'::jsonb
);

-- ── audit ──────────────────────────────────────────────────────────────────
create table platform.audit_logs (
  id        bigserial primary key,
  org_id    uuid not null references platform.organizations(id) on delete cascade,
  actor_id  uuid,
  app_key   text,
  entity    text not null,
  entity_id text,
  action    text not null,
  before    jsonb,
  after     jsonb,
  ip        inet,
  at        timestamptz not null default now()
);
create index audit_org_at_idx     on platform.audit_logs(org_id, at desc);
create index audit_entity_idx     on platform.audit_logs(org_id, entity, entity_id);

-- ── transactional outbox (durable domain events; drained by an Edge Function)
create table platform.outbox (
  id           bigserial primary key,
  org_id       uuid not null references platform.organizations(id) on delete cascade,
  topic        text not null,
  payload      jsonb not null,
  status       text not null default 'pending'
                 check (status in ('pending','processing','done','failed')),
  attempts     int not null default 0,
  last_error   text,
  available_at timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create index outbox_drain_idx on platform.outbox(available_at, id)
  where status in ('pending','failed');

-- ▶▶▶ 20260812090100_platform_functions_seed.sql

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

-- ▶▶▶ 20260812090200_core.sql

-- ============================================================================
-- 0003 · CORE  (shared business objects)
--
-- WHY THIS SCHEMA EXISTS, and why products are NOT in `inventory`:
-- a Catalogue-only customer needs products but has no Inventory entitlement.
-- If products lived in inventory, Catalogue would grow a shadow product table
-- and we would have rebuilt the exact duplication this platform exists to end.
-- Rule: if two apps would both plausibly own it, and a customer buying only
-- one of them still needs it, it belongs in core.
--
-- MONEY: bigint paise everywhere. Never floats. (Carried forward from the
-- Yogendra build, which got this right.)
-- RATES: integer basis points. 300 = 3.00%.
-- ============================================================================

create schema if not exists core;

-- ── taxonomy ───────────────────────────────────────────────────────────────
create table core.categories (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  parent_id  uuid references core.categories(id) on delete set null,
  name       text not null,
  slug       text not null,
  position   int  not null default 0,
  created_at timestamptz not null default now(),
  unique (org_id, slug)
);
create index categories_org_parent_idx on core.categories(org_id, parent_id);

create table core.brands (
  id     uuid primary key default gen_random_uuid(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name   text not null,
  unique (org_id, name)
);

create table core.units (
  id       uuid primary key default gen_random_uuid(),
  org_id   uuid not null references platform.organizations(id) on delete cascade,
  name     text not null,
  short    text not null,
  decimals int  not null default 0 check (decimals between 0 and 3),
  unique (org_id, short)
);

-- ── tax ────────────────────────────────────────────────────────────────────
-- mode mirrors the Yogendra build's orders.gst_mode, which modelled this
-- correctly: null/auto is decided per document, not baked into the product.
create table core.tax_rates (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  name       text not null,
  rate_bp    int  not null default 0 check (rate_bp between 0 and 10000),
  cess_bp    int  not null default 0 check (cess_bp between 0 and 10000),
  mode       text not null default 'exclusive' check (mode in ('inclusive','exclusive','none')),
  is_default boolean not null default false,
  unique (org_id, name)
);
create unique index tax_rates_one_default on core.tax_rates(org_id) where is_default;

-- ── pricing formula ────────────────────────────────────────────────────────
-- Ported from lib/pricing.ts in the Yogendra build (the strongest asset in
-- either legacy repo) and generalised. The two customer forks differed ONLY in
-- values that are now columns here: multipliers, rounding style, tier breaks.
-- That divergence is why the codebase forked; it must never be code again.
create table core.pricing_formulas (
  id       uuid primary key default gen_random_uuid(),
  org_id   uuid not null references platform.organizations(id) on delete cascade,
  key      text not null,
  name     text not null,
  version  int  not null default 1,
  mode     text not null default 'multiplier' check (mode in ('multiplier','buildup')),

  -- multiplier mode
  wholesale_markup_bp int not null default 0,
  retail_multiplier   numeric(10,4) not null default 1.5,
  mrp_multiplier      numeric(10,4) not null default 2.0,
  -- optional banded retail multiplier, e.g.
  -- [{"below_paise":150000,"multiplier":1.6},{"multiplier":1.5}]
  retail_tiers jsonb not null default '[]'::jsonb,

  -- build-up mode (the owner's costing sheet, all steps configurable)
  shipping_bp        int not null default 0,
  packing_flat_paise bigint not null default 0,
  promotion_flat_paise bigint not null default 0,
  reseller_bp        int not null default 0,
  customer_discount_bp int not null default 0,
  mrp_bp             int not null default 0,

  -- display rounding. charm_9 = "must end in 9"; multiple_5 / multiple_10 as named.
  retail_rounding text not null default 'nearest'
    check (retail_rounding in ('nearest','charm_9','multiple_5','multiple_10')),
  mrp_rounding    text not null default 'multiple_5'
    check (mrp_rounding in ('nearest','charm_9','multiple_5','multiple_10')),
  round_to_paise  int not null default 100 check (round_to_paise > 0),

  -- quantity breaks: [{"min_qty":12,"pct_off_bp":500}]
  qty_break_tiers jsonb not null default '[]'::jsonb,
  wholesale_min_order_paise bigint not null default 0,

  is_default     boolean not null default false,
  effective_from timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  unique (org_id, key, version)
);
create unique index pricing_formulas_one_default on core.pricing_formulas(org_id) where is_default;

-- ── products ───────────────────────────────────────────────────────────────
create table core.products (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  name        text not null,
  description text,
  type        text not null default 'goods' check (type in ('goods','service')),
  category_id uuid references core.categories(id) on delete set null,
  brand_id    uuid references core.brands(id)     on delete set null,
  unit_id     uuid references core.units(id)      on delete set null,
  hsn_sac     text,
  tax_rate_id uuid references core.tax_rates(id)  on delete set null,
  formula_id  uuid references core.pricing_formulas(id) on delete set null,
  has_variants boolean not null default false,
  status      text not null default 'active' check (status in ('draft','active','archived')),
  notes       text,
  custom      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid
);
create index products_org_status_idx on core.products(org_id, status);
create index products_org_category_idx on core.products(org_id, category_id);
-- Trigram search index, only when the extension is present.
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm') then
    execute 'create index products_search_idx on core.products using gin (name gin_trgm_ops)';
  else
    execute 'create index products_search_idx on core.products (org_id, lower(name))';
  end if;
end $$;
create index products_custom_idx on core.products using gin (custom jsonb_path_ops);
create trigger trg_products_updated before update on core.products
  for each row execute function platform.set_updated_at();

-- Variant axes. Modelled as options+values rather than a fixed size/colour
-- pair so the engine works for apparel, electronics, hardware and jewellery
-- without schema changes. (The legacy build started with a single `color`
-- column and had to bolt attributes on later.)
create table core.product_options (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  product_id uuid not null references core.products(id) on delete cascade,
  name       text not null,
  position   int  not null default 0,
  unique (product_id, name)
);
create table core.product_option_values (
  id        uuid primary key default gen_random_uuid(),
  option_id uuid not null references core.product_options(id) on delete cascade,
  value     text not null,
  hex       text,
  position  int not null default 0,
  unique (option_id, value)
);

-- EVERY product has at least one variant, including simple products (is_default).
-- Everything downstream - stock, barcode, catalogue, POS - references
-- variant_id and never product_id. This removes an entire class of branching.
create table core.product_variants (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  product_id  uuid not null references core.products(id) on delete cascade,
  sku         text not null,
  name        text,
  attributes  jsonb not null default '{}'::jsonb,   -- {"Size":"M","Colour":"Black"}
  is_default  boolean not null default false,

  base_cost_paise      bigint,     -- purchase / landed cost (permission-gated)
  mrp_paise            bigint,
  selling_price_paise  bigint,
  wholesale_price_paise bigint,
  min_selling_price_paise bigint,

  status      text not null default 'active' check (status in ('active','archived')),
  custom      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, sku)
);
create index variants_product_idx on core.product_variants(org_id, product_id);
create unique index variants_one_default on core.product_variants(product_id) where is_default;
create trigger trg_variants_updated before update on core.product_variants
  for each row execute function platform.set_updated_at();

-- V1 guardrail: refuse absurd variant matrices rather than melting the UI.
create or replace function core.guard_variant_count() returns trigger
language plpgsql as $$
declare n int;
begin
  select count(*) into n from core.product_variants where product_id = new.product_id;
  if n >= 500 then
    raise exception 'variant limit reached for product % (max 500)', new.product_id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger trg_variant_limit before insert on core.product_variants
  for each row execute function core.guard_variant_count();

create table core.product_barcodes (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  variant_id uuid not null references core.product_variants(id) on delete cascade,
  barcode    text not null,
  type       text not null default 'INTERNAL' check (type in ('EAN13','UPCA','CODE128','QR','INTERNAL')),
  is_primary boolean not null default false,
  unique (org_id, barcode)
);
create index barcodes_variant_idx on core.product_barcodes(variant_id);

create table core.product_images (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  product_id  uuid not null references core.products(id) on delete cascade,
  variant_id  uuid references core.product_variants(id) on delete cascade,
  storage_path text not null,
  alt         text,
  position    int not null default 0
);
create index product_images_product_idx on core.product_images(product_id, position);

-- Explicit price pins. Resolution order: variant -> product -> formula.
create table core.price_overrides (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  variant_id uuid references core.product_variants(id) on delete cascade,
  product_id uuid references core.products(id) on delete cascade,
  tier       text not null check (tier in ('wholesale','retail','mrp')),
  price_paise bigint not null check (price_paise > 0),
  check (num_nonnulls(variant_id, product_id) = 1)
);
create unique index price_override_variant_uq on core.price_overrides(variant_id, tier) where variant_id is not null;
create unique index price_override_product_uq on core.price_overrides(product_id, tier) where product_id is not null;

-- Simple products still get a variant, automatically. Nothing downstream has
-- to ask "does this product have variants?".
create or replace function core.ensure_default_variant() returns trigger
language plpgsql security definer
set search_path = core, public
as $$
begin
  if not new.has_variants then
    insert into core.product_variants(org_id, product_id, sku, is_default)
    values (new.org_id, new.id,
            'SKU-' || upper(substr(replace(new.id::text,'-',''), 1, 10)),
            true)
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger trg_product_default_variant after insert on core.products
  for each row execute function core.ensure_default_variant();

-- ▶▶▶ 20260812090300_core_pricing_fn.sql

-- ============================================================================
-- 0004 · PRICING FUNCTIONS
--
-- The SAME formula must exist in SQL and in TypeScript (packages/pricing), so
-- what the catalogue displays is always what the bill charges. The legacy
-- build learned this the hard way and mirrored bd_price() in lib/pricing.ts;
-- we keep that discipline and add a test that asserts the two agree.
-- ============================================================================

create or replace function core.round_step(v numeric, step int) returns bigint
language sql immutable as $$
  select case when step is null or step <= 0 then round(v)::bigint
              else (round(v / step) * step)::bigint end
$$;

-- Round UP to the next whole rupee ending in 9. Never down: the charm price
-- must not dip below the formula output, or margin silently erodes.
create or replace function core.round_charm9(v numeric) returns bigint
language sql immutable as $$
  select case when v is null or v <= 0 then round(coalesce(v,0))::bigint
  else ((greatest(1, round(v / 100)) + ((9 - (greatest(1, round(v / 100))::bigint % 10) + 10) % 10)) * 100)::bigint
  end
$$;

-- Round to a whole rupee that is a multiple of n. `floor_paise` (used for MRP)
-- guarantees the printed MRP is never below the selling price.
create or replace function core.round_multiple(v numeric, n int, floor_paise bigint default null)
returns bigint language sql immutable as $$
  with r as (select greatest(n, (round(v / 100.0 / n) * n))::bigint as rupees)
  select case
    when floor_paise is not null and (select rupees from r) * 100 < floor_paise
      then (ceil(ceil(floor_paise / 100.0) / n) * n * 100)::bigint
    else (select rupees from r) * 100
  end
$$;

create or replace function core.apply_rounding(v numeric, style text, step int, floor_paise bigint default null)
returns bigint language sql immutable as $$
  select case style
    when 'charm_9'     then core.round_charm9(v)
    when 'multiple_5'  then core.round_multiple(v, 5,  floor_paise)
    when 'multiple_10' then core.round_multiple(v, 10, floor_paise)
    else core.round_step(v, step)
  end
$$;

-- Banded retail multiplier: [{"below_paise":150000,"multiplier":1.6},{"multiplier":1.5}]
-- First matching band wins; a band without below_paise is the catch-all.
create or replace function core.retail_multiplier_for(base_paise bigint, f core.pricing_formulas)
returns numeric language sql immutable as $$
  select coalesce((
    select (t->>'multiplier')::numeric
    from jsonb_array_elements(f.retail_tiers) with ordinality as e(t, ord)
    where (t->>'below_paise') is null or base_paise < (t->>'below_paise')::bigint
    order by ord limit 1
  ), f.retail_multiplier)
$$;

-- The full price set for a base cost under a formula.
create or replace function core.compute_prices(base_paise bigint, p_formula_id uuid)
returns table (wholesale_paise bigint, retail_paise bigint, mrp_paise bigint)
language plpgsql stable
set search_path = core, public
as $$
declare f core.pricing_formulas; b numeric; w numeric; r numeric; m numeric; rp bigint;
begin
  select * into f from core.pricing_formulas where id = p_formula_id;
  if not found or base_paise is null or base_paise <= 0 then
    return query select null::bigint, null::bigint, null::bigint; return;
  end if;
  b := base_paise;

  if f.mode = 'buildup' then
    -- the owner's costing sheet, step by step
    w := b;
    r := b * (1 + f.shipping_bp / 10000.0)
           + f.packing_flat_paise + f.promotion_flat_paise;
    r := r * (1 + f.reseller_bp / 10000.0);
    r := r * (1 + f.customer_discount_bp / 10000.0);
    m := r * (1 + f.mrp_bp / 10000.0);
  else
    w := b * (1 + f.wholesale_markup_bp / 10000.0);
    r := b * core.retail_multiplier_for(base_paise, f);
    m := b * f.mrp_multiplier;
  end if;

  rp := core.apply_rounding(r, f.retail_rounding, f.round_to_paise);
  return query select
    core.round_step(w, f.round_to_paise),
    rp,
    core.apply_rounding(m, f.mrp_rounding, f.round_to_paise, rp);
end $$;

-- Effective price for one variant and tier: explicit override wins, else formula.
create or replace function core.resolve_price(p_variant uuid, p_tier text)
returns bigint language plpgsql stable
set search_path = core, public
as $$
declare v core.product_variants; pr core.products; ov bigint; c record;
begin
  select * into v from core.product_variants where id = p_variant;
  if not found then return null; end if;
  select * into pr from core.products where id = v.product_id;

  select price_paise into ov from core.price_overrides
   where variant_id = p_variant and tier = p_tier;
  if ov is not null then return ov; end if;

  select price_paise into ov from core.price_overrides
   where product_id = v.product_id and tier = p_tier;
  if ov is not null then return ov; end if;

  -- a price typed directly onto the variant beats the formula
  if p_tier = 'retail'    and v.selling_price_paise   is not null then return v.selling_price_paise;   end if;
  if p_tier = 'wholesale' and v.wholesale_price_paise is not null then return v.wholesale_price_paise; end if;
  if p_tier = 'mrp'       and v.mrp_paise             is not null then return v.mrp_paise;             end if;

  if pr.formula_id is null or v.base_cost_paise is null then return null; end if;
  select * into c from core.compute_prices(v.base_cost_paise, pr.formula_id);
  return case p_tier when 'wholesale' then c.wholesale_paise
                     when 'retail'    then c.retail_paise
                     else c.mrp_paise end;
end $$;

-- Best quantity break for a line, in basis points off.
create or replace function core.qty_break_bp(p_formula_id uuid, p_qty numeric)
returns int language sql stable
set search_path = core, public
as $$
  select coalesce(max((t->>'pct_off_bp')::int), 0)
  from core.pricing_formulas f,
       jsonb_array_elements(f.qty_break_tiers) as t
  where f.id = p_formula_id and p_qty >= (t->>'min_qty')::numeric
$$;

-- Sanity rules the legacy build enforced and we keep: never sell above MRP,
-- and a wholesale buyer must always beat the retail shopper.
create or replace function core.price_set_is_valid(w bigint, r bigint, m bigint)
returns boolean language sql immutable as $$
  select w is not null and r is not null and m is not null
     and w > 0 and r > 0 and m > 0
     and r <= m and w < r
$$;

-- ▶▶▶ 20260812090400_inventory.sql

-- ============================================================================
-- 0005 · INVENTORY  (ledger-first)
--
-- THE ONE INVARIANT: stock_movements is append-only and authoritative.
-- stock_balances is a cache maintained by trigger inside the same transaction.
-- They cannot disagree, because there is exactly one writer.
--
-- The legacy build made variants.qty authoritative WITH a parallel log, and
-- then needed ~10 migrations (0051, 0062, 0064, 0066-0070) to repair the drift
-- that design guarantees. Guard views treated the symptom. This removes the
-- cause. Corrections are new compensating movements, never edits.
-- ============================================================================

create schema if not exists inventory;

create table inventory.locations (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  name       text not null,
  type       text not null default 'shop'
               check (type in ('shop','warehouse','godown','vehicle','virtual')),
  address    jsonb not null default '{}'::jsonb,
  is_default boolean not null default false,
  status     text not null default 'active' check (status in ('active','archived')),
  created_at timestamptz not null default now(),
  unique (org_id, name)
);
create unique index locations_one_default on inventory.locations(org_id) where is_default;

-- ── the ledger ─────────────────────────────────────────────────────────────
create table inventory.stock_movements (
  id          bigserial primary key,
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  variant_id  uuid not null references core.product_variants(id) on delete restrict,
  location_id uuid not null references inventory.locations(id)   on delete restrict,
  qty_delta   numeric(18,3) not null check (qty_delta <> 0),
  reason      text not null check (reason in (
                'opening','purchase','sale','sale_return','purchase_return',
                'transfer_out','transfer_in','adjustment','damage','expiry',
                'theft','count_correction','production_in','production_out')),
  ref_type    text,
  ref_id      uuid,
  unit_cost_paise bigint,
  occurred_at timestamptz not null default now(),
  created_by  uuid,
  note        text
);
create index movements_variant_idx  on inventory.stock_movements(org_id, variant_id, occurred_at desc);
create index movements_location_idx on inventory.stock_movements(org_id, location_id, occurred_at desc);
create index movements_ref_idx      on inventory.stock_movements(ref_type, ref_id);

-- Append-only, enforced at the table. No policy grants update or delete, and
-- these rules make it explicit even for a superuser path.
create rule stock_movements_no_update as on update to inventory.stock_movements do instead nothing;
create rule stock_movements_no_delete as on delete to inventory.stock_movements do instead nothing;

create table inventory.stock_balances (
  org_id        uuid not null references platform.organizations(id) on delete cascade,
  variant_id    uuid not null references core.product_variants(id) on delete cascade,
  location_id   uuid not null references inventory.locations(id)   on delete cascade,
  qty_on_hand   numeric(18,3) not null default 0,
  qty_reserved  numeric(18,3) not null default 0 check (qty_reserved >= 0),
  qty_available numeric(18,3) generated always as (qty_on_hand - qty_reserved) stored,
  moving_avg_cost_paise bigint,
  last_movement_id bigint,
  updated_at    timestamptz not null default now(),
  primary key (org_id, variant_id, location_id)
);
create index balances_location_idx on inventory.stock_balances(org_id, location_id)
  where qty_on_hand <> 0;

-- Balance maintenance + moving average cost, in-transaction.
create or replace function inventory.apply_movement() returns trigger
language plpgsql security definer
set search_path = inventory, core, public
as $$
declare prev_qty numeric(18,3); prev_cost bigint; new_cost bigint;
begin
  select qty_on_hand, moving_avg_cost_paise into prev_qty, prev_cost
  from inventory.stock_balances
  where org_id = new.org_id and variant_id = new.variant_id and location_id = new.location_id
  for update;

  if new.qty_delta > 0 and new.unit_cost_paise is not null then
    -- weighted average; inbound at a known cost only
    new_cost := case
      when prev_qty is null or prev_qty <= 0 then new.unit_cost_paise
      else ((coalesce(prev_cost,0) * prev_qty) + (new.unit_cost_paise * new.qty_delta))
           / (prev_qty + new.qty_delta)
    end;
  else
    new_cost := prev_cost;
  end if;

  insert into inventory.stock_balances as b
    (org_id, variant_id, location_id, qty_on_hand, moving_avg_cost_paise, last_movement_id, updated_at)
  values (new.org_id, new.variant_id, new.location_id, new.qty_delta, new_cost, new.id, now())
  on conflict (org_id, variant_id, location_id) do update
    set qty_on_hand = b.qty_on_hand + excluded.qty_on_hand,
        moving_avg_cost_paise = coalesce(excluded.moving_avg_cost_paise, b.moving_avg_cost_paise),
        last_movement_id = excluded.last_movement_id,
        updated_at = now();
  return null;
end $$;
create trigger trg_apply_movement after insert on inventory.stock_movements
  for each row execute function inventory.apply_movement();

-- THE ONLY supported way to move stock.
-- Unlike the legacy bd_deduct_stock, this takes a row lock and either posts the
-- full delta or raises. It never silently floors a deduction at zero while
-- logging a different number - the bug that made ledger and qty disagree.
create or replace function inventory.post_movement(
  p_org uuid, p_variant uuid, p_location uuid, p_delta numeric,
  p_reason text, p_ref_type text default null, p_ref_id uuid default null,
  p_unit_cost bigint default null, p_note text default null,
  p_allow_negative boolean default false
) returns bigint
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare cur numeric(18,3); res numeric(18,3); mid bigint;
begin
  if p_delta = 0 then raise exception 'qty_delta must be non-zero'; end if;

  select qty_on_hand, qty_reserved into cur, res
  from inventory.stock_balances
  where org_id = p_org and variant_id = p_variant and location_id = p_location
  for update;
  cur := coalesce(cur, 0); res := coalesce(res, 0);

  if p_delta < 0 and not p_allow_negative and (cur + p_delta) < res then
    raise exception
      'insufficient stock: on hand %, reserved %, requested %', cur, res, abs(p_delta)
      using errcode = 'check_violation';
  end if;

  insert into inventory.stock_movements
    (org_id, variant_id, location_id, qty_delta, reason, ref_type, ref_id, unit_cost_paise, created_by, note)
  values (p_org, p_variant, p_location, p_delta, p_reason, p_ref_type, p_ref_id,
          p_unit_cost, platform.current_user_id(), p_note)
  returning id into mid;

  return mid;
end $$;

-- ── reservations: how other apps hold stock without consuming it ───────────
-- A catalogue cart or a parked POS bill holds; it does not deduct.
create table inventory.reservations (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  variant_id  uuid not null references core.product_variants(id) on delete cascade,
  location_id uuid not null references inventory.locations(id)   on delete cascade,
  qty         numeric(18,3) not null check (qty > 0),
  source_app  text not null,
  source_ref  text,
  status      text not null default 'held' check (status in ('held','consumed','released','expired')),
  expires_at  timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index reservations_open_idx on inventory.reservations(org_id, variant_id, location_id)
  where status = 'held';
create index reservations_expiry_idx on inventory.reservations(expires_at) where status = 'held';

create or replace function inventory.sync_reserved() returns trigger
language plpgsql security definer
set search_path = inventory, public
as $$
declare v_org uuid; v_var uuid; v_loc uuid;
begin
  v_org := coalesce(new.org_id, old.org_id);
  v_var := coalesce(new.variant_id, old.variant_id);
  v_loc := coalesce(new.location_id, old.location_id);

  insert into inventory.stock_balances(org_id, variant_id, location_id, qty_on_hand, qty_reserved)
  values (v_org, v_var, v_loc, 0, 0)
  on conflict (org_id, variant_id, location_id) do nothing;

  update inventory.stock_balances b
     set qty_reserved = coalesce((
           select sum(r.qty) from inventory.reservations r
           where r.org_id = v_org and r.variant_id = v_var
             and r.location_id = v_loc and r.status = 'held'), 0),
         updated_at = now()
   where b.org_id = v_org and b.variant_id = v_var and b.location_id = v_loc;
  return null;
end $$;
create trigger trg_reservation_sync
  after insert or update or delete on inventory.reservations
  for each row execute function inventory.sync_reserved();

-- ── documents ──────────────────────────────────────────────────────────────
-- Transfers are two-phase and record what was ACTUALLY received. The gap
-- between dispatched and received becomes an explicit adjustment - that is
-- where real businesses lose money, and where competitors just move a number.
create table inventory.transfers (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references platform.organizations(id) on delete cascade,
  code             text not null,
  from_location_id uuid not null references inventory.locations(id),
  to_location_id   uuid not null references inventory.locations(id),
  status           text not null default 'draft'
                     check (status in ('draft','dispatched','in_transit','received','cancelled')),
  dispatched_at    timestamptz,
  received_at      timestamptz,
  notes            text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  unique (org_id, code),
  check (from_location_id <> to_location_id)
);
create table inventory.transfer_lines (
  id           uuid primary key default gen_random_uuid(),
  transfer_id  uuid not null references inventory.transfers(id) on delete cascade,
  variant_id   uuid not null references core.product_variants(id),
  qty_sent     numeric(18,3) not null check (qty_sent > 0),
  qty_received numeric(18,3)
);

create table inventory.adjustments (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  code        text not null,
  location_id uuid not null references inventory.locations(id),
  reason      text not null check (reason in
                ('damage','expiry','theft','found','physical_correction','opening_correction','transit_loss','other')),
  status      text not null default 'draft' check (status in ('draft','pending_approval','approved','cancelled')),
  note        text,
  approved_by uuid,
  approved_at timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  unique (org_id, code)
);
create table inventory.adjustment_lines (
  id            uuid primary key default gen_random_uuid(),
  adjustment_id uuid not null references inventory.adjustments(id) on delete cascade,
  variant_id    uuid not null references core.product_variants(id),
  qty_before    numeric(18,3),
  qty_delta     numeric(18,3) not null check (qty_delta <> 0),
  qty_after     numeric(18,3),
  note          text
);

create table inventory.stock_counts (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  code        text not null,
  location_id uuid not null references inventory.locations(id),
  scope       jsonb not null default '{}'::jsonb,   -- {"category_ids":[...],"brand_ids":[...]}
  status      text not null default 'draft'
                check (status in ('draft','counting','review','approved','cancelled')),
  started_at  timestamptz,
  approved_at timestamptz,
  created_by  uuid,
  unique (org_id, code)
);
create table inventory.stock_count_lines (
  id          uuid primary key default gen_random_uuid(),
  count_id    uuid not null references inventory.stock_counts(id) on delete cascade,
  variant_id  uuid not null references core.product_variants(id),
  system_qty  numeric(18,3) not null,   -- frozen at count start
  counted_qty numeric(18,3),
  unique (count_id, variant_id)
);

create table inventory.reorder_rules (
  org_id      uuid not null references platform.organizations(id) on delete cascade,
  variant_id  uuid not null references core.product_variants(id) on delete cascade,
  location_id uuid not null references inventory.locations(id)   on delete cascade,
  min_qty     numeric(18,3),
  max_qty     numeric(18,3),
  reorder_qty numeric(18,3),
  primary key (org_id, variant_id, location_id)
);

-- ▶▶▶ 20260812090500_catalogue.sql

-- ============================================================================
-- 0006 · CATALOGUE
--
-- PUBLIC READ PATH: anonymous visitors NEVER touch core/inventory tables and
-- never evaluate a tenant RLS policy. Publishing serialises the whole
-- catalogue into published_snapshots; the public site reads only snapshots,
-- behind ISR + CDN. Stock status is the single live element, served bucketed
-- ('in_stock' | 'limited' | 'out_of_stock') - never a raw number unless the
-- business opts in. This is what lets a WhatsApp forward go viral safely.
-- ============================================================================

create schema if not exists catalogue;

create table catalogue.catalogues (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  slug       text not null unique
               check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
  name       text not null,
  theme_key  text not null default 'classic'
               check (theme_key in ('classic','modern','wholesale','luxury','minimal','retail')),
  status     text not null default 'draft' check (status in ('draft','published','unpublished')),
  -- {"price_mode":"show_price","stock_display":"badge","show_sku":false,
  --  "audience":"public","seo":{...},"contact":{...}}
  settings   jsonb not null default '{}'::jsonb,
  custom_domain text unique,
  current_version int not null default 0,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index catalogues_org_idx on catalogue.catalogues(org_id);
create trigger trg_catalogues_updated before update on catalogue.catalogues
  for each row execute function platform.set_updated_at();

create table catalogue.catalogue_categories (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references platform.organizations(id) on delete cascade,
  catalogue_id uuid not null references catalogue.catalogues(id) on delete cascade,
  category_id  uuid references core.categories(id) on delete set null,
  name         text not null,
  position     int not null default 0
);

-- Overrides live here; the product itself stays in core. Catalogue owns
-- presentation only.
create table catalogue.catalogue_items (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references platform.organizations(id) on delete cascade,
  catalogue_id uuid not null references catalogue.catalogues(id) on delete cascade,
  product_id   uuid not null references core.products(id) on delete cascade,
  variant_id   uuid references core.product_variants(id) on delete cascade,
  price_mode   text not null default 'inherit'
                 check (price_mode in ('inherit','show_price','hide_price','mrp_and_selling',
                                       'contact_for_price','login_to_view')),
  override_price_paise bigint,
  override_description text,
  -- used when Inventory is NOT connected, and materialised on disconnect so a
  -- live catalogue never goes blank when an app is revoked
  manual_stock_status  text check (manual_stock_status in ('in_stock','limited','out_of_stock')),
  visibility   text not null default 'visible' check (visibility in ('visible','hidden')),
  position     int not null default 0,
  unique (catalogue_id, product_id, variant_id)
);
create index catalogue_items_cat_idx on catalogue.catalogue_items(catalogue_id, position)
  where visibility = 'visible';

-- One immutable row per publish. The public site reads nothing else.
create table catalogue.published_snapshots (
  catalogue_id uuid not null references catalogue.catalogues(id) on delete cascade,
  version      int not null,
  payload      jsonb not null,
  published_at timestamptz not null default now(),
  published_by uuid,
  primary key (catalogue_id, version)
);

create table catalogue.enquiries (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references platform.organizations(id) on delete cascade,
  catalogue_id uuid not null references catalogue.catalogues(id) on delete cascade,
  product_id   uuid references core.products(id) on delete set null,
  variant_id   uuid references core.product_variants(id) on delete set null,
  name         text,
  phone        text not null,
  message      text,
  status       text not null default 'new' check (status in ('new','contacted','closed')),
  source       text not null default 'catalogue',
  created_at   timestamptz not null default now()
);
create index enquiries_org_status_idx on catalogue.enquiries(org_id, status, created_at desc);

-- Public snapshot read. SECURITY DEFINER so anon needs no table grants at all.
create or replace function catalogue.public_snapshot(p_slug text)
returns jsonb language sql stable security definer
set search_path = catalogue, public
as $$
  select s.payload
  from catalogue.catalogues c
  join catalogue.published_snapshots s
    on s.catalogue_id = c.id and s.version = c.current_version
  where c.slug = p_slug and c.status = 'published'
$$;

-- Bucketed availability. Never leaks a quantity unless the org opts in.
create or replace function catalogue.public_stock_status(p_slug text)
returns table (variant_id uuid, status text)
language sql stable security definer
set search_path = catalogue, inventory, platform, public
as $$
  select ci.variant_id,
         case
           when not exists (
             select 1 from platform.app_connections ac
             where ac.org_id = c.org_id and ac.source_app = 'catalogue'
               and ac.target_app = 'inventory' and ac.status = 'active')
             then coalesce(ci.manual_stock_status, 'in_stock')
           when coalesce(sum(b.qty_available), 0) <= 0 then 'out_of_stock'
           when coalesce(sum(b.qty_available), 0) <= 3 then 'limited'
           else 'in_stock'
         end as status
  from catalogue.catalogues c
  join catalogue.catalogue_items ci on ci.catalogue_id = c.id and ci.visibility = 'visible'
  left join inventory.stock_balances b on b.variant_id = ci.variant_id and b.org_id = c.org_id
  where c.slug = p_slug and c.status = 'published' and ci.variant_id is not null
  group by ci.variant_id, ci.manual_stock_status, c.org_id
$$;

-- ▶▶▶ 20260812090600_integrity.sql

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

-- ▶▶▶ 20260812090700_rls.sql

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
