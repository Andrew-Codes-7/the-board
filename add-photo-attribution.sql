-- =============================================================
--  PHOTO CREDIT ON ACTIVITY CARDS — run this once in Supabase → SQL Editor.
--
--  One new column. Pictures found through Openverse are openly licensed, but
--  most of those licences ask to be credited, so the photographer's name and
--  the licence travel with the picture instead of being lost the moment it's
--  chosen. Your own uploaded photos simply leave it empty.
--
--  Nothing else changes: the `activity-photos` storage bucket and the
--  photo_url / photo_path columns from add-activity-photos.sql are unchanged,
--  and existing cards keep working with no credit recorded.
-- =============================================================

alter table activities add column if not exists photo_attribution text;


-- =============================================================
--  DONE. Reload the app — "Find a picture" on a Things To Do card will start
--  saving the credit along with the picture.
-- =============================================================
