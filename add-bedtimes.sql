-- =============================================================
--  BEDTIME CALENDAR — run this once in Supabase → SQL Editor.
--
--  Two changes, both needed by the same app update:
--
--   1. three new columns on the existing `people` table — whether this person
--      appears on the bedtime board at all, and the two times they normally go
--      down: a weeknight one (Sunday through Thursday night) and a weekend one
--      (Friday and Saturday night). Nobody is on the board until you tick them,
--      so nothing changes for existing households until someone opts a kid in.
--
--   2. a new `bedtimes` table holding ONLY the nights that differ from those
--      usual times — a sleepover, a late game, whoever's on duty that night.
--      A night with no row here simply shows the person's usual time, which is
--      why changing a usual time instantly moves every night you haven't
--      already changed by hand, and why this table stays small.
-- =============================================================

alter table people add column if not exists bedtime_enabled        boolean not null default false;
alter table people add column if not exists default_bedtime        time;
alter table people add column if not exists default_bedtime_weekend time;


create table if not exists bedtimes (
  id                 uuid primary key default gen_random_uuid(),
  household_id       uuid not null references households(id) on delete cascade,
  date               date not null,
  person_id          uuid not null references people(id) on delete cascade,
  -- null = "the usual time still applies". A row can exist purely to carry a
  -- note or an on-duty parent without pinning the time, so that night keeps
  -- following the usual time if it's ever changed.
  time               time,
  notes              text,
  -- the parent handling bedtime that night. Losing that person shouldn't lose
  -- the night itself, so this clears rather than cascades.
  on_duty_person_id  uuid references people(id) on delete set null,
  created_at         timestamptz not null default now(),
  -- one row per person per night — the app relies on this.
  unique (household_id, date, person_id)
);

create index if not exists idx_bedtimes_hh_date on bedtimes (household_id, date);


-- =============================================================
--  ROW LEVEL SECURITY — same rule as every other table: you may only touch
--  a row whose household_id is one of yours.
-- =============================================================

alter table bedtimes enable row level security;

drop policy if exists "bedtimes_select" on bedtimes;
drop policy if exists "bedtimes_insert" on bedtimes;
drop policy if exists "bedtimes_update" on bedtimes;
drop policy if exists "bedtimes_delete" on bedtimes;

create policy "bedtimes_select" on bedtimes for select using (household_id in (select auth_household_ids()));
create policy "bedtimes_insert" on bedtimes for insert with check (household_id in (select auth_household_ids()));
create policy "bedtimes_update" on bedtimes for update using (household_id in (select auth_household_ids()));
create policy "bedtimes_delete" on bedtimes for delete using (household_id in (select auth_household_ids()));


-- =============================================================
--  GRANT TABLE ACCESS
--  security-fixes.sql turned off automatic grants for new tables (so a
--  forgotten RLS policy fails closed instead of silently exposing data).
--  This table needs it done by hand, same as any other new table.
-- =============================================================

grant all on bedtimes to authenticated;
revoke all on bedtimes from anon, public;


-- =============================================================
--  DONE. Reload the app — the new "Bedtime" tab will start saving. Tick the
--  kids you want on the board under "Usual Bedtimes" and the week fills itself
--  in from there.
-- =============================================================
