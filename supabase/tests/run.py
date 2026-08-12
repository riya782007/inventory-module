#!/usr/bin/env python3
"""Boot a throwaway Postgres, apply every migration, assert the invariants.

Run:  python3 supabase/tests/run.py
Exit code is non-zero if any invariant is violated, so it can gate CI.
"""
import os, pathlib, sys, tempfile, pgserver, psycopg

HERE = pathlib.Path(__file__).resolve().parent
MIG  = HERE.parent / "migrations"
# pgdata must be on local disk: a FUSE-mounted workspace cannot host a cluster.
PGDATA = os.environ.get("NEWVORA_PGDATA", os.path.join(tempfile.gettempdir(), "newvora-pgdata"))

srv = pgserver.get_server(PGDATA)

# Always start from a genuinely empty database so a re-run can never pass on
# stale state.
with psycopg.connect(srv.get_uri(), autocommit=True) as boot:
    with boot.cursor() as c:
        c.execute("drop database if exists newvora_test with (force)")
        c.execute("create database newvora_test")
URI  = srv.get_uri(database="newvora_test")
conn = psycopg.connect(URI, autocommit=True)

fails, checks = [], 0

def run(sql, label=""):
    try:
        with conn.cursor() as c: c.execute(sql)
    except Exception as e:
        print(f"  ✗ {label}\n    {str(e)[:900]}"); sys.exit(1)

def q(sql):
    with conn.cursor() as c:
        c.execute(sql); r = c.fetchone()
        return "" if r is None else ("" if r[0] is None else r[0])

def check(name, got, want):
    global checks; checks += 1
    ok = str(got).strip() == str(want).strip()
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"   got={got!r} want={want!r}"))
    if not ok: fails.append(name)

def expect_error(sql, name, fragment):
    global checks; checks += 1
    try:
        with conn.cursor() as c: c.execute(sql)
        print(f"  FAIL  {name}   (no error raised)"); fails.append(name)
    except Exception as e:
        ok = fragment.lower() in str(e).lower()
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"   error!={fragment!r}: {str(e)[:200]}"))
        if not ok: fails.append(name)

def as_user(uid, org, sql, expect_fail=False):
    """Run SQL as a non-superuser with a forged-or-real JWT context."""
    with psycopg.connect(URI) as c2:
        with c2.cursor() as c:
            c.execute("set role app_user")
            c.execute("select set_config('request.jwt.claims', %s, true)",
                      ['{"sub":"%s","app_metadata":{"org_id":"%s"}}' % (uid, org)])
            c.execute(sql)
            if expect_fail: return None
            r = c.fetchone()
            return "" if r is None or r[0] is None else r[0]

print("\n=== applying migrations ===")
run(open(HERE / "00_local_shim.sql").read(), "shim")
for f in sorted(MIG.glob("*.sql")):
    run(open(f).read(), f.name); print(f"  ok  {f.name}")

print("\n=== schema shape ===")
check("4 schemas created",
      q("select count(*) from information_schema.schemata where schema_name in ('platform','core','inventory','catalogue')"), 4)
check("every tenant table has RLS enabled",
      q("""select count(*) from pg_tables t join pg_class c on c.relname=t.tablename
           join pg_namespace n on n.oid=c.relnamespace and n.nspname=t.schemaname
           where t.schemaname in ('platform','core','inventory','catalogue') and not c.relrowsecurity"""), 0)
check("stock ledger has no UPDATE/DELETE policy",
      q("""select count(*) from pg_policies where schemaname='inventory'
           and tablename='stock_movements' and cmd in ('UPDATE','DELETE')"""), 0)
check("6 system roles seeded", q("select count(*) from platform.roles where org_id is null"), 6)
check("staff role cannot remove stock",
      q("""select count(*) from platform.roles r join platform.role_permissions rp on rp.role_id=r.id
           where r.key='staff' and rp.permission_key='inventory.remove'"""), 0)
check("staff role cannot see cost",
      q("""select count(*) from platform.roles r join platform.role_permissions rp on rp.role_id=r.id
           where r.key='staff' and rp.permission_key='pricing.view_cost'"""), 0)

