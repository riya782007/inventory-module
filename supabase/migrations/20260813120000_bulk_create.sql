-- ============================================================================
-- 0010 · BULK PRODUCT CREATION
-- Pattern taken from the Aggarwal build's Bulk Add Inventory, improved:
--   * every row goes through the SAME core.create_product path (each row is
--     its own product - never one product with a lumped quantity)
--   * one round trip instead of one server call per row
--   * per-row savepoints: a failed row rolls back only itself and is
--     reported with its reason; the rest of the batch still lands
-- SECURITY INVOKER: RLS applies to every row, same as single create.
-- ============================================================================
create or replace function core.create_products_bulk(p jsonb)
returns jsonb
language plpgsql security invoker
set search_path = core, inventory, platform, public
as $$
declare
  row_j jsonb; i int := 0; ok_count int := 0;
  res jsonb := '[]'::jsonb; pid uuid; v_sku text;
begin
  if platform.current_org_id() is null then
    raise exception 'no active organization';
  end if;
  for row_j in select * from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) loop
    begin
      pid := core.create_product(row_j);
      select sku into v_sku from core.product_variants
      where product_id = pid and is_default limit 1;
      res := res || jsonb_build_object('row', i, 'ok', true,
               'product_id', pid, 'sku', v_sku, 'name', row_j->>'name');
      ok_count := ok_count + 1;
    exception when others then
      -- implicit savepoint: only this row's work is rolled back
      res := res || jsonb_build_object('row', i, 'ok', false,
               'name', row_j->>'name', 'error', SQLERRM);
    end;
    i := i + 1;
  end loop;
  return jsonb_build_object('created', ok_count, 'total', i, 'results', res);
end $$;
grant execute on function core.create_products_bulk(jsonb) to authenticated;

-- ── fix: manual + name-based SKUs for SIMPLE products ────────────────────────
-- The variant path already honours a typed SKU and auto-generates readable
-- ones; the simple path kept the trigger's opaque SKU-<hex>. Now: a typed SKU
-- wins (uppercased, de-clashed with -2/-3…), otherwise NAME-XXXX.
create or replace function core.assign_sku(p_org uuid, p_variant uuid, p_manual text, p_name text)
returns text language plpgsql security invoker
set search_path = core, public
as $$
declare v_sku text; v_base text; v_n int := 2;
begin
  v_base := upper(regexp_replace(coalesce(nullif(trim(p_manual), ''), ''), '\s+', '-', 'g'));
  if v_base = '' then
    v_base := upper(left(regexp_replace(p_name, '[^A-Za-z0-9]', '', 'g'), 3))
              || '-' || upper(substr(md5(p_variant::text), 1, 4));
  end if;
  v_sku := v_base;
  while exists (select 1 from core.product_variants
                where org_id = p_org and sku = v_sku and id <> p_variant) loop
    v_sku := v_base || '-' || v_n; v_n := v_n + 1;
  end loop;
  update core.product_variants set sku = v_sku where id = p_variant;
  return v_sku;
end $$;
grant execute on function core.assign_sku(uuid, uuid, text, text) to authenticated;

-- Wrap create_product: run the original then normalise the simple-product SKU.
-- (The variant path is untouched - it already handles SKUs correctly.)
create or replace function core.create_product_v2(p jsonb)
returns uuid language plpgsql security invoker
set search_path = core, inventory, platform, public
as $$
declare v_product uuid; v_variant uuid;
begin
  v_product := core.create_product(p);
  if not coalesce((p->>'has_variants')::boolean, false) then
    select id into v_variant from core.product_variants
    where product_id = v_product and is_default limit 1;
    perform core.assign_sku(platform.current_org_id(), v_variant,
                            p->>'sku', p->>'name');
  end if;
  return v_product;
end $$;
grant execute on function core.create_product_v2(jsonb) to authenticated;

-- Bulk goes through v2 so typed SKUs land.
create or replace function core.create_products_bulk(p jsonb)
returns jsonb
language plpgsql security invoker
set search_path = core, inventory, platform, public
as $$
declare
  row_j jsonb; i int := 0; ok_count int := 0;
  res jsonb := '[]'::jsonb; pid uuid; v_sku text;
begin
  if platform.current_org_id() is null then
    raise exception 'no active organization';
  end if;
  for row_j in select * from jsonb_array_elements(coalesce(p->'rows', '[]'::jsonb)) loop
    begin
      pid := core.create_product_v2(row_j);
      select sku into v_sku from core.product_variants
      where product_id = pid and is_default limit 1;
      res := res || jsonb_build_object('row', i, 'ok', true,
               'product_id', pid, 'sku', v_sku, 'name', row_j->>'name');
      ok_count := ok_count + 1;
    exception when others then
      res := res || jsonb_build_object('row', i, 'ok', false,
               'name', row_j->>'name', 'error', SQLERRM);
    end;
    i := i + 1;
  end loop;
  return jsonb_build_object('created', ok_count, 'total', i, 'results', res);
end $$;
