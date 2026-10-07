-- =============================================================
--  ADD PICTURES TO "THINGS TO DO" — run this once in Supabase → SQL Editor.
--
--  This is the same setup add-meal-photos.sql did for meals, applied to the
--  activity ideas so their cards can be photo-forward too:
--    1. Two new columns on `activities` to remember which picture belongs to it.
--    2. A storage bucket called `activity-photos` to hold the image files.
--
--  Safe to run more than once — every step checks before it acts.
--
--  photo_url  is the address the app puts in the <img> tag.
--  photo_path is where the file sits inside the bucket, kept so that replacing
--             or clearing a picture can delete the old file instead of leaving
--             orphaned images piling up in storage forever.
-- =============================================================

alter table activities add column if not exists photo_url  text;
alter table activities add column if not exists photo_path text;


-- =============================================================
--  THE BUCKET
--
--  Same reasoning as meal-photos: `public = true` means the files can be viewed
--  by anyone holding the address, which is what lets an <img> tag show them
--  without juggling signed URLs that expire. The addresses contain random ids
--  and are not guessable. WRITING to the bucket is locked down below.
--
--  The 5MB ceiling and the file-type list are enforced by Supabase itself, so
--  they hold even if someone bypasses the app entirely.
-- =============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'activity-photos', 'activity-photos', true, 5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
  set public             = true,
      file_size_limit    = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp'];


-- =============================================================
--  WHO MAY WRITE TO IT
--
--  Every picture is stored under a folder named after the household it belongs
--  to, e.g.  <household-id>/<activity-id>-<random>.jpg
--
--  So the rule is the one every other table already uses: you may only touch a
--  file whose folder is one of your households. Someone signed into a different
--  family's board cannot add, overwrite, or delete your pictures.
-- =============================================================

drop policy if exists "activity_photos_insert" on storage.objects;
drop policy if exists "activity_photos_update" on storage.objects;
drop policy if exists "activity_photos_delete" on storage.objects;

create policy "activity_photos_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'activity-photos'
    and (storage.foldername(name))[1] in (select hid::text from public.auth_household_ids() as hid)
  );

create policy "activity_photos_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'activity-photos'
    and (storage.foldername(name))[1] in (select hid::text from public.auth_household_ids() as hid)
  );

create policy "activity_photos_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'activity-photos'
    and (storage.foldername(name))[1] in (select hid::text from public.auth_household_ids() as hid)
  );


-- =============================================================
--  DONE. Reload the app. Existing ideas keep working exactly as they are —
--  they simply stay on the plain paper card until you give them a picture.
-- =============================================================
