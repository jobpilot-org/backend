-- Tests for the profile tables and replace_profile().
--
-- User one ('1111...') and user two ('2222...') check that RLS keeps each user to their own profile
-- and that replace_profile() swaps the whole profile atomically for the caller only.
begin;

create extension if not exists pgtap with schema extensions;

select plan(35);

-- -------------------------------------------------------------------------------------------------
-- Schema, RLS, and role privileges
-- -------------------------------------------------------------------------------------------------

create temporary table profile_tables (name text) on commit drop;
insert into profile_tables
values ('profiles'), ('profile_entries'), ('profile_skills'), ('profile_languages');

select has_table('public', name, name || ' exists') from profile_tables;

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = ('public.' || name)::regclass),
  name || ' has row level security enabled'
)
  from profile_tables;

select table_privs_are('public', name, 'anon', array[]::text[], 'anon has no privileges on ' || name)
  from profile_tables;

select col_is_pk('public', 'profiles', 'user_id', 'one profile per user');

select function_privs_are(
  'public', 'replace_profile', array['jsonb'], 'anon', array[]::text[],
  'anon cannot call replace_profile'
);

-- -------------------------------------------------------------------------------------------------
-- Test accounts
-- -------------------------------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values
  (
    '11111111-1111-1111-1111-111111111111',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'user-one@example.com',
    now(),
    now()
  ),
  (
    '22222222-2222-2222-2222-222222222222',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'user-two@example.com',
    now(),
    now()
  );

-- -------------------------------------------------------------------------------------------------
-- User one replaces their profile
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select lives_ok(
  $$select public.replace_profile('{
    "firstName": "Erika",
    "lastName": "Muster",
    "headline": "Senior Fullstack-Entwicklerin",
    "city": "Berlin",
    "birthDate": "1980-02-03",
    "summary": "Zwanzig Jahre Web.",
    "experience": [
      {"title": "Senior Entwicklerin", "organization": "Acme", "startDate": "2023-05", "isCurrent": true},
      {"title": "Entwicklerin", "organization": "Beta", "startDate": "2019", "endDate": "2023-04"}
    ],
    "education": [
      {"title": "Bachelor Informatik", "organization": "TU Berlin", "startDate": "2000", "endDate": "2004"}
    ],
    "skills": [{"category": "Frontend", "items": "React, TypeScript"}],
    "languages": [{"language": "Deutsch", "level": "Muttersprache"}, {"language": "Englisch"}]
  }'::jsonb)$$,
  'user one replaces their profile'
);

select is(
  (select first_name || ' ' || last_name || ' · ' || headline from public.profiles),
  'Erika Muster · Senior Fullstack-Entwicklerin',
  'personal data is stored'
);

select is(
  (select user_id from public.profiles),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'user_id comes from auth.uid()'
);

select isnt((select onboarded_at from public.profiles), null, 'replace_profile marks the user as onboarded');

select results_eq(
  $$select kind, position, title, start_date, end_date, is_current
      from public.profile_entries order by kind desc, position$$,
  $$values
      ('experience', 0, 'Senior Entwicklerin', '2023-05', null::text, true),
      ('experience', 1, 'Entwicklerin', '2019', '2023-04', false),
      ('education', 0, 'Bachelor Informatik', '2000', '2004', false)$$,
  'entries keep their kind and order'
);

select is((select count(*) from public.profile_skills)::int, 1, 'skills are stored');

select results_eq(
  $$select language, level from public.profile_languages order by position$$,
  $$values ('Deutsch', 'Muttersprache'), ('Englisch', null::text)$$,
  'languages keep their order; a missing level stays null'
);

select lives_ok(
  $$update public.profiles set onboarded_at = '2026-01-01T00:00:00Z'$$,
  'user one updates their profile row'
);

select lives_ok(
  $$select public.replace_profile('{"firstName": "Erika", "lastName": "Muster", "experience": [
      {"title": "Neue Station"}
    ]}'::jsonb)$$,
  'replacing again succeeds'
);

select is(
  (select title from public.profile_entries),
  'Neue Station',
  'replacing removes the previous entries'
);

select is((select count(*) from public.profile_skills)::int, 0, 'replacing removes the previous skills');

select is(
  (select headline from public.profiles),
  null,
  'fields missing from the input are cleared'
);

select is(
  (select onboarded_at from public.profiles),
  '2026-01-01T00:00:00Z'::timestamptz,
  'an existing onboarded_at is kept'
);

select throws_ok(
  $$insert into public.profile_entries (kind, title, start_date) values ('experience', 'X', '05/2023')$$,
  '23514',
  null,
  'periods must be YYYY or YYYY-MM'
);

select throws_ok(
  $$insert into public.profile_entries (kind, title, end_date, is_current)
    values ('experience', 'X', '2024', true)$$,
  '23514',
  null,
  'a current entry has no end date'
);

select throws_ok(
  $$insert into public.profile_entries (kind, title) values ('hobby', 'X')$$,
  '23514',
  null,
  'kind is experience or education'
);

-- -------------------------------------------------------------------------------------------------
-- User two sees and changes nothing of user one
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

select is((select count(*) from public.profiles)::int, 0, 'user two cannot see user one''s profile');
select is((select count(*) from public.profile_entries)::int, 0, 'user two cannot see user one''s entries');

select lives_ok(
  $$select public.replace_profile('{"firstName": "Kim", "lastName": "Zwei"}'::jsonb)$$,
  'user two replaces their own profile'
);

reset role;

select is(
  (select count(*) from public.profile_entries where user_id = '11111111-1111-1111-1111-111111111111')::int,
  1,
  'user two''s replace left user one''s entries alone'
);

select is(
  (select count(*) from public.profiles
    where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'))::int,
  2,
  'each user has their own profile row'
);

select * from finish();

rollback;
