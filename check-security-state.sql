-- =============================================================
--  READ-ONLY HEALTH CHECK — changes nothing, safe to run anytime.
--  Paste into Supabase → SQL Editor → Run.
--
--  You want all four rows to say OK. Any row saying NEEDS FIX means
--  run harden-invite-codes.sql (it fixes all four).
-- =============================================================

select
  '1. signups work (code generator)'::text as check_name,
  case when p.proconfig::text like '%extensions%' then 'OK' else 'NEEDS FIX' end::text as status,
  coalesce(p.proconfig::text, 'no search_path set - this is the signup bug')::text as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'gen_invite_code'

union all

select
  '2. strangers locked out of admin functions'::text,
  case when count(*) = 0 then 'OK' else 'NEEDS FIX' end::text,
  case when count(*) = 0
       then 'no anonymous access'
       else count(*)::text || ' still open to anyone: ' || coalesce(string_agg(p.proname, ', '), '')
  end::text
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('join_household_by_code','create_household','regenerate_invite_code',
                    'household_members_detailed','remove_household_member','set_household_member_role')
  and has_function_privilege('anon', p.oid, 'EXECUTE')

union all

select
  '3. invite-code guessing is throttled'::text,
  case when exists (
         select 1 from pg_proc p2
         join pg_namespace n2 on n2.oid = p2.pronamespace
         where n2.nspname = 'public'
           and p2.proname = 'join_household_by_code'
           and p2.prosrc like '%invite_attempts%'
       ) then 'OK' else 'NEEDS FIX' end::text,
  case when exists (select 1 from information_schema.tables
                    where table_schema = 'public' and table_name = 'invite_attempts')
       then 'attempt log present' else 'attempt log missing' end::text

union all

select
  '4. all invite codes are 8 characters'::text,
  case when count(*) filter (where invite_code is null or length(invite_code) < 8) = 0
       then 'OK' else 'NEEDS FIX' end::text,
  count(*) filter (where invite_code is null or length(invite_code) < 8)::text
    || ' of ' || count(*)::text || ' households still on a short code'
from households;
