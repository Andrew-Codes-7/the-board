-- =============================================================
--  ADD: link logins to family members, plus household admin tools.
--  Run this once in Supabase → SQL Editor → New query → Run.
--
--  Two ideas to keep straight:
--    * a "family member" (people table) is anyone on the board — including
--      kids who will never log in. They can be assigned chores and tasks.
--    * a "login" (auth user) is an account. Every login points at exactly one
--      family member, but most family members have no login at all.
-- =============================================================


-- =============================================================
--  1. LINK A LOGIN TO A FAMILY MEMBER
--  Nullable on purpose: a person with no user_id is someone without a login.
-- =============================================================

alter table people add column if not exists user_id uuid references auth.users(id) on delete set null;

-- One login can claim at most one person per household.
create unique index if not exists idx_people_household_user
  on people (household_id, user_id) where user_id is not null;


-- =============================================================
--  2. WHO'S IN THIS HOUSEHOLD (with their email addresses)
--  Email lives in auth.users, which the app can't read directly, so this
--  function reads it on the caller's behalf — but only after checking the
--  caller actually belongs to the household they're asking about.
-- =============================================================

create or replace function household_members_detailed(hh uuid)
returns table (
  user_id     uuid,
  email       text,
  role        text,
  person_id   uuid,
  person_name text,
  joined_at   timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from household_members
    where household_id = hh and household_members.user_id = auth.uid()
  ) then
    raise exception 'You are not a member of that household.';
  end if;

  return query
    select hm.user_id,
           u.email::text,
           hm.role,
           p.id,
           p.name,
           hm.created_at
    from household_members hm
    join auth.users u on u.id = hm.user_id
    left join people p on p.user_id = hm.user_id and p.household_id = hm.household_id
    where hm.household_id = hh
    order by hm.created_at;
end;
$$;

grant execute on function household_members_detailed(uuid) to authenticated;


-- =============================================================
--  3. REMOVE SOMEONE FROM THE HOUSEHOLD (owner only)
--  Their family member record stays behind — only the login link is cut —
--  so any chores or tasks assigned to that person keep working.
-- =============================================================

create or replace function remove_household_member(hh uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from household_members
    where household_id = hh and user_id = auth.uid() and role = 'owner'
  ) then
    raise exception 'Only the household admin can remove members.';
  end if;

  if target = auth.uid() then
    raise exception 'You cannot remove yourself. Use "Leave household" instead.';
  end if;

  update people set user_id = null where household_id = hh and user_id = target;
  delete from household_members where household_id = hh and user_id = target;
end;
$$;

grant execute on function remove_household_member(uuid, uuid) to authenticated;


-- =============================================================
--  4. CHANGE SOMEONE'S ROLE (owner only)
--  Lets the admin hand admin rights to someone else, or take them back.
-- =============================================================

create or replace function set_household_member_role(hh uuid, target uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if new_role not in ('owner','member') then
    raise exception 'Role must be owner or member.';
  end if;

  if not exists (
    select 1 from household_members
    where household_id = hh and user_id = auth.uid() and role = 'owner'
  ) then
    raise exception 'Only the household admin can change roles.';
  end if;

  -- Don't allow the last admin to demote themselves out of existence.
  if target = auth.uid() and new_role = 'member'
     and (select count(*) from household_members where household_id = hh and role = 'owner') <= 1 then
    raise exception 'Make someone else an admin first.';
  end if;

  update household_members set role = new_role
  where household_id = hh and user_id = target;
end;
$$;

grant execute on function set_household_member_role(uuid, uuid, text) to authenticated;
