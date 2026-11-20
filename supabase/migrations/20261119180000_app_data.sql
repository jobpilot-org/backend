-- Application data shared by all jobpilot apps (mobile, web, admin, desktop, extension).
--
-- Mirrors the local Drizzle schema of mobile-app (`src/db/schema.ts`) so the same domain logic
-- works against either store. Differences to the SQLite version:
--
-- - Every row carries `user_id` (defaults to `auth.uid()`); RLS limits each user to their own rows.
-- - Child tables reference their application through `(user_id, application_id)`, so a row can never
--   point at another user's application, even with a guessed id.
-- - Timestamps are `timestamptz`, calendar days (`applied_at`) are `date`. Clients convert to the
--   ISO strings the domain layer expects.
-- - Ids stay `text`: the apps generate their own ids (`createId()`), which keeps existing local data
--   importable. Inserts without an id get a UUID.
-- - `reminders` and `settings` are keyed per user.
--
-- Allowed values in the check constraints match the constants in mobile-app `src/domain/`.

create table public.applications (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  company text not null,
  role text not null,
  location text not null,
  work_mode text check (work_mode in ('remote', 'hybrid', 'onsite')),
  applied_at date not null,
  status text not null check (
    status in ('saved', 'applied', 'screening', 'interview', 'final', 'offer', 'rejected', 'withdrawn')
  ),
  priority text not null default 'normal' check (priority in ('high', 'normal', 'low')),
  source text,
  job_url text,
  salary_min integer,
  salary_max integer,
  next_step text,
  job_description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (user_id, id),
  check (salary_min is null or salary_max is null or salary_min <= salary_max)
);

comment on table public.applications is 'Job applications; one row per application and user.';
comment on column public.applications.job_description is
  'Text of the job posting, input for the AI assistant.';
comment on column public.applications.archived_at is
  'Set = deleted but restorable (soft delete).';

create index applications_user_id_archived_at_idx on public.applications (user_id, archived_at);

create table public.status_events (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid(),
  application_id text not null,
  from_status text check (
    from_status in ('saved', 'applied', 'screening', 'interview', 'final', 'offer', 'rejected', 'withdrawn')
  ),
  to_status text not null check (
    to_status in ('saved', 'applied', 'screening', 'interview', 'final', 'offer', 'rejected', 'withdrawn')
  ),
  at timestamptz not null default now(),
  foreign key (user_id, application_id)
    references public.applications (user_id, id) on delete cascade
);

comment on table public.status_events is
  'Every status change, including creation (from_status null); basis for timeline and insights.';

create index status_events_user_id_application_id_idx
  on public.status_events (user_id, application_id);

create table public.contacts (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid(),
  application_id text not null,
  name text not null,
  role text,
  email text,
  phone text,
  linkedin_url text,
  created_at timestamptz not null default now(),
  foreign key (user_id, application_id)
    references public.applications (user_id, id) on delete cascade
);

create index contacts_user_id_application_id_idx on public.contacts (user_id, application_id);

create table public.notes (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid(),
  application_id text not null,
  body text not null,
  created_at timestamptz not null default now(),
  foreign key (user_id, application_id)
    references public.applications (user_id, id) on delete cascade
);

create index notes_user_id_application_id_idx on public.notes (user_id, application_id);

create table public.appointments (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid(),
  application_id text not null,
  kind text not null check (kind in ('phone', 'video', 'onsite', 'technical')),
  starts_at timestamptz not null,
  location text,
  notes text,
  created_at timestamptz not null default now(),
  foreign key (user_id, application_id)
    references public.applications (user_id, id) on delete cascade
);

create index appointments_user_id_application_id_idx
  on public.appointments (user_id, application_id);
create index appointments_user_id_starts_at_idx on public.appointments (user_id, starts_at);

create table public.reminders (
  user_id uuid not null default auth.uid(),
  key text not null,
  application_id text not null,
  kind text not null check (
    kind in ('follow-up', 'appointment-day-before', 'appointment-soon', 'thank-you', 'custom')
  ),
  due_at timestamptz not null,
  title text not null,
  body text not null,
  done_at timestamptz,
  snoozed_until timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, key),
  foreign key (user_id, application_id)
    references public.applications (user_id, id) on delete cascade
);

comment on table public.reminders is
  'Source of truth for in-app reminders and notifications; key doubles as the notification id.';

create index reminders_user_id_application_id_idx on public.reminders (user_id, application_id);
create index reminders_user_id_due_at_idx on public.reminders (user_id, due_at);

create table public.settings (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  key text not null,
  value text not null,
  primary key (user_id, key)
);

comment on table public.settings is
  'Small per-user key/value settings such as list filter, sort order or AI profile text.';

-- Keep updated_at current regardless of what the client sends.
create function public.applications_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger applications_set_updated_at
  before update on public.applications
  for each row execute function public.applications_set_updated_at();

revoke all on function public.applications_set_updated_at() from public, anon, authenticated;

-- RLS and privileges: deny by default, `authenticated` works only on their own rows, `anon` gets
-- nothing. The `with check` clause also stops an update from moving a row to another account.
do $$
declare
  t text;
begin
  foreach t in array array[
    'applications', 'status_events', 'contacts', 'notes', 'appointments', 'reminders', 'settings'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format(
      'grant select, insert, update, delete on table public.%I to authenticated', t
    );
    execute format(
      'create policy "Users manage their own rows" on public.%I for all to authenticated '
      'using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)',
      t
    );
  end loop;
end;
$$;
