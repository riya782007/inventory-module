-- ============================================================================
-- 0012 · SUPPLIERS + PURCHASE ORDERS
-- The standard procure-to-stock loop: PO draft -> ordered -> receive (partial
-- allowed) -> stock and moving-average cost update through the ledger.
-- Receiving is the ONLY path that adds purchased stock; unit cost flows into
-- the moving average via inventory._post.
-- ============================================================================

-- ── permissions for the new domain ──────────────────────────────────────────
insert into platform.permissions(key, app_key, label, description, is_sensitive) values
  ('purchases.view',    'inventory', 'View purchase orders',    null, false),
  ('purchases.create',  'inventory', 'Create purchase orders',  null, false),
  ('purchases.receive', 'inventory', 'Receive purchase orders', 'adds stock at cost', false),
  ('suppliers.manage',  'inventory', 'Manage suppliers',        null, false)
on conflict (key) do nothing;

insert into platform.role_permissions(role_id, permission_key)
select r.id, k
from platform.roles r
cross join unnest(array['purchases.view','purchases.create','purchases.receive','suppliers.manage']) as k
where r.org_id is null and r.key in ('owner','admin','manager','inventory_manager')
on conflict do nothing;

-- ── suppliers (core.parties: shared later with CRM/customers) ───────────────
create table if not exists core.parties (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references platform.organizations(id) on delete cascade,
  kind       text not null default 'supplier' check (kind in ('supplier','customer','both')),
  name       text not null,
  phone      text,
  email      text,
  gstin      text,
  city       text,
  address    text,
  notes      text,
  status     text not null default 'active' check (status in ('active','archived')),
  created_at timestamptz not null default now(),
  unique (org_id, name)
);
alter table core.parties enable row level security;
alter table core.parties force row level security;
create policy parties_read on core.parties for select
  using (org_id = platform.current_org_id() and platform.is_member());
create policy parties_write on core.parties for all
  using      (org_id = platform.current_org_id() and platform.has_perm('suppliers.manage'))
  with check (org_id = platform.current_org_id() and platform.has_perm('suppliers.manage'));
grant select, insert, update, delete on core.parties to authenticated;

-- ── purchase orders ─────────────────────────────────────────────────────────
create table if not exists inventory.purchase_orders (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references platform.organizations(id) on delete cascade,
  code         text not null,
  supplier_id  uuid not null references core.parties(id),
  location_id  uuid not null references inventory.locations(id),
  status       text not null default 'draft'
                 check (status in ('draft','ordered','partial','received','cancelled')),
  expected_at  date,
  notes        text,
  ordered_at   timestamptz,
  received_at  timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  unique (org_id, code)
);
create table if not exists inventory.purchase_order_lines (
  id              uuid primary key default gen_random_uuid(),
  po_id           uuid not null references inventory.purchase_orders(id) on delete cascade,
  variant_id      uuid not null references core.product_variants(id),
  qty_ordered     numeric(18,3) not null check (qty_ordered > 0),
  qty_received    numeric(18,3) not null default 0 check (qty_received >= 0),
  unit_cost_paise bigint
);
create index if not exists po_org_status_idx on inventory.purchase_orders(org_id, status, created_at desc);

alter table inventory.purchase_orders enable row level security;
alter table inventory.purchase_orders force row level security;
alter table inventory.purchase_order_lines enable row level security;
alter table inventory.purchase_order_lines force row level security;
-- Reads via RLS; ALL writes go through the definer RPCs below.
create policy po_read on inventory.purchase_orders for select
  using (org_id = platform.current_org_id()
         and platform.has_entitlement('inventory')
         and platform.has_perm('purchases.view'));
create policy po_lines_read on inventory.purchase_order_lines for select
  using (exists (select 1 from inventory.purchase_orders h
                 where h.id = po_id and h.org_id = platform.current_org_id()));
grant select on inventory.purchase_orders, inventory.purchase_order_lines to authenticated;

-- ── RPCs ────────────────────────────────────────────────────────────────────
create or replace function inventory.create_po(
  p_supplier uuid, p_location uuid, p_lines jsonb,
  p_expected date default null, p_notes text default null
) returns uuid
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare v_org uuid; v_id uuid; l jsonb;
begin
  v_org := inventory._guard('purchases.create');
  if not exists (select 1 from core.parties
                 where id = p_supplier and org_id = v_org and kind in ('supplier','both')) then
    raise exception 'supplier not found'; end if;
  if not platform.can_access_location(p_location) then
    raise exception 'location not accessible'; end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    raise exception 'add at least one line'; end if;

  insert into inventory.purchase_orders(org_id, code, supplier_id, location_id,
                                        status, expected_at, notes, created_by)
  values (v_org, 'PO-' || upper(substr(md5(random()::text), 1, 6)),
          p_supplier, p_location, 'draft', p_expected, p_notes,
          platform.current_user_id())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    insert into inventory.purchase_order_lines(po_id, variant_id, qty_ordered, unit_cost_paise)
    values (v_id, (l->>'variant_id')::uuid, (l->>'qty')::numeric,
            nullif(l->>'unit_cost_paise','')::bigint);
  end loop;
  return v_id;
