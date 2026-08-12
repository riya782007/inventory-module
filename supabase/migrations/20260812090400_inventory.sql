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
