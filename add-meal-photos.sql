-- =============================================================
--  ADD MEAL PHOTOS — run this once in Supabase → SQL Editor.
--
--  Two parts:
--    1. Two new columns on `meals` to remember which photo belongs to a meal.
--    2. A storage bucket called `meal-photos` to actually hold the image files.
--
--  Why a bucket and not just the web address of the recipe site's photo: a link
--  to someone else's image breaks the day they rename or delete it, and a recipe
--  you saved two years ago would quietly turn into a blank card. Copying the
--  photo into your own storage on import means it's yours and stays put.
--
--  photo_url  is the address the app puts in the <img> tag.
--  photo_path is where the file sits inside the bucket, kept so that replacing
--             or clearing a photo can delete the old file instead of leaving
--             orphaned images piling up in storage forever.
-- =============================================================

alter table meals add column if not exists photo_url  text;
alter table meals add column if not exists photo_path text;


-- =============================================================
--  THE BUCKET
--
--  `public = true` means the image files can be viewed by anyone holding the
--  address — the same way any photo on any website works. That's deliberate:
--  it's what lets the <img> tag display them without juggling signed URLs that
--  expire. The addresses contain random ids and are not guessable, and these
--  are photos of dinner. WRITING to the bucket is a different matter and is
--  locked down properly below.
--
--  The 5MB ceiling and the file-type list are enforced by Supabase itself, so
--  they hold even if someone bypasses the app entirely.
-- =============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'meal-photos', 'meal-photos', true, 5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
  set public             = true,
      file_size_limit    = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp'];


-- =============================================================
--  WHO MAY WRITE TO IT
--
--  Every photo is stored under a folder named after the household it belongs
--  to, e.g.  <household-id>/<meal-id>-<random>.jpg
--
--  So the rule is the same one every other table already uses: you may only
--  touch a file whose folder is one of your households. Someone signed into a
--  different family's board cannot add, overwrite, or delete your photos.
--
--  Dropped first so this file can be safely re-run if anything needs changing.
-- =============================================================

drop policy if exists "meal_photos_insert" on storage.objects;
drop policy if exists "meal_photos_update" on storage.objects;
drop policy if exists "meal_photos_delete" on storage.objects;

create policy "meal_photos_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'meal-photos'
    and (storage.foldername(name))[1] in (select hid::text from public.auth_household_ids() as hid)
  );

create policy "meal_photos_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'meal-photos'
    and (storage.foldername(name))[1] in (select hid::text from public.auth_household_ids() as hid)
  );

create policy "meal_photos_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'meal-photos'
    and (storage.foldername(name))[1] in (select hid::text from public.auth_household_ids() as hid)
  );


-- =============================================================
--  DONE. Reload the app. Existing meals keep working exactly as they are —
--  they simply have no photo until you import one or add your own.
-- =============================================================
