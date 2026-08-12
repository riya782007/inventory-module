-- ============================================================================
-- 0011 · TRANSFERS, STOCK COUNTS, REORDER RULES (server logic)
--
-- Refactor: the lock-and-insert core moves into inventory._post, which is
-- NOT callable by clients. post_movement keeps its permission surface and
-- delegates. Transfer/count RPCs do their own permission checks (a user with
-- inventory.transfer may lack inventory.remove) and then call _post.
-- ============================================================================

-- ── internal poster: the only writer of movements. No client grant. ─────────
create or replace function inventory._post(
  p_org uuid, p_variant uuid, p_location uuid, p_delta numeric,
  p_reason text, p_ref_type text, p_ref_id uuid,
  p_unit_cost bigint, p_note text, p_allow_negative boolean
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
    raise exception 'insufficient stock: on hand %, reserved %, requested %',
      cur, res, abs(p_delta) using errcode = 'check_violation';
  end if;
  insert into inventory.stock_movements
    (org_id, variant_id, location_id, qty_delta, reason, ref_type, ref_id,
     unit_cost_paise, created_by, note)
  values (p_org, p_variant, p_location, p_delta, p_reason, p_ref_type, p_ref_id,
          p_unit_cost, platform.current_user_id(), p_note)
  returning id into mid;
  return mid;
end $$;
revoke execute on function inventory._post(uuid,uuid,uuid,numeric,text,text,uuid,bigint,text,boolean)
  from public, anon, authenticated;

-- post_movement: same client surface as 0009, now delegating to _post.
create or replace function inventory.post_movement(
  p_org uuid, p_variant uuid, p_location uuid, p_delta numeric,
  p_reason text, p_ref_type text default null, p_ref_id uuid default null,
  p_unit_cost bigint default null, p_note text default null,
  p_allow_negative boolean default false
) returns bigint
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare jwt_org uuid;
begin
  jwt_org := platform.current_org_id();
  if jwt_org is not null then
    if p_org is distinct from jwt_org then
      raise exception 'org mismatch' using errcode = 'insufficient_privilege'; end if;
    if not platform.has_entitlement('inventory') then
      raise exception 'inventory app not active' using errcode = 'insufficient_privilege'; end if;
    if p_delta > 0 and not platform.has_perm('inventory.add') then
      raise exception 'missing permission inventory.add' using errcode = 'insufficient_privilege'; end if;
    if p_delta < 0 and not platform.has_perm('inventory.remove') then
      raise exception 'missing permission inventory.remove' using errcode = 'insufficient_privilege'; end if;
    if not platform.can_access_location(p_location) then
      raise exception 'location not accessible' using errcode = 'insufficient_privilege'; end if;
  end if;
  return inventory._post(p_org, p_variant, p_location, p_delta, p_reason,
                         p_ref_type, p_ref_id, p_unit_cost, p_note, p_allow_negative);
end $$;

create or replace function inventory._guard(p_perm text) returns uuid
language plpgsql stable security definer
set search_path = platform, public
as $$
declare v_org uuid := platform.current_org_id();
begin
  if v_org is null then raise exception 'no active organization'; end if;
  if not platform.has_entitlement('inventory') then
    raise exception 'inventory app not active' using errcode = 'insufficient_privilege'; end if;
  if not platform.has_perm(p_perm) then
    raise exception 'missing permission %', p_perm using errcode = 'insufficient_privilege'; end if;
  return v_org;
end $$;

-- ── transfers ───────────────────────────────────────────────────────────────
create or replace function inventory.create_transfer(
  p_from uuid, p_to uuid, p_lines jsonb, p_notes text default null
) returns uuid
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare v_org uuid; v_id uuid; l jsonb;
begin
  v_org := inventory._guard('inventory.transfer');
  if p_from = p_to then raise exception 'source and destination are the same'; end if;
  if not platform.can_access_location(p_from) then
    raise exception 'source location not accessible'; end if;
  if jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    raise exception 'add at least one line'; end if;

  insert into inventory.transfers(org_id, code, from_location_id, to_location_id,
                                  status, notes, created_by)
  values (v_org, 'TR-' || upper(substr(md5(random()::text), 1, 6)),
          p_from, p_to, 'draft', p_notes, platform.current_user_id())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    insert into inventory.transfer_lines(transfer_id, variant_id, qty_sent)
    values (v_id, (l->>'variant_id')::uuid, (l->>'qty')::numeric);
  end loop;
  return v_id;
end $$;
grant execute on function inventory.create_transfer(uuid, uuid, jsonb, text) to authenticated;

create or replace function inventory.dispatch_transfer(p_id uuid) returns void
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare v_org uuid; t inventory.transfers; l record;
begin
  v_org := inventory._guard('inventory.transfer');
  select * into t from inventory.transfers where id = p_id and org_id = v_org for update;
  if not found then raise exception 'transfer not found'; end if;
  if t.status <> 'draft' then raise exception 'transfer is %, not draft', t.status; end if;
  if not platform.can_access_location(t.from_location_id) then
    raise exception 'source location not accessible'; end if;

  for l in select * from inventory.transfer_lines where transfer_id = p_id loop
    perform inventory._post(v_org, l.variant_id, t.from_location_id, -l.qty_sent,
      'transfer_out', 'transfer', p_id, null, null, false);
  end loop;
  update inventory.transfers set status = 'dispatched', dispatched_at = now() where id = p_id;
end $$;
grant execute on function inventory.dispatch_transfer(uuid) to authenticated;

-- Receipt records what ACTUALLY arrived; shortfall stays visible as the gap
-- between the transfer_out and transfer_in movements, and on the line itself.
create or replace function inventory.receive_transfer(p_id uuid, p_lines jsonb) returns void
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare v_org uuid; t inventory.transfers; l jsonb; v_line inventory.transfer_lines; v_qty numeric;
begin
  v_org := inventory._guard('inventory.transfer');
  select * into t from inventory.transfers where id = p_id and org_id = v_org for update;
  if not found then raise exception 'transfer not found'; end if;
  if t.status not in ('dispatched','in_transit') then
    raise exception 'transfer is %, not dispatched', t.status; end if;
  if not platform.can_access_location(t.to_location_id) then
    raise exception 'destination location not accessible'; end if;

  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select * into v_line from inventory.transfer_lines
    where id = (l->>'line_id')::uuid and transfer_id = p_id;
    if not found then raise exception 'line not found'; end if;
    v_qty := coalesce((l->>'qty_received')::numeric, v_line.qty_sent);
    if v_qty < 0 or v_qty > v_line.qty_sent then
      raise exception 'received qty must be between 0 and %', v_line.qty_sent; end if;
    update inventory.transfer_lines set qty_received = v_qty where id = v_line.id;
    if v_qty > 0 then
      perform inventory._post(v_org, v_line.variant_id, t.to_location_id, v_qty,
        'transfer_in', 'transfer', p_id, null,
        case when v_qty < v_line.qty_sent
             then 'short-received ' || (v_line.qty_sent - v_qty) || ' in transit' end,
        false);
    end if;
  end loop;
  update inventory.transfers set status = 'received', received_at = now() where id = p_id;
end $$;
grant execute on function inventory.receive_transfer(uuid, jsonb) to authenticated;

create or replace function inventory.cancel_transfer(p_id uuid) returns void
language plpgsql security definer
set search_path = inventory, platform, public
as $$
declare v_org uuid; t inventory.transfers;
begin
  v_org := inventory._guard('inventory.transfer');
  select * into t from inventory.transfers where id = p_id and org_id = v_org for update;
  if not found then raise exception 'transfer not found'; end if;
  if t.status <> 'draft' then
    raise exception 'only a draft can be cancelled (this one is %)', t.status; end if;
  update inventory.transfers set status = 'cancelled' where id = p_id;
end $$;
grant execute on function inventory.cancel_transfer(uuid) to authenticated;

-- ── physical stock count ────────────────────────────────────────────────────
-- Freeze system qty at start; count; approve writes ONE correction per
-- variance through the ledger. Includes every active variant, even those
-- with no balance row yet (system 0).
create or replace function inventory.start_count(p_location uuid) returns uuid
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare v_org uuid; v_id uuid;
begin
  v_org := inventory._guard('inventory.count');
  if not platform.can_access_location(p_location) then
    raise exception 'location not accessible'; end if;
  insert into inventory.stock_counts(org_id, code, location_id, status, started_at, created_by)
  values (v_org, 'CNT-' || upper(substr(md5(random()::text), 1, 6)),
          p_location, 'counting', now(), platform.current_user_id())
  returning id into v_id;

  insert into inventory.stock_count_lines(count_id, variant_id, system_qty)
  select v_id, v.id, coalesce(b.qty_on_hand, 0)
  from core.product_variants v
  join core.products p on p.id = v.product_id and p.status = 'active'
  left join inventory.stock_balances b
    on b.variant_id = v.id and b.location_id = p_location and b.org_id = v_org
  where v.org_id = v_org and v.status = 'active';
  return v_id;
end $$;
grant execute on function inventory.start_count(uuid) to authenticated;

create or replace function inventory.save_count_line(p_count uuid, p_variant uuid, p_qty numeric)
returns void
language plpgsql security definer
set search_path = inventory, platform, public
as $$
declare v_org uuid;
begin
  v_org := inventory._guard('inventory.count');
  update inventory.stock_count_lines l set counted_qty = p_qty
  from inventory.stock_counts c
  where l.count_id = p_count and l.variant_id = p_variant
    and c.id = p_count and c.org_id = v_org and c.status = 'counting';
  if not found then raise exception 'count line not found or count not open'; end if;
end $$;
grant execute on function inventory.save_count_line(uuid, uuid, numeric) to authenticated;

create or replace function inventory.approve_count(p_id uuid) returns int
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare v_org uuid; c inventory.stock_counts; l record; n int := 0;
begin
  v_org := inventory._guard('inventory.approve');
  select * into c from inventory.stock_counts where id = p_id and org_id = v_org for update;
  if not found then raise exception 'count not found'; end if;
  if c.status <> 'counting' then raise exception 'count is %, not counting', c.status; end if;

  for l in select * from inventory.stock_count_lines
           where count_id = p_id and counted_qty is not null
             and counted_qty <> system_qty loop
    perform inventory._post(v_org, l.variant_id, c.location_id,
      l.counted_qty - l.system_qty, 'count_correction', 'stock_count', p_id,
      null, 'Physical count', true);
    n := n + 1;
  end loop;
  update inventory.stock_counts set status = 'approved', approved_at = now() where id = p_id;
  return n;
end $$;
grant execute on function inventory.approve_count(uuid) to authenticated;

-- ── reorder levels ──────────────────────────────────────────────────────────
create or replace function inventory.set_reorder_level(
  p_variant uuid, p_location uuid, p_min numeric
) returns void
language plpgsql security definer
set search_path = inventory, platform, public
as $$
declare v_org uuid;
begin
  v_org := inventory._guard('inventory.view');
  if p_min is null or p_min <= 0 then
    delete from inventory.reorder_rules
    where org_id = v_org and variant_id = p_variant and location_id = p_location;
  else
    insert into inventory.reorder_rules(org_id, variant_id, location_id, min_qty)
    values (v_org, p_variant, p_location, p_min)
    on conflict (org_id, variant_id, location_id) do update set min_qty = excluded.min_qty;
  end if;
end $$;
grant execute on function inventory.set_reorder_level(uuid, uuid, numeric) to authenticated;
