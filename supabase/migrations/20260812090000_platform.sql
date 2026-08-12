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
