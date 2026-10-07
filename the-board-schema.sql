-- =============================================================
--  THE BOARD — DATABASE SCHEMA
--  Run this once in Supabase → SQL Editor → New query → Run.
--  It creates every table your app needs, scopes all data to a
--  "household," and turns on Row Level Security so one family can
--  never see another's data.
--
--  Safe to read top to bottom. You don't need to understand it —
--  but it's commented so you can if you want to.
-- =============================================================

-- Needed for auto-generating IDs.
create extension if not exists "pgcrypto";


-- =============================================================
--  1. HOUSEHOLDS & MEMBERS
--  A household is one family's shared space. Users (you, your wife)
--  are linked to a household through household_members.
-- =============================================================

create table if not exists households (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default 'Our Household',
  created_at  timestamptz not null default now()
);

create table if not exists household_members (
  household_id uuid not null references households(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null default 'member',   -- 'owner' or 'member'
  created_at   timestamptz not null default now(),
  primary key (household_id, user_id)
);

-- Helper: which households does the logged-in user belong to?
-- Marked "security definer" so it can read membership without tripping
-- over its own security rules (prevents an infinite loop).
create or replace function auth_household_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select household_id from household_members where user_id = auth.uid()
$$;


-- =============================================================
--  2. PEOPLE (family members you assign things to)
--  Note: these are "assignees" (including kids who have no login),
--  separate from actual app users above.
-- =============================================================

create table if not exists people (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  name          text not null,
  color         text not null default '#7FA593',
  created_at    timestamptz not null default now()
);


-- =============================================================
--  3. TASK CATEGORIES
-- =============================================================

create table if not exists task_categories (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  name          text not null,
  created_at    timestamptz not null default now()
);


-- =============================================================
--  4. CALENDAR EVENTS
-- =============================================================

create table if not exists events (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  date          date not null,
  title         text not null,
  time          text,                       -- optional, stored as "18:30"
  notes         text,
  person_id     uuid references people(id) on delete set null,
  from_task_id  uuid,                        -- links back to a scheduled task
  created_at    timestamptz not null default now()
);


-- =============================================================
--  5. TASKS (to-dos)
-- =============================================================

create table if not exists todos (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references households(id) on delete cascade,
  title          text not null,
  notes          text,
  done           boolean not null default false,
  priority       text not null default 'none',   -- none / low / medium / high
  scheduled_date date,
  event_id       uuid references events(id) on delete set null,
  category_id    uuid references task_categories(id) on delete set null,
  person_id      uuid references people(id) on delete set null,
  sort_order     integer not null default 0,
  completed_at   timestamptz,
  created_at     timestamptz not null default now()
);


-- =============================================================
--  6. MEALS (recipe box)
-- =============================================================

create table if not exists meals (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  name          text not null,
  link          text,
  notes         text,
  created_at    timestamptz not null default now()
);


-- =============================================================
--  7. WEEKLY MEAL PLAN
-- =============================================================

create table if not exists meal_plan (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  date          date not null,
  slot          text not null,              -- breakfast / lunch / dinner
  meal_id       uuid references meals(id) on delete set null,
  text          text,                       -- free-text meal if not from recipe box
  person_id     uuid references people(id) on delete set null,
  created_at    timestamptz not null default now()
);


-- =============================================================
--  8. THINGS TO DO (activity ideas)
--  categories stored as a JSON list of names, e.g. ["Family","Alone"]
-- =============================================================

create table if not exists activities (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  name          text not null,
  categories    jsonb not null default '[]',
  created_at    timestamptz not null default now()
);


-- =============================================================
--  9. CHORES
-- =============================================================

create table if not exists chores (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  name          text not null,
  person_id     uuid references people(id) on delete set null,
  freq          text not null default 'Weekly',  -- Daily/Weekly/Monthly/One-time
  done          boolean not null default false,
  created_at    timestamptz not null default now()
);


-- =============================================================
--  10. GROCERIES + PRICE HISTORY
--  Each item's price observations live in their own rows (grocery_prices),
--  which is what makes real price tracking / trends possible.
-- =============================================================

create table if not exists groceries (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  item          text not null,
  source        text,                        -- default/most-recent store
  cost          numeric,                     -- latest price (mirror of newest history row)
  currency      text not null default 'USD',
  created_at    timestamptz not null default now()
);

create table if not exists grocery_prices (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  grocery_id    uuid not null references groceries(id) on delete cascade,
  price         numeric not null,
  currency      text not null default 'USD',
  store         text,
  date          date not null default current_date,
  created_at    timestamptz not null default now()
);


-- =============================================================
--  11. SETTINGS (one row per household)
-- =============================================================

create table if not exists settings (
  household_id   uuid primary key references households(id) on delete cascade,
  currency       text not null default 'USD',
  fx_rates       jsonb,
  fx_updated_at  timestamptz,
  updated_at     timestamptz not null default now()
);


-- =============================================================
--  12. ROW LEVEL SECURITY
--  This is the important part: every table is locked so a user can
--  only touch rows belonging to a household they're a member of.
-- =============================================================

-- Households: you can see/manage a household you belong to; any logged-in
-- user may create one (the app makes them a member right after).
alter table households enable row level security;
create policy "hh_select" on households for select
  using (id in (select auth_household_ids()));
create policy "hh_insert" on households for insert
  with check (auth.uid() is not null);
create policy "hh_update" on households for update
  using (id in (select auth_household_ids()));

-- Household members: you can see and manage your own membership rows.
alter table household_members enable row level security;
create policy "hm_select" on household_members for select
  using (user_id = auth.uid());
create policy "hm_insert" on household_members for insert
  with check (user_id = auth.uid());
create policy "hm_delete" on household_members for delete
  using (user_id = auth.uid());

-- Every data table below follows the same rule:
-- "you may touch this row only if its household_id is one of yours."
-- (Written out per-table because Postgres needs explicit policies.)

do $$
declare t text;
begin
  foreach t in array array[
    'people','task_categories','events','todos','meals','meal_plan',
    'activities','chores','groceries','grocery_prices','settings'
  ]
  loop
    execute format('alter table %I enable row level security;', t);
    execute format($f$create policy "%1$s_select" on %1$I for select using (household_id in (select auth_household_ids()));$f$, t);
    execute format($f$create policy "%1$s_insert" on %1$I for insert with check (household_id in (select auth_household_ids()));$f$, t);
    execute format($f$create policy "%1$s_update" on %1$I for update using (household_id in (select auth_household_ids()));$f$, t);
    execute format($f$create policy "%1$s_delete" on %1$I for delete using (household_id in (select auth_household_ids()));$f$, t);
  end loop;
end $$;


-- =============================================================
--  13. HELPFUL INDEXES (make lookups fast as data grows)
-- =============================================================

create index if not exists idx_events_hh_date       on events (household_id, date);
create index if not exists idx_todos_hh             on todos (household_id);
create index if not exists idx_meal_plan_hh_date    on meal_plan (household_id, date);
create index if not exists idx_activities_hh        on activities (household_id);
create index if not exists idx_chores_hh            on chores (household_id);
create index if not exists idx_groceries_hh         on groceries (household_id);
create index if not exists idx_grocery_prices_item  on grocery_prices (grocery_id);
create index if not exists idx_members_user         on household_members (user_id);

-- =============================================================
--  DONE. Every table exists and is locked down by household.
--  Next: turn on Authentication, then wire the app's saves/loads
--  to these tables (Phase 3 & 4).
-- =============================================================
