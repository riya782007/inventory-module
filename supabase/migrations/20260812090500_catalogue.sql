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
