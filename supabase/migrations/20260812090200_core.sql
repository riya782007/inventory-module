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
