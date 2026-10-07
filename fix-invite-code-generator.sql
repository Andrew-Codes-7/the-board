-- =============================================================
--  FIX: "function gen_random_bytes(integer) does not exist"
--  Run this once in Supabase → SQL Editor. Fixes new signups being
--  unable to start a household.
--
--  What went wrong:
--    gen_invite_code() builds a random code using gen_random_bytes(),
--    which comes from the pgcrypto extension. Supabase keeps pgcrypto
--    in a schema called "extensions", not in "public".
--
--    Every other function in this app pins its search_path to "public"
--    for safety. gen_invite_code() was the one function that didn't, so
--    it ran with whatever path its caller had — and create_household
--    pins "public". Result: pgcrypto was invisible and the lookup failed.
--
--  Why it stayed hidden until now: nothing had called create_household
--  since it was added. The original household predates it and the second
--  member joined by invite code, so the first brand-new signup was the
--  first time this code path ever ran.
--
--  The fix is to pin gen_invite_code()'s own search_path and include the
--  extensions schema. A function's own search_path always wins while it
--  runs, so fixing it here fixes every caller at once — creating a
--  household, regenerating a code, and removing a member.
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
--  CHECK IT WORKED
--  This should return three different 8-character codes made up of
--  A-Z and 2-9 (no O/0 or I/1, so codes can be read aloud).
--  If it errors instead, stop and send me the message.
-- =============================================================

select gen_invite_code() as sample_1,
       gen_invite_code() as sample_2,
       gen_invite_code() as sample_3;
