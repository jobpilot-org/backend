-- Documents of each user: references (Arbeitszeugnisse), certificates, diplomas, other attachments
-- and one application photo. Shared by all jobpilot apps.
--
-- - The file lives in the private storage bucket `documents` under `<user_id>/<document_id>/<name>`;
--   storage policies limit each user to their own folder. The row in `public.documents` holds the
--   metadata and is written by the app after a successful upload.
-- - `profile_entry_id` assigns a document to a CV station (e.g. the reference from a company to that
--   job). The composite foreign key keeps the assignment within the user's own entries; deleting
--   the entry (also through `replace_profile`) only clears the assignment, the document stays.
-- - At most one photo per user; it must be an image and cannot be assigned to a station.

alter table public.profile_entries
  add constraint profile_entries_user_id_id_key unique (user_id, id);

create table public.documents (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('photo', 'reference', 'certificate', 'diploma', 'other')),
  title text not null check (title <> ''),
  file_name text not null check (file_name <> ''),
  mime_type text not null check (
    mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')
  ),
  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 10485760),
  storage_path text not null unique check (split_part(storage_path, '/', 1) = user_id::text),
  profile_entry_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (user_id, profile_entry_id)
    references public.profile_entries (user_id, id) on delete set null (profile_entry_id),
  check (kind <> 'photo' or mime_type like 'image/%'),
  check (kind <> 'photo' or profile_entry_id is null)
);

comment on table public.documents is
  'Uploaded documents (references, certificates, diplomas, photo); files in storage bucket "documents".';
comment on column public.documents.storage_path is
  'Object name in bucket "documents": <user_id>/<document_id>/<file name>.';
comment on column public.documents.profile_entry_id is
  'CV station the document belongs to, e.g. the reference of that employer; null = unassigned.';

create index documents_user_id_kind_idx on public.documents (user_id, kind);
create index documents_user_id_profile_entry_id_idx on public.documents (user_id, profile_entry_id);
create unique index documents_one_photo_per_user_idx on public.documents (user_id) where kind = 'photo';

create function public.documents_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger documents_set_updated_at
  before update on public.documents
  for each row execute function public.documents_set_updated_at();

revoke all on function public.documents_set_updated_at() from public, anon, authenticated;

alter table public.documents enable row level security;
revoke all on table public.documents from anon, authenticated;
grant select, insert, update, delete on table public.documents to authenticated;
create policy "Users manage their own documents" on public.documents for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Private bucket: files only through the API with the user's token (signed URLs for viewing).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'documents',
  'documents',
  false,
  10485760,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "Users read their own documents" on storage.objects for select to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Users upload their own documents" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Users update their own documents" on storage.objects for update to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'documents' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Users delete their own documents" on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
