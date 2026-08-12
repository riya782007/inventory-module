-- ============================================================================
-- 0013 · ORG RESOLUTION FALLBACK
-- current_org_id() previously trusted ONLY the JWT app_metadata stamp, which
-- is written by an admin-API call after onboarding. If that stamp ever fails
-- (missing service key, half-failed signup), the user is locked out even
-- though their membership row exists. Now: JWT claim first (fast path),
-- else the user's single active membership. V1 is one-org-per-user, so the
-- fallback is unambiguous.
-- SECURITY DEFINER is safe from recursion: org_members deliberately does not
-- FORCE RLS (see 0008), so the definer/owner read bypasses its policies.
-- ============================================================================
create or replace function platform.current_org_id() returns uuid
language sql stable security definer
set search_path = platform, public
as $$
  select coalesce(
    nullif(((select auth.jwt()) -> 'app_metadata' ->> 'org_id'), '')::uuid,
    (select m.org_id from platform.org_members m
     where m.user_id = (select auth.uid()) and m.status = 'active'
     limit 1)
  )
$$;
