-- =============================================================
--  SECURITY FIXES — run this once in Supabase → SQL Editor.
--
--  Fixes found by testing the live database:
--    1. CRITICAL  Anyone with an account could add themselves to any household
--                 (bypassing the invite code) and then read or delete everything.
--    2. MEDIUM    Any member — not just the admin — could change the invite code
--                 and rename the household. The UI hid the button; the database
--                 allowed it anyway.
--    3. MEDIUM    Invite codes were generated with a non-cryptographic random
--                 number generator, so they were somewhat predictable.
--    4. LOW       Any table added in future would be readable by every logged-in
--                 user until someone remembered to switch on row security.
-- =============================================================


-- =============================================================
--  1. CLOSE THE SELF-JOIN HOLE  (the critical one)
--
--  The old rule said "you may add a membership row as long as it's for
--  yourself" — which let anyone who learned a household's id walk straight in.
--  Joining now has to go through join_household_by_code, which demands the code.
-- =============================================================

drop policy if exists "hm_insert" on household_members;


-- =============================================================
--  2. CRYPTOGRAPHICALLY RANDOM INVITE CODES
--  Uses pgcrypto's secure random bytes instead of a predictable generator,
--  and 8 characters instead of 6 (about 850 billion combinations).
--  Ambiguous characters (0/O, 1/I/L) are left out so codes can be read aloud.
-- =============================================================

create or replace function gen_invite_code()
returns text
language plpgsql
volatile
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
--  3. CREATING A HOUSEHOLD
--  Because the app can no longer insert its own membership row, starting a
--  household happens here: the household and the owner's membership are created
--  together, so there's no moment where one exists without the other.
-- =============================================================

create or replace function create_household(hh_name text default 'Our Household')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid := gen_random_uuid();
  code   text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to start a household.';
  end if;

  -- Retry in the vanishingly unlikely event of a code collision.
  loop
    code := gen_invite_code();
    exit when not exists (select 1 from households where invite_code = code);
  end loop;

  insert into households (id, name, invite_code) values (new_id, hh_name, code);
  insert into household_members (household_id, user_id, role)
  values (new_id, auth.uid(), 'owner');

  return new_id;
end;
$$;

grant execute on function create_household(text) to authenticated;


-- =============================================================
--  4. CHANGING THE INVITE CODE — ADMIN ONLY
--  Previously any member could do this directly against the database.
-- =============================================================

create or replace function regenerate_invite_code(hh uuid)
returns text
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
    raise exception 'Only the household admin can change the invite code.';
  end if;

  loop
    code := gen_invite_code();
    exit when not exists (select 1 from households where invite_code = code);
  end loop;

  update households set invite_code = code where id = hh;
  return code;
end;
$$;

grant execute on function regenerate_invite_code(uuid) to authenticated;


-- =============================================================
--  5. LOCK DOWN DIRECT EDITS TO THE HOUSEHOLD ROW
--  Members can still read it; only the admin can change it, and that now runs
--  through the function above.
-- =============================================================

drop policy if exists "hh_update" on households;
create policy "hh_update" on households for update
  using (
    id in (
      select household_id from household_members
      where user_id = auth.uid() and role = 'owner'
    )
  );

-- Households are never created directly by the app any more.
drop policy if exists "hh_insert" on households;


-- =============================================================
--  6. FAIL CLOSED ON FUTURE TABLES
--  Previously any new table was automatically readable by every logged-in user.
--  Now a new table starts locked, and you grant access deliberately — forgetting
--  a grant shows a visible error, whereas forgetting row security silently
--  exposed data.
-- =============================================================

alter default privileges in schema public revoke all on tables from authenticated;
alter default privileges in schema public revoke all on sequences from authenticated;


-- =============================================================
--  DONE. Existing 6-character invite codes keep working; any code generated
--  from now on is 8 characters and cryptographically random.
-- =============================================================
