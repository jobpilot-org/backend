-- Tests for the trigger that records status history on public.applications.
--
-- One account ('3333...') creates and changes an application; a second ('4444...') checks that
-- foreign history stays hidden. Clients must not be able to write status_events themselves.
begin;

create extension if not exists pgtap with schema extensions;

select plan(17);

select has_trigger(
  'public', 'applications', 'applications_log_status_event', 'status trigger exists'
);

select function_privs_are(
  'public',
  'applications_log_status_event',
  array[]::text[],
  'authenticated',
  array[]::text[],
  'clients cannot call the trigger function directly'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values
  (
    '33333333-3333-3333-3333-333333333333',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'user-three@example.com',
    now(),
    now()
  ),
  (
    '44444444-4444-4444-4444-444444444444',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'user-four@example.com',
    now(),
    now()
  );

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"33333333-3333-3333-3333-333333333333"}',
  true
);

set local role authenticated;

-- Creating an application logs `null -> status` at created_at
insert into public.applications (id, company, role, location, applied_at, status, created_at)
values ('trg-1', 'Acme', 'Dev', 'Berlin', '2026-11-01', 'applied', '2026-11-01T08:00:00Z');

select results_eq(
  $$select from_status, to_status, at, user_id
      from public.status_events where application_id = 'trg-1'$$,
  $$values (null::text, 'applied'::text, '2026-11-01T08:00:00Z'::timestamptz,
            '33333333-3333-3333-3333-333333333333'::uuid)$$,
  'creating an application records null -> status at created_at for the owner'
);

-- Changing other fields logs nothing
update public.applications set company = 'Acme GmbH', priority = 'high' where id = 'trg-1';

select is(
  (select count(*) from public.status_events where application_id = 'trg-1')::int,
  1,
  'updates without a status change add no event'
);

-- Setting the same status logs nothing
update public.applications set status = 'applied' where id = 'trg-1';

select is(
  (select count(*) from public.status_events where application_id = 'trg-1')::int,
  1,
  'setting the unchanged status adds no event'
);

-- A real change logs `old -> new`
update public.applications set status = 'screening' where id = 'trg-1';

select results_eq(
  $$select from_status, to_status from public.status_events
     where application_id = 'trg-1' order by id$$,
  $$values (null::text, 'applied'::text), ('applied', 'screening')$$,
  'a status change records old -> new'
);

select is(
  (select at from public.status_events where application_id = 'trg-1' and to_status = 'screening'),
  now(),
  'a status change is recorded at the time of the change'
);

update public.applications set status = 'interview', next_step = 'Vorbereiten' where id = 'trg-1';

select is(
  (select count(*) from public.status_events where application_id = 'trg-1')::int,
  3,
  'each status change adds exactly one event'
);

-- Archiving keeps the history; restoring adds nothing
update public.applications set archived_at = now() where id = 'trg-1';
update public.applications set archived_at = null where id = 'trg-1';

select is(
  (select count(*) from public.status_events where application_id = 'trg-1')::int,
  3,
  'archiving and restoring do not touch the history'
);

-- Clients cannot write the history themselves
select throws_ok(
  $$insert into public.status_events (application_id, from_status, to_status)
    values ('trg-1', 'interview', 'offer')$$,
  '42501',
  null,
  'clients cannot insert status events'
);

select throws_ok(
  $$update public.status_events set to_status = 'offer' where application_id = 'trg-1'$$,
  '42501',
  null,
  'clients cannot rewrite status events'
);

select throws_ok(
  $$delete from public.status_events where application_id = 'trg-1'$$,
  '42501',
  null,
  'clients cannot delete status events'
);

select throws_ok(
  $$select public.applications_log_status_event()$$,
  '42501',
  null,
  'clients cannot execute the trigger function'
);

select throws_ok(
  $$update public.applications set status = 'unknown' where id = 'trg-1'$$,
  '23514',
  null,
  'an invalid status is rejected before anything is logged'
);

reset role;

-- Another user sees none of it
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"44444444-4444-4444-4444-444444444444"}',
  true
);

set local role authenticated;

select is(
  (select count(*) from public.status_events)::int,
  0,
  'another user sees no foreign status events'
);

update public.applications set status = 'offer' where id = 'trg-1';

reset role;

select is(
  (select status from public.applications where id = 'trg-1'),
  'interview',
  'another user cannot change the status'
);

select is(
  (select count(*) from public.status_events where application_id = 'trg-1')::int,
  3,
  'a blocked foreign update records no event'
);

select * from finish();

rollback;
