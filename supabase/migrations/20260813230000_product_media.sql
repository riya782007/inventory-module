-- ============================================================================
-- 0014 · PRODUCT MEDIA (Storage bucket + org-scoped policies)
-- Path convention: product-media/{org_id}/{product_id}/{uuid}.jpg
-- The first path segment IS the tenant boundary; policies enforce it.
-- The bucket is public-read (the future catalogue serves images via CDN);
-- writes require membership of the org in the path + products.edit.
-- Wrapped in a guard so the migration also applies on a bare Postgres in CI
-- (the storage schema only exists on Supabase).
-- ============================================================================
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema absent (local CI) - skipping bucket setup';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('product-media', 'product-media', true, 5242880,
          array['image/jpeg','image/png','image/webp'])
  on conflict (id) do update set
    public = true, file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp'];

  begin
    execute $p$
      create policy "product media org upload" on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'product-media'
        and (storage.foldername(name))[1] = platform.current_org_id()::text
        and platform.has_perm('products.edit'))
    $p$;
  exception when duplicate_object then null; end;

  begin
    execute $p$
      create policy "product media org read" on storage.objects
      for select to authenticated
      using (
        bucket_id = 'product-media'
        and (storage.foldername(name))[1] = platform.current_org_id()::text)
    $p$;
  exception when duplicate_object then null; end;

  begin
    execute $p$
      create policy "product media org delete" on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'product-media'
        and (storage.foldername(name))[1] = platform.current_org_id()::text
        and platform.has_perm('products.edit'))
    $p$;
  exception when duplicate_object then null; end;
end $$;