print("\n=== seed two tenants ===")
run("""
insert into platform.organizations(id,slug,name,state_code,gstin) values
  ('11111111-1111-1111-1111-111111111111','acme','Acme Traders','07','07AAIPJ3244P1ZD'),
  ('22222222-2222-2222-2222-222222222222','rival','Rival Traders','29',null);
insert into platform.app_entitlements(org_id,app_key,status) values
  ('11111111-1111-1111-1111-111111111111','inventory','active'),
  ('11111111-1111-1111-1111-111111111111','catalogue','active'),
  ('22222222-2222-2222-2222-222222222222','inventory','active');
insert into platform.org_members(org_id,user_id,role_id,status)
select '11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',id,'active'
from platform.roles where org_id is null and key='owner';
insert into platform.org_members(org_id,user_id,role_id,status)
select '22222222-2222-2222-2222-222222222222','bbbbbbbb-0000-0000-0000-000000000002',id,'active'
from platform.roles where org_id is null and key='owner';
insert into platform.org_members(org_id,user_id,role_id,status)
select '11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000003',id,'active'
from platform.roles where org_id is null and key='staff';
insert into inventory.locations(id,org_id,name,type,is_default) values
  ('aaaa0000-0000-0000-0000-00000000000a','11111111-1111-1111-1111-111111111111','Main Shop','shop',true),
  ('aaaa0000-0000-0000-0000-00000000000b','11111111-1111-1111-1111-111111111111','Warehouse','warehouse',false),
  ('bbbb0000-0000-0000-0000-00000000000a','22222222-2222-2222-2222-222222222222','Rival Shop','shop',true);
""", "seed")
print("  ok  2 orgs, entitlements, members, locations")

print("\n=== products & the mandatory default variant ===")
run("""
insert into core.products(id,org_id,name,has_variants) values
 ('dddd0000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Steel Tiffin 3-tier',false),
 ('dddd0000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Cotton Kurta',true);
insert into core.product_variants(id,org_id,product_id,sku,attributes,is_default,base_cost_paise) values
 ('eeee0000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','dddd0000-0000-0000-0000-000000000002','KURTA-M-BLK','{"Size":"M","Colour":"Black"}',true,90000),
 ('eeee0000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','dddd0000-0000-0000-0000-000000000002','KURTA-L-BLK','{"Size":"L","Colour":"Black"}',false,90000);
""", "products")
check("simple product auto-created its default variant",
      q("select count(*) from core.product_variants where product_id='dddd0000-0000-0000-0000-000000000001'"), 1)
check("variant_integrity empty", q("select count(*) from core.variant_integrity"), 0)

print("\n=== the ledger invariant ===")
V1='eeee0000-0000-0000-0000-000000000001'; V2='eeee0000-0000-0000-0000-000000000002'
ORG='11111111-1111-1111-1111-111111111111'; LOC='aaaa0000-0000-0000-0000-00000000000a'
for d,r,cost in [(100,'opening',90000),(-5,'sale',None),(-2,'sale',None),(-1,'damage',None)]:
    run(f"select inventory.post_movement('{ORG}','{V1}','{LOC}',{d},'{r}',null,null,{cost or 'null'});")
check("balance = 100-5-2-1 = 92", q(f"select qty_on_hand::int from inventory.stock_balances where variant_id='{V1}'"), 92)
check("stock_integrity empty (balance == ledger)", q("select count(*) from inventory.stock_integrity"), 0)
expect_error(f"select inventory.post_movement('{ORG}','{V1}','{LOC}',-1000,'sale');",
             "oversell refused, not silently floored at 0", "insufficient stock")
check("balance unchanged after refused oversell",
      q(f"select qty_on_hand::int from inventory.stock_balances where variant_id='{V1}'"), 92)
run("update inventory.stock_movements set qty_delta = 999 where id = 1;")
check("UPDATE on the ledger is a no-op (append-only rule)",
      q("select count(*) from inventory.stock_movements where qty_delta = 999"), 0)
run("delete from inventory.stock_movements where id = 1;")
check("DELETE on the ledger is a no-op", q("select count(*) from inventory.stock_movements"), 4)

print("\n=== moving average cost ===")
run(f"select inventory.post_movement('{ORG}','{V2}','{LOC}',10,'purchase',null,null,100000);")
run(f"select inventory.post_movement('{ORG}','{V2}','{LOC}',10,'purchase',null,null,120000);")
check("10@Rs1000 + 10@Rs1200 -> avg Rs1100",
      q(f"select moving_avg_cost_paise from inventory.stock_balances where variant_id='{V2}'"), 110000)

