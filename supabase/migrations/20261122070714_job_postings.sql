-- Job postings ("Stellenangebote") the user has saved, e.g. from the browser extension. A posting is
-- not an application: it becomes one only when the user decides to apply. Shared by all apps.
--
-- - State: open → applied (`application_id` set) or dismissed (`dismissed_at` set, can be reopened).
-- - `application_id` points to the application created from this posting. The composite foreign key
--   keeps it within the user's own applications; deleting the application clears the link only.
--   At most one posting per application.
-- - Contact data from the posting is kept here and copied to `contacts` when the application is made.

create table public.job_postings (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  company text not null check (company <> ''),
  role text not null check (role <> ''),
  location text not null default '',
  work_mode text check (work_mode in ('remote', 'hybrid', 'onsite')),
  salary_min integer,
  salary_max integer,
  source text,
  job_url text,
  job_description text,
  contact_name text,
  contact_email text,
  application_id text,
  dismissed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, id),
  foreign key (user_id, application_id)
    references public.applications (user_id, id) on delete set null (application_id),
  check (salary_min is null or salary_max is null or salary_min <= salary_max)
);

comment on table public.job_postings is
  'Saved job postings; become an application only when the user applies (application_id).';
comment on column public.job_postings.application_id is
  'Application created from this posting; null = not applied (yet).';
comment on column public.job_postings.dismissed_at is
  'Set = the user is not interested; can be reopened.';

create index job_postings_user_id_created_at_idx on public.job_postings (user_id, created_at desc);
create unique index job_postings_application_id_idx
  on public.job_postings (user_id, application_id) where application_id is not null;

create function public.job_postings_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger job_postings_set_updated_at
  before update on public.job_postings
  for each row execute function public.job_postings_set_updated_at();

revoke all on function public.job_postings_set_updated_at() from public, anon, authenticated;

alter table public.job_postings enable row level security;
revoke all on table public.job_postings from anon, authenticated;
grant select, insert, update, delete on table public.job_postings to authenticated;
create policy "Users manage their own job postings" on public.job_postings for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
