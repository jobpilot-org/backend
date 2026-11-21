-- Tests for public.documents and the storage bucket "documents".
--
-- User one ('1111...') and user two ('2222...') check that RLS and the storage policies keep each
-- user to their own documents and files, that a document can only be assigned to the user's own CV
-- station, and the rules for the application photo.
begin;

create extension if not exists pgtap with schema extensions;

select plan(24);

-- -------------------------------------------------------------------------------------------------
-- Schema, RLS, and role privileges
-- -------------------------------------------------------------------------------------------------

select has_table('public', 'documents', 'documents exists');

select ok(
  (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = 'public.documents'::regclass),
  'documents has row level security enabled'
);

select table_privs_are('public', 'documents', 'anon', array[]::text[], 'anon has no privileges on documents');

select is(
  (select public from storage.buckets where id = 'documents'),
  false,
  'bucket documents is private'
);

select is(
  (select file_size_limit from storage.buckets where id = 'documents'),
  10485760::bigint,
  'bucket documents allows at most 10 MB per file'
);

-- -------------------------------------------------------------------------------------------------
-- Test accounts and CV stations
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

insert into public.profile_entries (id, user_id, kind, title, organization)
values
  ('entry-one', '11111111-1111-1111-1111-111111111111', 'experience', 'Entwickler', 'Increon'),
  ('entry-two', '22222222-2222-2222-2222-222222222222', 'experience', 'Entwicklerin', 'Acme');

-- -------------------------------------------------------------------------------------------------
-- User one
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select lives_ok(
  $$insert into public.documents (id, kind, title, file_name, mime_type, size_bytes, storage_path, profile_entry_id)
    values ('doc-one', 'reference', 'Arbeitszeugnis Increon', 'zeugnis.pdf', 'application/pdf', 1000,
            '11111111-1111-1111-1111-111111111111/doc-one/zeugnis.pdf', 'entry-one')$$,
  'user one stores a reference assigned to their own station'
);

select is(
  (select user_id from public.documents where id = 'doc-one'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'user_id comes from auth.uid()'
);

select throws_ok(
  $$insert into public.documents (kind, title, file_name, mime_type, size_bytes, storage_path, profile_entry_id)
    values ('reference', 'Fremd', 'x.pdf', 'application/pdf', 1000,
            '11111111-1111-1111-1111-111111111111/x/x.pdf', 'entry-two')$$,
  '23503',
  null,
  'a document cannot be assigned to another user''s station'
);

select throws_ok(
  $$insert into public.documents (kind, title, file_name, mime_type, size_bytes, storage_path)
    values ('other', 'Fremder Ordner', 'x.pdf', 'application/pdf', 1000,
            '22222222-2222-2222-2222-222222222222/x/x.pdf')$$,
  '23514',
  null,
  'the storage path must start with the user''s own folder'
);

select throws_ok(
  $$insert into public.documents (kind, title, file_name, mime_type, size_bytes, storage_path)
    values ('other', 'Zu groß', 'x.pdf', 'application/pdf', 20000000,
            '11111111-1111-1111-1111-111111111111/big/x.pdf')$$,
  '23514',
  null,
  'files over 10 MB are rejected'
);

select throws_ok(
  $$insert into public.documents (kind, title, file_name, mime_type, size_bytes, storage_path)
    values ('photo', 'Foto als PDF', 'foto.pdf', 'application/pdf', 1000,
            '11111111-1111-1111-1111-111111111111/p/foto.pdf')$$,
  '23514',
  null,
  'the photo must be an image'
);

select lives_ok(
  $$insert into public.documents (id, kind, title, file_name, mime_type, size_bytes, storage_path)
    values ('photo-one', 'photo', 'Bewerbungsfoto', 'foto.jpg', 'image/jpeg', 1000,
            '11111111-1111-1111-1111-111111111111/photo-one/foto.jpg')$$,
  'user one stores a photo'
);

select throws_ok(
  $$insert into public.documents (kind, title, file_name, mime_type, size_bytes, storage_path)
    values ('photo', 'Zweites Foto', 'foto2.jpg', 'image/jpeg', 1000,
            '11111111-1111-1111-1111-111111111111/p2/foto2.jpg')$$,
  '23505',
  null,
  'at most one photo per user'
);

select throws_ok(
  $$update public.documents set profile_entry_id = 'entry-one' where id = 'photo-one'$$,
  '23514',
  null,
  'the photo cannot be assigned to a station'
);

select lives_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values ('documents', '11111111-1111-1111-1111-111111111111/doc-one/zeugnis.pdf',
            '11111111-1111-1111-1111-111111111111')$$,
  'user one uploads into their own folder'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values ('documents', '22222222-2222-2222-2222-222222222222/x/fremd.pdf',
            '11111111-1111-1111-1111-111111111111')$$,
  '42501',
  null,
  'user one cannot upload into another user''s folder'
);

-- Deleting the station keeps the document and only clears the assignment
select lives_ok(
  $$delete from public.profile_entries where id = 'entry-one'$$,
  'user one deletes the station'
);

select results_eq(
  $$select id, profile_entry_id from public.documents where id = 'doc-one'$$,
  $$values ('doc-one', null::text)$$,
  'the document stays, unassigned'
);

-- -------------------------------------------------------------------------------------------------
-- User two
-- -------------------------------------------------------------------------------------------------

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is((select count(*) from public.documents)::int, 0, 'user two sees none of user one''s documents');

select is(
  (select count(*) from storage.objects where bucket_id = 'documents')::int,
  0,
  'user two sees none of user one''s files'
);

update public.documents set title = 'Gekapert' where id = 'doc-one';
-- Direct DELETE on storage.objects is blocked by Supabase anyway; the policy shows on UPDATE
update storage.objects set metadata = '{"gekapert": true}' where bucket_id = 'documents';

select lives_ok(
  $$insert into public.documents (kind, title, file_name, mime_type, size_bytes, storage_path, profile_entry_id)
    values ('reference', 'Zeugnis Acme', 'acme.pdf', 'application/pdf', 1000,
            '22222222-2222-2222-2222-222222222222/acme/acme.pdf', 'entry-two')$$,
  'user two stores their own reference'
);

reset role;

select is(
  (select title from public.documents where id = 'doc-one'),
  'Arbeitszeugnis Increon',
  'user two cannot change user one''s document'
);

select is(
  (select metadata from storage.objects where bucket_id = 'documents'),
  null,
  'user two cannot change user one''s file'
);

select is(
  (select count(*) from public.documents where user_id = '22222222-2222-2222-2222-222222222222')::int,
  1,
  'user two has one document'
);

select * from finish();

rollback;
