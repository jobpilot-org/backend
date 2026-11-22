-- Cover letters ("Anschreiben"), bound to a job posting and/or an application – each posting has
-- its own letter, because postings differ. When an application is made from a posting, the
-- letter gets the application id as well (it "moves along").
--
-- The letter is stored in parts so the assistant can suggest and the user can edit each part:
-- salutation, tone and length, the strengths to highlight, subject and sections (JSON array of
-- { key, text } in order). Sender and recipient are not stored: they come from the profile and
-- the posting when the letter is shown.

create table public.cover_letters (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  posting_id text,
  application_id text,
  salutation text not null default '',
  tone text not null default 'modern' check (tone in ('formal', 'modern', 'personal')),
  length text not null default 'medium' check (length in ('short', 'medium')),
  strengths text[] not null default '{}',
  subject text not null default '',
  sections jsonb not null default '[]'::jsonb check (jsonb_typeof(sections) = 'array'),
  closing text not null default 'Mit freundlichen Grüßen',
  model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (user_id, posting_id)
    references public.job_postings (user_id, id) on delete set null (posting_id),
  foreign key (user_id, application_id)
    references public.applications (user_id, id) on delete set null (application_id)
);

comment on table public.cover_letters is
  'Cover letters per job posting / application, stored as salutation, tone, strengths, subject and sections.';
comment on column public.cover_letters.sections is
  'Ordered JSON array of { "key": "intro" | "fit" | "strengths" | "motivation" | "closing", "text": "…" }.';

-- One letter per posting and one per application
create unique index cover_letters_posting_idx
  on public.cover_letters (user_id, posting_id) where posting_id is not null;
create unique index cover_letters_application_idx
  on public.cover_letters (user_id, application_id) where application_id is not null;

create function public.cover_letters_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger cover_letters_set_updated_at
  before update on public.cover_letters
  for each row execute function public.cover_letters_set_updated_at();

revoke all on function public.cover_letters_set_updated_at() from public, anon, authenticated;

-- A letter needs a posting or an application. Not a check constraint: deleting the last one sets
-- the reference to null via the foreign key, and the letter should then go away instead of
-- blocking the delete.
create function public.cover_letters_require_target()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.posting_id is null and new.application_id is null then
    raise exception 'cover letter needs a job posting or an application'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger cover_letters_require_target
  before insert on public.cover_letters
  for each row execute function public.cover_letters_require_target();

create function public.cover_letters_delete_orphan()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  delete from public.cover_letters where id = new.id;
  return null;
end;
$$;

create trigger cover_letters_delete_orphan
  after update of posting_id, application_id on public.cover_letters
  for each row when (new.posting_id is null and new.application_id is null)
  execute function public.cover_letters_delete_orphan();

revoke all on function public.cover_letters_require_target() from public, anon, authenticated;
revoke all on function public.cover_letters_delete_orphan() from public, anon, authenticated;

alter table public.cover_letters enable row level security;
revoke all on table public.cover_letters from anon, authenticated;
grant select, insert, update, delete on table public.cover_letters to authenticated;
create policy "Users manage their own cover letters" on public.cover_letters for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
