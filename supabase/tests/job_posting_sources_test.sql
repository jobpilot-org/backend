-- Tests for job_posting_sources and the derived posting columns.
begin;

create extension if not exists pgtap with schema extensions;

select plan(12);

select has_table('public', 'job_posting_sources', 'job_posting_sources exists');

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = 'public.job_posting_sources'::regclass),
  'job_posting_sources has row level security enabled'
);

select table_privs_are(
  'public', 'job_posting_sources', 'anon', array[]::text[], 'anon has no privileges on job_posting_sources'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'user-one@example.com', now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'user-two@example.com', now(), now());

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

insert into public.job_postings (id, company, role)
values ('p1', 'Simple First Consulting GmbH', 'Spezialist KI-Automatisierung & Workflows (m/w/d)');

select lives_ok(
  $$insert into public.job_posting_sources
      (posting_id, kind, source, url, company, role, location, salary_min, salary_max, job_description, captured_at)
    values ('p1', 'portal', 'Indeed', 'https://de.indeed.com/viewjob?jk=abc', 'Simple First Consulting GmbH',
            'Spezialist KI-Automatisierung & Workflows (m/w/d)', 'Homeoffice', 57000, 75000, 'Text von Indeed', now() - interval '1 hour')$$,
  'user one adds the portal source'
);

select results_eq(
  $$select job_url, location, salary_min, salary_max, job_description from public.job_postings where id = 'p1'$$,
  $$values ('https://de.indeed.com/viewjob?jk=abc', 'Homeoffice', 57000, 75000, 'Text von Indeed')$$,
  'the posting takes the values of its only source'
);

select lives_ok(
  $$insert into public.job_posting_sources
      (posting_id, kind, source, url, company, role, salary_min, salary_max, job_description, contact_name, apply_email)
    values ('p1', 'company', 'simple-first.de', 'https://simple-first.de/stellenangebote/ki', 'Simple First',
            'KI- & Digitalisierungsberater - Steuerkanzleien (m/w/d)', 54000, 72000, 'Text der Firmenseite',
            'Julia Illgner', 'bewerbung@simple-first.de')$$,
  'user one adds the company page as a second source'
);

select results_eq(
  $$select role, job_url, location, salary_min, salary_max, job_description, contact_name, apply_email
      from public.job_postings where id = 'p1'$$,
  $$values ('KI- & Digitalisierungsberater - Steuerkanzleien (m/w/d)', 'https://simple-first.de/stellenangebote/ki',
            'Homeoffice', 54000, 72000, 'Text der Firmenseite', 'Julia Illgner', 'bewerbung@simple-first.de')$$,
  'the company page wins; missing fields come from the portal'
);

select lives_ok(
  $$update public.job_posting_sources set salary_min = null, salary_max = null where kind = 'company'$$,
  'user one removes the salary from the company source'
);

select results_eq(
  $$select salary_min, salary_max from public.job_postings where id = 'p1'$$,
  $$values (57000, 75000)$$,
  'salary min and max come together from one source'
);

select lives_ok(
  $$delete from public.job_posting_sources where kind = 'company'$$,
  'user one removes the company source'
);

select is(
  (select role from public.job_postings where id = 'p1'),
  'Spezialist KI-Automatisierung & Workflows (m/w/d)',
  'the posting falls back to the remaining source'
);

-- User two ---------------------------------------------------------------------------------------

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is((select count(*) from public.job_posting_sources)::int, 0, 'user two sees none of user one''s sources');

select * from finish();

rollback;
