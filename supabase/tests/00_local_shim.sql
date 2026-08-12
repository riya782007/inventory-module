-- LOCAL TEST ONLY. Supabase provides auth.uid()/auth.jwt() and the anon /
-- authenticated roles; this recreates just enough of them to run the real
-- migrations against a throwaway Postgres in CI.
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$
  -- matches Supabase: the subject comes out of the claims JSON
  select nullif(
    coalesce(
      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
      current_setting('request.jwt.claim.sub', true)
    ), '')::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='app_user') then create role app_user nologin; end if;
end $$;

-- On Supabase these grants already exist for authenticated/anon.
grant usage on schema auth to anon, authenticated, app_user;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, app_user;
