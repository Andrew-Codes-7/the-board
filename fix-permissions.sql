-- =============================================================
--  FIX: grant baseline table access to logged-in users.
--  Run this once in Supabase → SQL Editor → New query → Run.
--
--  Your Row Level Security policies (from the-board-schema.sql) already
--  control who can see which rows, scoped to your household. But Postgres
--  also requires a more basic "you're allowed to touch this table at all"
--  grant underneath that, and the original schema script didn't include it.
--  This adds that missing piece — it does not loosen any of the
--  household-scoping security you already have.
-- =============================================================

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;

-- So any table created the same way in the future gets this automatically too.
alter default privileges in schema public grant all on tables to authenticated;
alter default privileges in schema public grant all on sequences to authenticated;
