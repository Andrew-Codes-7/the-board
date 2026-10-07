-- =============================================================
--  HARDEN INVITE CODES — run this once in Supabase → SQL Editor,
--  BEFORE letting anyone outside the family beta test.
--
--  Three problems this fixes, found by testing the live database:
--
--    1. HIGH  join_household_by_code could be called by anyone on the
--             internet — no login needed — with no limit on attempts.
--             Measured: 20 guesses in 3 seconds, never throttled.
--             Households created before the earlier security fix still
--             have 6-character codes (only ~16 million combinations),
--             which is well within reach of an automated guesser. One
--             correct guess = full read/write on that family's board.
--
--    2. MEDIUM Invite codes never expire and can be reused forever, so
--             someone removed from a household can immediately rejoin
--             using the code they already know.
--
--    3. LOW   The other admin functions were also callable without
--             logging in. Their internal checks held, so nothing leaked,
--             but they shouldn't be reachable by strangers at all.
-- =============================================================


-- =============================================================
--  0. FIX THE CODE GENERATOR FIRST
--  gen_invite_code() calls gen_random_bytes() from the pgcrypto
--  extension, which Supabase keeps in the "extensions" schema — but
--  this was the one function that never pinned its own search_path,
--  so it inherited "public" from its caller and couldn't find pgcrypto.
--  That's the "function gen_random_bytes(integer) does not exist" error
--  that blocked new signups.
--
--  This must run BEFORE step 2 below, which calls gen_invite_code() to
--  rotate codes and would otherwise fail the same way. Harmless to run
--  again if you already applied fix-invite-code-generator.sql.
-- =============================================================

create or replace function gen_invite_code()
returns text
language plpgsql
volatile
set search_path = public, extensions
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text := '';
  i int;
begin
  for i in 1..8 loop
    code := code || substr(alphabet, (get_byte(gen_random_bytes(1), 0) % length(alphabet)) + 1, 1);
  end loop;
  return code;
end;
$$;


-- =============================================================
--  1. ONLY SIGNED-IN USERS MAY CALL THESE FUNCTIONS
--  Postgres grants EXECUTE to everyone by default, so the earlier
--  "grant ... to authenticated" was additive and never actually shut
--  anonymous callers out. Revoke first, then re-grant.
-- =============================================================

revoke execute on function join_household_by_code(text)                  from public, anon;
revoke execute on function create_household(text)                        from public, anon;
revoke execute on function regenerate_invite_code(uuid)                  from public, anon;
revoke execute on function household_members_detailed(uuid)              from public, anon;
revoke execute on function remove_household_member(uuid, uuid)           from public, anon;
revoke execute on function set_household_member_role(uuid, uuid, text)   from public, anon;
revoke execute on function auth_household_ids()                          from public, anon;

grant execute on function join_household_by_code(text)                to authenticated;
grant execute on function create_household(text)                      to authenticated;
grant execute on function regenerate_invite_code(uuid)                to authenticated;
grant execute on function household_members_detailed(uuid)            to authenticated;
grant execute on function remove_household_member(uuid, uuid)         to authenticated;
grant execute on function set_household_member_role(uuid, uuid, text) to authenticated;
grant execute on function auth_household_ids()                        to authenticated;


-- =============================================================
--  2. GIVE EVERY OLD 6-CHARACTER CODE A NEW 8-CHARACTER ONE
--  8 characters from a 31-letter alphabet is about 850 billion
--  combinations instead of 16 million.
--
--  NOTE: this changes the invite code for every household that still
--  has an old one — including yours. Anyone mid-way through joining
--  will need the new code. Read it off the Household & members page
--  after running this.
-- =============================================================

do $$
declare
  hh   record;
  code text;
begin
  for hh in select id from households where invite_code is null or length(invite_code) < 8 loop
    loop
      code := gen_invite_code();
      exit when not exists (select 1 from households where invite_code = code);
    end loop;
    update households set invite_code = code where id = hh.id;
  end loop;
end $$;


-- =============================================================
--  3. THROTTLE WRONG GUESSES
--  Ten wrong codes an hour per account. Legitimate joining takes one
--  or two tries; a guesser needs millions, so this ends the attack
--  while staying invisible to real users.
--
--  No grants on this table on purpose — only the security-definer
--  function below writes to it, so nobody can read or clear it.
-- =============================================================

create table if not exists invite_attempts (
  user_id      uuid not null,
  attempted_at timestamptz not null default now()
);

create index if not exists idx_invite_attempts_user on invite_attempts (user_id, attempted_at);

alter table invite_attempts enable row level security;


create or replace function join_household_by_code(code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_household_id uuid;
  recent_failures     int;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to join a household.';
  end if;

  -- Forget attempts older than an hour, then count what's left.
  delete from invite_attempts where attempted_at < now() - interval '1 hour';

  select count(*) into recent_failures
  from invite_attempts
  where user_id = auth.uid() and attempted_at > now() - interval '1 hour';

  if recent_failures >= 10 then
    raise exception 'Too many incorrect invite codes. Wait an hour and try again.';
  end if;

  select id into target_household_id from households where invite_code = upper(code);

  if target_household_id is null then
    insert into invite_attempts (user_id) values (auth.uid());
    raise exception 'That invite code doesn''t match any household.';
  end if;

  insert into household_members (household_id, user_id, role)
  values (target_household_id, auth.uid(), 'member')
  on conflict (household_id, user_id) do nothing;

  -- A correct code clears the slate for that account.
  delete from invite_attempts where user_id = auth.uid();

  return target_household_id;
end;
$$;

revoke execute on function join_household_by_code(text) from public, anon;
grant  execute on function join_household_by_code(text) to authenticated;


-- =============================================================
--  4. REMOVING SOMEONE NOW RETIRES THE OLD INVITE CODE
--  Otherwise they can walk straight back in with the code they
--  already have. Everyone still in the household needs the new code
--  to invite anyone else — read it off Household & members.
-- =============================================================

create or replace function remove_household_member(hh uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  code text;
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

  loop
    code := gen_invite_code();
    exit when not exists (select 1 from households where invite_code = code);
  end loop;
  update households set invite_code = code where id = hh;
end;
$$;

revoke execute on function remove_household_member(uuid, uuid) from public, anon;
grant  execute on function remove_household_member(uuid, uuid) to authenticated;


-- =============================================================
--  DONE. Two things to know afterwards:
--    * Your household's invite code has changed — get the new one from
--      the Household & members page before inviting anyone.
--    * Removing a member now changes the code automatically, so anyone
--      else you want to invite afterwards needs the new one.
-- =============================================================
