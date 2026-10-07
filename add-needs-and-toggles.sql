-- =============================================================
--  NEEDS & WANTS + SECTION TOGGLES — run this once in Supabase → SQL Editor.
--
--  Two changes, both needed by the same app update:
--
--   1. a new `needs` table — the running list of things the house needs to
--      buy. Each item sits in one of two buckets: 'soon' (we're out of paper
--      towels) or 'someday' (a grill, eventually). Items move between the two.
--
--   2. a new `hidden_sections` column on the existing `settings` table — the
--      list of tabs and cards this household has switched off in Settings.
--      It's a JSON array of section ids, e.g. ["chores","meals.groceries"].
--      Empty array = everything shows, which is what every existing
--      household gets by default, so nothing changes until someone opts out.
-- =============================================================

create table if not exists needs (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  name          text not null,
  -- 'soon' = get it on the next shop; 'someday' = when we feel like it.
  bucket        text not null default 'soon' check (bucket in ('soon','someday')),
  note          text,
  done          boolean not null default false,
  completed_at  timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists idx_needs_hh_bucket on needs (household_id, bucket);


-- =============================================================
--  ROW LEVEL SECURITY — same rule as every other table: you may only touch
--  a row whose household_id is one of yours.
-- =============================================================

alter table needs enable row level security;

drop policy if exists "needs_select" on needs;
drop policy if exists "needs_insert" on needs;
drop policy if exists "needs_update" on needs;
drop policy if exists "needs_delete" on needs;

create policy "needs_select" on needs for select using (household_id in (select auth_household_ids()));
create policy "needs_insert" on needs for insert with check (household_id in (select auth_household_ids()));
create policy "needs_update" on needs for update using (household_id in (select auth_household_ids()));
create policy "needs_delete" on needs for delete using (household_id in (select auth_household_ids()));


-- =============================================================
--  GRANT TABLE ACCESS
--  security-fixes.sql turned off automatic grants for new tables (so a
--  forgotten RLS policy fails closed instead of silently exposing data).
--  This table needs it done by hand, same as any other new table.
-- =============================================================

grant all on needs to authenticated;
revoke all on needs from anon, public;


-- =============================================================
--  SECTION TOGGLES — one new column on the settings table each household
--  already has. `not null default '[]'` means existing rows are backfilled
--  with "nothing hidden" automatically.
-- =============================================================

alter table settings add column if not exists hidden_sections jsonb not null default '[]'::jsonb;


-- =============================================================
--  DONE. Reload the app — the new "Needs & Wants" tab will start saving,
--  and Settings will have a "Sections" card for switching things on and off.
-- =============================================================