end $$;
grant execute on function inventory.create_po(uuid, uuid, jsonb, date, text) to authenticated;

create or replace function inventory.order_po(p_id uuid) returns void
language plpgsql security definer
set search_path = inventory, platform, public
as $$
declare v_org uuid; po inventory.purchase_orders;
begin
  v_org := inventory._guard('purchases.create');
  select * into po from inventory.purchase_orders where id = p_id and org_id = v_org for update;
  if not found then raise exception 'purchase order not found'; end if;
  if po.status <> 'draft' then raise exception 'PO is %, not draft', po.status; end if;
  update inventory.purchase_orders set status = 'ordered', ordered_at = now() where id = p_id;
end $$;
grant execute on function inventory.order_po(uuid) to authenticated;

-- Partial receipts are normal life. Each call receives some quantities;
-- stock + moving-average cost update through the ledger; the PO flips to
-- 'partial' until every line is fully received.
create or replace function inventory.receive_po(p_id uuid, p_lines jsonb) returns void
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare v_org uuid; po inventory.purchase_orders; l jsonb;
        v_line inventory.purchase_order_lines; v_qty numeric; v_cost bigint;
        v_all boolean;
begin
  v_org := inventory._guard('purchases.receive');
  select * into po from inventory.purchase_orders where id = p_id and org_id = v_org for update;
  if not found then raise exception 'purchase order not found'; end if;
  if po.status not in ('ordered','partial') then
    raise exception 'PO is %, not ordered', po.status; end if;
  if not platform.can_access_location(po.location_id) then
    raise exception 'location not accessible'; end if;

  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select * into v_line from inventory.purchase_order_lines
    where id = (l->>'line_id')::uuid and po_id = p_id for update;
    if not found then raise exception 'line not found'; end if;
    v_qty := coalesce((l->>'qty')::numeric, 0);
    if v_qty <= 0 then continue; end if;
    if v_line.qty_received + v_qty > v_line.qty_ordered then
      raise exception 'line over-receipt: ordered %, already received %, receiving %',
        v_line.qty_ordered, v_line.qty_received, v_qty; end if;
    v_cost := coalesce(nullif(l->>'unit_cost_paise','')::bigint, v_line.unit_cost_paise);

    update inventory.purchase_order_lines
      set qty_received = qty_received + v_qty,
          unit_cost_paise = coalesce(v_cost, unit_cost_paise)
      where id = v_line.id;

    perform inventory._post(v_org, v_line.variant_id, po.location_id, v_qty,
      'purchase', 'purchase_order', p_id, v_cost, null, false);
  end loop;

  select bool_and(qty_received >= qty_ordered) into v_all
  from inventory.purchase_order_lines where po_id = p_id;
  update inventory.purchase_orders
    set status = case when v_all then 'received' else 'partial' end,
        received_at = case when v_all then now() else received_at end
    where id = p_id;
end $$;
grant execute on function inventory.receive_po(uuid, jsonb) to authenticated;

create or replace function inventory.cancel_po(p_id uuid) returns void
language plpgsql security definer
set search_path = inventory, platform, public
as $$
declare v_org uuid; po inventory.purchase_orders;
begin
  v_org := inventory._guard('purchases.create');
  select * into po from inventory.purchase_orders where id = p_id and org_id = v_org for update;
  if not found then raise exception 'purchase order not found'; end if;
  if po.status not in ('draft','ordered') then
    raise exception 'a % PO cannot be cancelled', po.status; end if;
  if exists (select 1 from inventory.purchase_order_lines
             where po_id = p_id and qty_received > 0) then
    raise exception 'stock was already received against this PO'; end if;
  update inventory.purchase_orders set status = 'cancelled' where id = p_id;
end $$;
grant execute on function inventory.cancel_po(uuid) to authenticated;

-- Last purchase price per variant+supplier (the legacy build's
-- "last-purchase-price memory" - it pre-fills the next PO line).
create or replace function inventory.last_purchase_costs(p_supplier uuid)
returns table (variant_id uuid, unit_cost_paise bigint)
language sql stable security definer
set search_path = inventory, platform, public
as $$
  select distinct on (l.variant_id) l.variant_id, l.unit_cost_paise
  from inventory.purchase_order_lines l
  join inventory.purchase_orders po on po.id = l.po_id
  where po.org_id = platform.current_org_id()
    and po.supplier_id = p_supplier
    and l.unit_cost_paise is not null
  order by l.variant_id, po.created_at desc
$$;
grant execute on function inventory.last_purchase_costs(uuid) to authenticated;