print("\n=== reservations hold, they do not deduct ===")
run(f"""insert into inventory.reservations(org_id,variant_id,location_id,qty,source_app,source_ref)
        values ('{ORG}','{V1}','{LOC}',10,'catalogue','cart-1');""")
check("on hand unchanged by a hold", q(f"select qty_on_hand::int from inventory.stock_balances where variant_id='{V1}'"), 92)
check("available drops to 82",       q(f"select qty_available::int from inventory.stock_balances where variant_id='{V1}'"), 82)
expect_error(f"select inventory.post_movement('{ORG}','{V1}','{LOC}',-90,'sale');",
             "cannot sell into reserved stock", "insufficient stock")
run("update inventory.reservations set status='released' where source_ref='cart-1';")
check("releasing restores availability", q(f"select qty_available::int from inventory.stock_balances where variant_id='{V1}'"), 92)
check("reservation_integrity empty", q("select count(*) from inventory.reservation_integrity"), 0)

print("\n=== pricing: both legacy customer forks, from CONFIG alone ===")
run("""
insert into core.pricing_formulas(id,org_id,key,name,mode,wholesale_markup_bp,retail_multiplier,mrp_multiplier,retail_rounding,mrp_rounding,is_default)
values ('ffff0000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','yogendra','Blythe Diva legacy','multiplier',1000,2.2,2.75,'charm_9','multiple_5',true);
insert into core.pricing_formulas(id,org_id,key,name,mode,wholesale_markup_bp,retail_multiplier,mrp_multiplier,retail_tiers,retail_rounding,mrp_rounding)
values ('ffff0000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','aggarwal','Aggarwal fork','multiplier',0,1.5,4,
        '[{"below_paise":150000,"multiplier":1.6},{"multiplier":1.5}]','multiple_10','multiple_10');
""", "formulas")
F1='ffff0000-0000-0000-0000-000000000001'; F2='ffff0000-0000-0000-0000-000000000002'
check("Yogendra: Rs200 x2.2 = Rs440 -> charm Rs449", q(f"select retail_paise from core.compute_prices(20000,'{F1}')"), 44900)
check("Yogendra: Rs200 x2.75 = Rs550 (multiple of 5)", q(f"select mrp_paise from core.compute_prices(20000,'{F1}')"), 55000)
check("Aggarwal: Rs1000 (<Rs1500) uses 1.6x -> Rs1600", q(f"select retail_paise from core.compute_prices(100000,'{F2}')"), 160000)
check("Aggarwal: Rs2000 (>=Rs1500) uses 1.5x -> Rs3000", q(f"select retail_paise from core.compute_prices(200000,'{F2}')"), 300000)
check("MRP never printed below retail",
      q(f"select case when mrp_paise>=retail_paise then 'ok' else 'BROKEN' end from core.compute_prices(100000,'{F2}')"), "ok")
check("price-set validity rule holds",
      q(f"select core.price_set_is_valid(wholesale_paise,retail_paise,mrp_paise) from core.compute_prices(20000,'{F1}')"), True)

print("\n=== build-up mode (the owner's costing sheet) ===")
run("""insert into core.pricing_formulas(id,org_id,key,name,mode,shipping_bp,packing_flat_paise,promotion_flat_paise,reseller_bp,customer_discount_bp,mrp_bp,retail_rounding,mrp_rounding)
values ('ffff0000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','buildup','Costing sheet','buildup',500,2000,1000,4000,500,2500,'nearest','nearest');""")
check("build-up yields wholesale < retail <= mrp",
      q("""select case when wholesale_paise < retail_paise and retail_paise <= mrp_paise then 'ok' else 'BROKEN' end
           from core.compute_prices(20000,'ffff0000-0000-0000-0000-000000000003')"""), "ok")

print("\n=== quantity breaks ===")
run(f"""update core.pricing_formulas set qty_break_tiers='[{{"min_qty":12,"pct_off_bp":500}},{{"min_qty":50,"pct_off_bp":1000}}]' where id='{F1}';""")
check("qty 5 -> 0",     q(f"select core.qty_break_bp('{F1}',5)"), 0)
check("qty 12 -> 500bp",q(f"select core.qty_break_bp('{F1}',12)"), 500)
check("qty 60 -> best 1000bp", q(f"select core.qty_break_bp('{F1}',60)"), 1000)

