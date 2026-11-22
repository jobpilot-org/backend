-- Tests for public.job_postings.
--
-- User one ('1111...') and user two ('2222...') check RLS, that a posting can only link to the
-- user's own application, at most once, and that deleting the application only clears the link.
begin;

create extension if not exists pgtap with schema extensions;

select plan(17);

select has_table('public', 'job_postings', 'job_postings exists');

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = 'public.job_postings'::regclass),
  'job_postings has row level security enabled'
);

select table_privs_are(
  'public', 'job_postings', 'anon', array[]::text[], 'anon has no privileges on job_postings'
);

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

insert into public.applications (id, user_id, company, role, location, applied_at, status)
values
  ('app-one', '11111111-1111-1111-1111-111111111111', 'Acme', 'Dev', '', '2026-11-22', 'applied'),
  ('app-two', '22222222-2222-2222-2222-222222222222', 'Beta', 'Dev', '', '2026-11-22', 'applied');

-- User one ---------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select lives_ok(
  $$insert into public.job_postings (id, company, role, job_url, contact_name)
    values ('posting-one', 'Acme', 'Senior Dev', 'https://acme.example/job/1', 'Frau Muster')$$,
  'user one saves a job posting'
);

select is(
  (select user_id from public.job_postings where id = 'posting-one'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'user_id comes from auth.uid()'
);

select throws_ok(
  $$insert into public.job_postings (company, role) values ('', 'Dev')$$,
  '23514',
  null,
  'company is required'
);

select throws_ok(
  $$update public.job_postings set application_id = 'app-two' where id = 'posting-one'$$,
  '23503',
  null,
  'a posting cannot link to another user''s application'
);

select lives_ok(
  $$update public.job_postings set application_id = 'app-one' where id = 'posting-one'$$,
  'user one links the posting to their application'
);

select throws_ok(
  $$insert into public.job_postings (company, role, application_id) values ('Acme', 'Dev', 'app-one')$$,
  '23505',
  null,
  'at most one posting per application'
);

select lives_ok(
  $$update public.job_postings
      set fit_score = 82, fit_result = '{"level": "hoch"}', fit_profile_hash = 'p1', fit_posting_hash = 'j1'
    where id = 'posting-one'$$,
  'user one stores a fit assessment'
);

select throws_ok(
  $$update public.job_postings set fit_score = 120 where id = 'posting-one'$$,
  '23514',
  null,
  'fit_score stays between 0 and 100'
);

select isnt(
  (select updated_at from public.job_postings where id = 'posting-one'),
  null,
  'updated_at is set'
);

select lives_ok(
  $$delete from public.applications where id = 'app-one'$$,
  'user one deletes the application'
);

select results_eq(
  $$select id, application_id from public.job_postings where id = 'posting-one'$$,
  $$values ('posting-one', null::text)$$,
  'the posting stays and is open again'
);

-- User two ---------------------------------------------------------------------------------------

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is((select count(*) from public.job_postings)::int, 0, 'user two sees none of user one''s postings');

update public.job_postings set role = 'Gekapert';
delete from public.job_postings;

reset role;

select is(
  (select role from public.job_postings where id = 'posting-one'),
  'Senior Dev',
  'user two cannot change user one''s posting'
);

select is(
  (select count(*) from public.job_postings)::int,
  1,
  'user two cannot delete user one''s posting'
);

select * from finish();

rollback;
