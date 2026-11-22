-- Tests for public.cover_letters.
begin;

create extension if not exists pgtap with schema extensions;

select plan(15);

select has_table('public', 'cover_letters', 'cover_letters exists');

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = 'public.cover_letters'::regclass),
  'cover_letters has row level security enabled'
);

select table_privs_are('public', 'cover_letters', 'anon', array[]::text[], 'anon has no privileges on cover_letters');

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'user-one@example.com', now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'user-two@example.com', now(), now());

insert into public.job_postings (id, user_id, company, role)
values
  ('p1', '11111111-1111-1111-1111-111111111111', 'Acme', 'Dev'),
  ('p2', '22222222-2222-2222-2222-222222222222', 'Beta', 'Dev');
insert into public.applications (id, user_id, company, role, location, applied_at, status)
values ('a1', '11111111-1111-1111-1111-111111111111', 'Acme', 'Dev', '', '2026-11-22', 'applied');

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select lives_ok(
  $$insert into public.cover_letters (id, posting_id, salutation, subject, sections)
    values ('c1', 'p1', 'Guten Tag,', 'Bewerbung als Dev',
            '[{"key": "intro", "text": "Einstieg"}, {"key": "closing", "text": "Schluss"}]')$$,
  'user one writes a cover letter for a posting'
);

select lives_ok(
  $$update public.cover_letters set address = 'du', tone = 'bold' where id = 'c1'$$,
  'address and the new tones are accepted'
);

select throws_ok(
  $$update public.cover_letters set address = 'ihr' where id = 'c1'$$,
  '23514',
  null,
  'only du or Sie'
);

select throws_ok(
  $$insert into public.cover_letters (posting_id) values ('p1')$$,
  '23505',
  null,
  'one letter per posting'
);

select throws_ok(
  $$insert into public.cover_letters (salutation) values ('ohne Bezug')$$,
  '23514',
  null,
  'a letter needs a posting or an application'
);

select throws_ok(
  $$insert into public.cover_letters (posting_id) values ('p2')$$,
  '23503',
  null,
  'a letter cannot point to another user''s posting'
);

select lives_ok(
  $$update public.cover_letters set application_id = 'a1' where id = 'c1'$$,
  'the letter moves along to the application'
);

select lives_ok(
  $$delete from public.job_postings where id = 'p1'$$,
  'user one deletes the posting'
);

select results_eq(
  $$select posting_id, application_id from public.cover_letters where id = 'c1'$$,
  $$values (null::text, 'a1')$$,
  'the letter stays with the application'
);

select lives_ok(
  $$delete from public.applications where id = 'a1'$$,
  'deleting the last reference is not blocked by the letter'
);

select is((select count(*) from public.cover_letters)::int, 0, 'the orphaned letter is gone');

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is((select count(*) from public.cover_letters)::int, 0, 'user two sees none of user one''s letters');

select * from finish();

rollback;
