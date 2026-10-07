-- =============================================================
--  ADD FOOD PURCHASES / RECEIPT LOG — run this once in Supabase → SQL Editor.
--
--  Adds two new tables for the "Purchases" section under the Meals tab:
--    receipts        one row per purchase (a single item, or a whole receipt)
--    receipt_items   one row per line item on that purchase
--
--  usd_amount on receipt_items is the USD value at the moment the item was
--  logged (using that day's exchange rate), frozen permanently — so looking
--  back at old purchases shows what was actually paid, not today's rate.
-- =============================================================

create table if not exists receipts (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  date          date not null default current_date,
  store         text,
  currency      text not null default 'USD',
  created_at    timestamptz not null default now()
);

create table if not exists receipt_items (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  receipt_id    uuid not null references receipts(id) on delete cascade,
  name          text not null,
  price         numeric not null,
  quantity      text,
  usd_amount    numeric,
  created_at    timestamptz not null default now()
);

create index if not exists idx_receipts_hh_date      on receipts (household_id, date);
create index if not exists idx_receipt_items_receipt on receipt_items (receipt_id);


-- =============================================================
--  ROW LEVEL SECURITY — same rule as every other table: you may only touch
--  a row whose household_id is one of yours.
-- =============================================================

do $$
declare t text;
begin
  foreach t in array array['receipts','receipt_items']
  loop
    execute format('alter table %I enable row level security;', t);
    execute format($f$create policy "%1$s_select" on %1$I for select using (household_id in (select auth_household_ids()));$f$, t);
    execute format($f$create policy "%1$s_insert" on %1$I for insert with check (household_id in (select auth_household_ids()));$f$, t);
    execute format($f$create policy "%1$s_update" on %1$I for update using (household_id in (select auth_household_ids()));$f$, t);
    execute format($f$create policy "%1$s_delete" on %1$I for delete using (household_id in (select auth_household_ids()));$f$, t);
  end loop;
end $$;


-- =============================================================
--  GRANT TABLE ACCESS
--  security-fixes.sql turned off automatic grants for new tables (so a
--  forgotten RLS policy fails closed instead of silently exposing data).
--  These two tables need it done by hand, same as any other new table.
-- =============================================================

grant all on receipts to authenticated;
grant all on receipt_items to authenticated;


-- =============================================================
--  DONE. Reload the app — the new "Purchases" card under Meals will start
--  saving to these tables.
-- =============================================================
