-- ============================================================================
-- 0009 · ONBOARDING + API ACCESS
-- Run AFTER setup_all.sql. Three jobs:
--   1. API grants: authenticated gets table DML (RLS still decides every row).
--   2. Harden inventory.post_movement for direct calls from the browser.
--   3. RPCs: create_organization (signup) and create_product (transactional).
-- ============================================================================

-- ── 1 · grants ─────────────────────────────────────────────────────────────
-- 0008 granted schema USAGE only. Real clients also need table privileges;
-- RLS remains the row gate on every one of these tables.
grant select, insert, update, delete on all tables in schema platform  to authenticated;
grant select, insert, update, delete on all tables in schema core      to authenticated;
grant select, insert, update, delete on all tables in schema inventory to authenticated;
grant select, insert, update, delete on all tables in schema catalogue to authenticated;
grant usage, select on all sequences in schema platform, core, inventory, catalogue to authenticated;
grant execute on all functions in schema platform, core, inventory, catalogue to authenticated;
alter default privileges in schema platform, core, inventory, catalogue
  grant select, insert, update, delete on tables to authenticated;

-- ── 2 · harden post_movement ───────────────────────────────────────────────
-- It is SECURITY DEFINER and takes p_org as a parameter, so a browser caller
-- could otherwise pass another org's id. Rule: when a JWT is present, the org
-- must match it and the caller must hold the direction-appropriate permission.
-- Server-side (service role, no JWT) callers remain trusted.
create or replace function inventory.post_movement(
  p_org uuid, p_variant uuid, p_location uuid, p_delta numeric,
  p_reason text, p_ref_type text default null, p_ref_id uuid default null,
  p_unit_cost bigint default null, p_note text default null,
  p_allow_negative boolean default false
) returns bigint
language plpgsql security definer
set search_path = inventory, core, platform, public
as $$
declare cur numeric(18,3); res numeric(18,3); mid bigint; jwt_org uuid;
begin
  if p_delta = 0 then raise exception 'qty_delta must be non-zero'; end if;

  jwt_org := platform.current_org_id();
  if jwt_org is not null then
    if p_org is distinct from jwt_org then
      raise exception 'org mismatch' using errcode = 'insufficient_privilege';
    end if;
    if not platform.has_entitlement('inventory') then
      raise exception 'inventory app not active' using errcode = 'insufficient_privilege';
    end if;
    if p_delta > 0 and not platform.has_perm('inventory.add') then
      raise exception 'missing permission inventory.add' using errcode = 'insufficient_privilege';
    end if;
    if p_delta < 0 and not platform.has_perm('inventory.remove') then
      raise exception 'missing permission inventory.remove' using errcode = 'insufficient_privilege';
    end if;
    if not platform.can_access_location(p_location) then
      raise exception 'location not accessible' using errcode = 'insufficient_privilege';
    end if;
  end if;

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

-- ── 3a · create_organization: everything a new business needs, atomically ──
create or replace function platform.create_organization(p_name text, p_slug text)
returns jsonb
language plpgsql security definer
set search_path = platform, core, inventory, public
as $$
declare v_user uuid; v_org uuid; v_owner_role uuid;
begin
  v_user := (select auth.uid());
  if v_user is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from platform.org_members where user_id = v_user) then
    raise exception 'user already belongs to an organization';
  end if;
  if p_slug !~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$' then
    raise exception 'slug must be lowercase letters, digits and hyphens (3-50 chars)';
  end if;
  if exists (select 1 from platform.organizations where slug = p_slug) then
    raise exception 'that link name is taken, try another';
  end if;

  insert into platform.organizations(name, slug) values (trim(p_name), p_slug)
  returning id into v_org;

  select id into v_owner_role from platform.roles where org_id is null and key = 'owner';
  insert into platform.org_members(org_id, user_id, role_id, status)
  values (v_org, v_user, v_owner_role, 'active');

  -- 14-day trial of both launch apps
  insert into platform.app_entitlements(org_id, app_key, status, trial_ends_at)
  values (v_org, 'inventory', 'trialing', now() + interval '14 days'),
         (v_org, 'catalogue', 'trialing', now() + interval '14 days');

  insert into inventory.locations(org_id, name, type, is_default)
  values (v_org, 'Main Shop', 'shop', true);

  -- Indian GST slabs, ready to pick on any product
  insert into core.tax_rates(org_id, name, rate_bp, mode, is_default) values
    (v_org, 'Non-GST',  0,    'none',      false),
    (v_org, 'GST 3%',   300,  'exclusive', false),
    (v_org, 'GST 5%',   500,  'exclusive', false),
    (v_org, 'GST 12%',  1200, 'exclusive', false),
    (v_org, 'GST 18%',  1800, 'exclusive', true),
    (v_org, 'GST 28%',  2800, 'exclusive', false);

  insert into core.pricing_formulas(org_id, key, name, mode,
    wholesale_markup_bp, retail_multiplier, mrp_multiplier,
    retail_rounding, mrp_rounding, is_default)
  values (v_org, 'default', 'Default pricing', 'multiplier',
          0, 1.5, 2.0, 'nearest', 'multiple_5', true);

  return jsonb_build_object('org_id', v_org, 'slug', p_slug);
end $$;
grant execute on function platform.create_organization(text, text) to authenticated;

-- Which org does this user belong to? (V1: exactly one.)
create or replace function platform.my_org()
returns jsonb language sql stable security definer
set search_path = platform, public
as $$
  select jsonb_build_object('org_id', m.org_id, 'name', o.name, 'slug', o.slug, 'role', r.key)
  from platform.org_members m
  join platform.organizations o on o.id = m.org_id
  join platform.roles r on r.id = m.role_id
  where m.user_id = (select auth.uid()) and m.status = 'active'
  limit 1
