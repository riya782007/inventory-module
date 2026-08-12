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