print("\n=== catalogue publish + safe public read ===")
run("""
insert into catalogue.catalogues(id,org_id,slug,name,status,current_version)
values ('cccc0000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','acme-store','Acme Store','published',1);
insert into catalogue.catalogue_items(org_id,catalogue_id,product_id,variant_id)
values ('11111111-1111-1111-1111-111111111111','cccc0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000002','eeee0000-0000-0000-0000-000000000001');
insert into catalogue.published_snapshots(catalogue_id,version,payload)
values ('cccc0000-0000-0000-0000-000000000001',1,'{"name":"Acme Store","items":[]}');
""", "catalogue")
check("publish_integrity empty", q("select count(*) from catalogue.publish_integrity"), 0)
check("public snapshot readable by slug", q("select catalogue.public_snapshot('acme-store') ->> 'name'"), "Acme Store")
check("no connection -> manual stock status used", q("select status from catalogue.public_stock_status('acme-store')"), "in_stock")
run(f"insert into platform.app_connections(org_id,source_app,target_app,status) values ('{ORG}','catalogue','inventory','active');")
check("connected -> live stock (92) shows in_stock", q("select status from catalogue.public_stock_status('acme-store')"), "in_stock")
run(f"select inventory.post_movement('{ORG}','{V1}','{LOC}',-90,'sale');")
check("2 left -> badge auto-flips to 'limited'", q("select status from catalogue.public_stock_status('acme-store')"), "limited")
run("update catalogue.catalogues set status='unpublished' where slug='acme-store';")
check("unpublished catalogue returns nothing", q("select catalogue.public_snapshot('acme-store') is null"), True)
run("update catalogue.catalogues set status='published' where slug='acme-store';")

print("\n=== CROSS-TENANT ISOLATION ===")
run("""grant usage on schema platform, core, inventory, catalogue to app_user;
grant select, insert, update, delete on all tables in schema platform, core, inventory, catalogue to app_user;
grant usage, select on all sequences in schema platform, core, inventory, catalogue to app_user;
grant execute on all functions in schema platform, core, inventory, catalogue to app_user;""")
ACME, RIVAL = ORG, '22222222-2222-2222-2222-222222222222'
OA,OB,SA = 'aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-000000000003'
check("Acme owner sees Acme's 3 variants", as_user(OA,ACME,"select count(*) from core.product_variants"), 3)
check("Rival owner sees ZERO Acme variants", as_user(OB,RIVAL,"select count(*) from core.product_variants"), 0)
check("Rival owner sees ZERO Acme balances", as_user(OB,RIVAL,"select count(*) from inventory.stock_balances"), 0)
check("Rival owner sees ZERO Acme movements", as_user(OB,RIVAL,"select count(*) from inventory.stock_movements"), 0)
check("FORGED org_id in JWT gains nothing without membership",
      as_user(OB,ACME,"select count(*) from core.product_variants"), 0)
check("no catalogue entitlement -> no catalogues visible",
      as_user(OB,RIVAL,"select count(*) from catalogue.catalogues"), 0)

print("\n=== permissions inside one tenant ===")
check("staff CAN read stock", as_user(SA,ACME,"select count(*) from inventory.stock_balances"), 2)
checks += 1
try:
    as_user(SA, ACME, f"""insert into inventory.stock_movements(org_id,variant_id,location_id,qty_delta,reason)
        values ('{ORG}','{V1}','{LOC}',-5,'sale')""", expect_fail=True)
    print("  FAIL  staff was able to REMOVE stock"); fails.append("staff remove-stock block")
except Exception as e:
    ok = "row-level security" in str(e).lower()
    print(f"  {'PASS' if ok else 'FAIL'}  staff blocked from removing stock at the DB layer")
    if not ok: fails.append("staff remove-stock block")

print("\n=== FINAL: whole-system integrity ===")
check("platform.system_integrity is EMPTY", q("select count(*) from platform.system_integrity"), 0)

print("\n" + "="*66)
print(f"  {checks - len(fails)}/{checks} checks passed")
if fails:
    print("  FAILED: " + ", ".join(fails)); sys.exit(1)
print("  ALL GREEN")
print("="*66)