$$;
grant execute on function platform.my_org() to authenticated;

-- ── 3b · create_product: product + options + variants + opening stock ──────
-- SECURITY INVOKER on purpose: every insert passes through RLS, so the
-- caller's products.create / products.variants / inventory.add permissions
-- are enforced by the database, not by this function's goodwill.
create or replace function core.create_product(p jsonb)
returns uuid
language plpgsql security invoker
set search_path = core, inventory, platform, public
as $$
declare
  v_org uuid := platform.current_org_id();
  v_product uuid; v_brand uuid; v_cat uuid; v_loc uuid;
  v_opt uuid; v_variant uuid; v_sku text; v_base text; v_n int;
  opt jsonb; val text; var jsonb; v_has_variants boolean;
begin
  if v_org is null then raise exception 'no active organization'; end if;
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'name required'; end if;

  if coalesce(trim(p->>'brand'), '') <> '' then
    insert into core.brands(org_id, name) values (v_org, trim(p->>'brand'))
    on conflict (org_id, name) do update set name = excluded.name
    returning id into v_brand;
  end if;
  if coalesce(trim(p->>'category'), '') <> '' then
    insert into core.categories(org_id, name, slug)
    values (v_org, trim(p->>'category'),
            regexp_replace(lower(trim(p->>'category')), '[^a-z0-9]+', '-', 'g'))
    on conflict (org_id, slug) do update set name = excluded.name
    returning id into v_cat;
  end if;

  v_has_variants := coalesce((p->>'has_variants')::boolean, false)
                    and jsonb_array_length(coalesce(p->'variants', '[]'::jsonb)) > 0;

  -- has_variants=true suppresses the auto-default-variant trigger;
  -- we insert the real variants ourselves below.
  insert into core.products(org_id, name, description, category_id, brand_id,
                            hsn_sac, has_variants, status)
  values (v_org, trim(p->>'name'), nullif(trim(coalesce(p->>'description','')), ''),
          v_cat, v_brand, nullif(trim(coalesce(p->>'hsn_sac','')), ''),
          v_has_variants, 'active')
  returning id into v_product;

  for opt in select * from jsonb_array_elements(coalesce(p->'options', '[]'::jsonb)) loop
    insert into core.product_options(org_id, product_id, name)
    values (v_org, v_product, opt->>'name') returning id into v_opt;
    for val in select jsonb_array_elements_text(coalesce(opt->'values', '[]'::jsonb)) loop
      insert into core.product_option_values(option_id, value) values (v_opt, val);
    end loop;
  end loop;

  select id into v_loc from inventory.locations
  where org_id = v_org and is_default limit 1;

  if v_has_variants then
    for var in select * from jsonb_array_elements(p->'variants') loop
      -- auto-SKU: NAME-ATTR-ATTR, uppercased 3-char parts, suffixed on clash
      v_base := upper(left(regexp_replace(p->>'name', '[^A-Za-z0-9]', '', 'g'), 3));
      select v_base || '-' || string_agg(upper(left(regexp_replace(x.v, '[^A-Za-z0-9]', '', 'g'), 3)), '-')
        into v_sku
      from (select value as v from jsonb_each_text(coalesce(var->'attributes', '{}'::jsonb))) x;
      v_sku := coalesce(nullif(trim(coalesce(var->>'sku','')), ''), coalesce(v_sku, v_base));
      v_n := 2;
      while exists (select 1 from core.product_variants where org_id = v_org and sku = v_sku) loop
        v_sku := v_sku || '-' || v_n; v_n := v_n + 1;
      end loop;

      insert into core.product_variants(org_id, product_id, sku, attributes, is_default,
        base_cost_paise, selling_price_paise, mrp_paise)
      values (v_org, v_product, v_sku, coalesce(var->'attributes', '{}'::jsonb),
              (var->>'is_default')::boolean is true,
              nullif(var->>'base_cost_paise','')::bigint,
              nullif(var->>'selling_price_paise','')::bigint,
              nullif(var->>'mrp_paise','')::bigint)
      returning id into v_variant;

      if coalesce((var->>'opening_qty')::numeric, 0) > 0 and v_loc is not null then
        perform inventory.post_movement(v_org, v_variant, v_loc,
          (var->>'opening_qty')::numeric, 'opening', 'product', v_product,
          nullif(var->>'base_cost_paise','')::bigint, 'Opening stock');
      end if;
    end loop;
    -- exactly one default variant
    if not exists (select 1 from core.product_variants where product_id = v_product and is_default) then
      update core.product_variants set is_default = true
      where id = (select id from core.product_variants where product_id = v_product
                  order by created_at limit 1);
    end if;
  else
    -- simple product: the trigger created the default variant; price + stock it
    select id into v_variant from core.product_variants
    where product_id = v_product and is_default;
    update core.product_variants set
      base_cost_paise     = nullif(p->>'base_cost_paise','')::bigint,
      selling_price_paise = nullif(p->>'selling_price_paise','')::bigint,
      mrp_paise           = nullif(p->>'mrp_paise','')::bigint
    where id = v_variant;
    if coalesce((p->>'opening_qty')::numeric, 0) > 0 and v_loc is not null then
      perform inventory.post_movement(v_org, v_variant, v_loc,
        (p->>'opening_qty')::numeric, 'opening', 'product', v_product,
        nullif(p->>'base_cost_paise','')::bigint, 'Opening stock');
    end if;
  end if;

  return v_product;
end $$;
grant execute on function core.create_product(jsonb) to authenticated;
