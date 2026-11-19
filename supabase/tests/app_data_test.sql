-- Tests for the application data tables shared by all apps.
--
-- Two accounts stand in for two app users: user one ('1111...') and user two ('2222...'). The tests
-- switch session claims and role to check that RLS keeps each user to their own rows and that child
-- rows cannot point at another user's application.
begin;

create extension if not exists pgtap with schema extensions;

select plan(64);

-- -------------------------------------------------------------------------------------------------
-- Schema, RLS, and role privileges
-- -------------------------------------------------------------------------------------------------

create temporary table app_tables (name text) on commit drop;
insert into app_tables
values
  ('applications'), ('status_events'), ('contacts'), ('notes'), ('appointments'), ('reminders'),
  ('settings');

select has_table('public', name, name || ' exists') from app_tables;

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = ('public.' || name)::regclass),
  name || ' has row level security enabled'
)
  from app_tables;

select table_privs_are('public', name, 'anon', array[]::text[], 'anon has no privileges on ' || name)
  from app_tables;

select table_privs_are(
  'public',
  name,
  'authenticated',
  array['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
  'authenticated may read and write ' || name
)
  from app_tables
 where name <> 'status_events';

select table_privs_are(
  'public',
  'status_events',
  'authenticated',
  array['SELECT'],
  'authenticated may only read status events; the trigger writes them'
);

select col_is_pk('public', 'reminders', array['user_id', 'key'], 'reminder keys are unique per user');
select col_is_pk('public', 'settings', array['user_id', 'key'], 'setting keys are unique per user');

select ok(
  exists (
    select 1
      from pg_catalog.pg_constraint c
     where c.conrelid = ('public.' || name)::regclass
       and c.contype = 'f'
       and c.confrelid = 'public.applications'::regclass
       and c.confdeltype = 'c'
       and array_length(c.conkey, 1) = 2
  ),
  name || ' references its application through (user_id, application_id) with cascade'
)
  from app_tables
 where name not in ('applications', 'settings');

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
-- Anonymous callers are rejected
-- -------------------------------------------------------------------------------------------------

set local role anon;

select throws_ok(
  'select count(*) from public.applications',
  '42501',
  null,
  'anon cannot read applications'
);

reset role;

-- -------------------------------------------------------------------------------------------------
-- User one writes their own data
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select lives_ok(
  $$insert into public.applications (id, company, role, location, applied_at, status)
    values ('app-1', 'Acme', 'Entwicklerin', 'Berlin', '2026-11-01', 'applied')$$,
  'user one creates an application'
);

select is(
  (select user_id from public.applications where id = 'app-1'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'user_id defaults to the caller'
);

select is(
  (select count(*) from public.status_events where application_id = 'app-1')::int,
  1,
  'creating the application recorded its first status event'
);

select lives_ok(
  $$insert into public.contacts (application_id, name) values ('app-1', 'Kim Muster')$$,
  'user one adds a contact'
);

select lives_ok(
  $$insert into public.notes (application_id, body) values ('app-1', 'Erstes Telefonat')$$,
  'user one adds a note'
);

select lives_ok(
  $$insert into public.appointments (application_id, kind, starts_at)
    values ('app-1', 'video', '2026-11-25T10:00:00+01')$$,
  'user one adds an appointment'
);

select lives_ok(
  $$insert into public.reminders (key, application_id, kind, due_at, title, body)
    values ('follow-up:app-1', 'app-1', 'follow-up', '2026-11-12T09:00:00+01', 'Nachhaken', 'Acme')$$,
  'user one adds a reminder'
);

select lives_ok(
  $$insert into public.settings (key, value) values ('applications.sort', 'newest')$$,
  'user one stores a setting'
);

select throws_ok(
  $$insert into public.applications (id, user_id, company, role, location, applied_at, status)
    values ('app-x', '22222222-2222-2222-2222-222222222222', 'Acme', 'Dev', 'Berlin',
            '2026-11-01', 'applied')$$,
  '42501',
  null,
  'user one cannot create rows for user two'
);

select throws_ok(
  $$insert into public.applications (company, role, location, applied_at, status)
    values ('Acme', 'Dev', 'Berlin', '2026-11-01', 'unknown')$$,
  '23514',
  null,
  'unknown status values are rejected'
);

select throws_ok(
  $$update public.applications set user_id = '22222222-2222-2222-2222-222222222222'
     where id = 'app-1'$$,
  '42501',
  null,
  'user one cannot move an application to user two'
);

reset role;

-- -------------------------------------------------------------------------------------------------
-- User two sees and changes nothing of user one
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is((select count(*) from public.applications)::int, 0, 'user two sees no applications');
select is((select count(*) from public.status_events)::int, 0, 'user two sees no status events');
select is((select count(*) from public.contacts)::int, 0, 'user two sees no contacts');
select is((select count(*) from public.notes)::int, 0, 'user two sees no notes');
select is((select count(*) from public.appointments)::int, 0, 'user two sees no appointments');
select is((select count(*) from public.reminders)::int, 0, 'user two sees no reminders');
select is((select count(*) from public.settings)::int, 0, 'user two sees no settings');

select throws_ok(
  $$insert into public.notes (application_id, body) values ('app-1', 'fremd')$$,
  '23503',
  null,
  'user two cannot attach a note to user one''s application'
);

select lives_ok(
  $$update public.applications set company = 'Gekapert' where id = 'app-1'$$,
  'updating a foreign application runs but matches no row'
);

select lives_ok(
  $$delete from public.applications where id = 'app-1'$$,
  'deleting a foreign application runs but matches no row'
);

select lives_ok(
  $$insert into public.applications (id, company, role, location, applied_at, status)
    values ('app-2', 'Globex', 'Dev', 'Hamburg', '2026-11-03', 'saved')$$,
  'user two creates their own application'
);

select throws_ok(
  $$insert into public.applications (id, company, role, location, applied_at, status)
    values ('app-1', 'Globex', 'Dev', 'Hamburg', '2026-11-03', 'saved')$$,
  '23505',
  null,
  'application ids are unique across users'
);

reset role;

-- -------------------------------------------------------------------------------------------------
-- User one's data is untouched; deleting an application cascades
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select is(
  (select company from public.applications where id = 'app-1'),
  'Acme',
  'user two could not change user one''s application'
);

select is(
  (select count(*) from public.applications)::int,
  1,
  'user one sees only their own application'
);

select lives_ok(
  $$delete from public.applications where id = 'app-1'$$,
  'user one deletes their application'
);

select is(
  (
    (select count(*) from public.status_events)
    + (select count(*) from public.contacts)
    + (select count(*) from public.notes)
    + (select count(*) from public.appointments)
    + (select count(*) from public.reminders)
  )::int,
  0,
  'child rows are deleted together with the application'
);

reset role;

-- -------------------------------------------------------------------------------------------------
-- Deleting an auth user removes their data
-- -------------------------------------------------------------------------------------------------

delete from auth.users where id = '22222222-2222-2222-2222-222222222222';

select is(
  (
    select count(*)
      from public.applications
     where user_id = '22222222-2222-2222-2222-222222222222'
  )::int,
  0,
  'deleting the auth user removes their applications'
);

select * from finish();

rollback;
