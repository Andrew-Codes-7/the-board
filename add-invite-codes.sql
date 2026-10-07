-- =============================================================
--  ADD: household invite codes, so a second family member can join
--  an existing household instead of always getting a brand new one.
--  Run this once in Supabase → SQL Editor → New query → Run.
-- =============================================================

alter table households add column if not exists invite_code text unique;

-- Give any household that doesn't have a code yet a random 6-character one.
update households
set invite_code = upper(substr(md5(random()::text || id::text), 1, 6))
where invite_code is null;

-- Lets a signed-in user join a household by its invite code, without needing
-- to already be a member of it (which the normal security rules would otherwise
-- require). Runs with elevated privileges ("security definer") only for this one
-- narrow purpose — look up a household by code, then add the caller as a member.
create or replace function join_household_by_code(code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_household_id uuid;
begin
  select id into target_household_id from households where invite_code = upper(code);
  if target_household_id is null then
    raise exception 'That invite code doesn''t match any household.';
  end if;
  insert into household_members (household_id, user_id, role)
  values (target_household_id, auth.uid(), 'member')
  on conflict (household_id, user_id) do nothing;
  return target_household_id;
end;
$$;

grant execute on function join_household_by_code(text) to authenticated;
