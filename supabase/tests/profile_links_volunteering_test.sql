-- Tests for volunteering entries, profile_links and replace_profile() with both.
begin;

create extension if not exists pgtap with schema extensions;

select plan(12);

select has_table('public', 'profile_links', 'profile_links exists');

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = 'public.profile_links'::regclass),
  'profile_links has row level security enabled'
);

select table_privs_are('public', 'profile_links', 'anon', array[]::text[], 'anon has no privileges on profile_links');

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

select lives_ok(
  $$select public.replace_profile('{
    "firstName": "Erika", "lastName": "Muster",
    "experience": [{"title": "Entwicklerin", "organization": "Acme"}],
    "volunteering": [{"title": "Jugendtrainerin", "organization": "TSV Musterstadt", "startDate": "2018", "isCurrent": true}],
    "links": [
      {"kind": "github", "url": "https://github.com/erika"},
      {"kind": "linkedin", "url": "https://www.linkedin.com/in/erika", "label": "LinkedIn"}
    ]
  }'::jsonb)$$,
  'replace_profile takes volunteering and links'
);

select results_eq(
  $$select kind, title from public.profile_entries order by kind$$,
  $$values ('experience', 'Entwicklerin'), ('volunteer', 'Jugendtrainerin')$$,
  'volunteering is stored as entry kind volunteer'
);

select results_eq(
  $$select position, kind, url, label from public.profile_links order by position$$,
  $$values (0, 'github', 'https://github.com/erika', null::text),
           (1, 'linkedin', 'https://www.linkedin.com/in/erika', 'LinkedIn')$$,
  'links keep their order'
);

select lives_ok(
  $$select public.replace_profile('{"firstName": "Erika", "lastName": "Muster", "experience": []}'::jsonb)$$,
  'replacing without links'
);

select is(
  (select count(*) from public.profile_links)::int,
  2,
  'links stay when the input has no links key'
);

select is(
  (select count(*) from public.profile_entries where kind = 'volunteer')::int,
  0,
  'volunteering is replaced like the other entries'
);

select throws_ok(
  $$insert into public.profile_links (kind, url) values ('github', 'javascript:alert(1)')$$,
  '23514',
  null,
  'only http(s) links'
);

-- User two ---------------------------------------------------------------------------------------

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is((select count(*) from public.profile_links)::int, 0, 'user two sees none of user one''s links');

delete from public.profile_links;

reset role;

select is(
  (select count(*) from public.profile_links where user_id = '11111111-1111-1111-1111-111111111111')::int,
  2,
  'user two cannot delete user one''s links'
);

select * from finish();

rollback;
