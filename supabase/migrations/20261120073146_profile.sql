-- Profile (CV data) of each user, shared by all jobpilot apps.
--
-- - `profiles`: one row per user with personal data, headline and summary. `onboarded_at` is set
--   once the user has chosen how to fill their profile (assistant, PDF import, profile page), so
--   the apps show the welcome page only after the first login.
-- - `profile_entries`: CV stations. Work experience and education share one shape (period, title,
--   organization, location, description) and differ only in `kind`.
-- - `profile_skills`: skill groups such as "Frontend: React, Next.js".
-- - `profile_languages`: languages with level.
--
-- Periods are text in the form `YYYY` or `YYYY-MM`, because CVs often name only the year.
-- `is_current` stands for "seit …" / "bis heute"; an end date is then not allowed.
-- `position` orders the rows within a list; the apps write 0, 1, 2 … in display order.
-- `replace_profile(jsonb)` replaces the whole profile in one transaction (PDF import, assistant).

create table public.profiles (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  first_name text not null default '',
  last_name text not null default '',
  headline text,
  street text,
  postal_code text,
  city text,
  phone text,
  email text,
  birth_date date,
  birth_place text,
  summary text,
  onboarded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Personal data and summary of the user''s CV; one row per user.';
comment on column public.profiles.onboarded_at is
  'Set once the user has picked a way to fill the profile; the welcome page is shown until then.';

create table public.profile_entries (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('experience', 'education')),
  position integer not null default 0,
  title text not null check (title <> ''),
  organization text,
  location text,
  description text,
  start_date text check (start_date ~ '^\d{4}(-(0[1-9]|1[0-2]))?$'),
  end_date text check (end_date ~ '^\d{4}(-(0[1-9]|1[0-2]))?$'),
  is_current boolean not null default false,
  created_at timestamptz not null default now(),
  check (not (is_current and end_date is not null))
);

comment on table public.profile_entries is
  'CV stations: work experience and education. Periods are YYYY or YYYY-MM.';
comment on column public.profile_entries.description is
  'Free text; one line per bullet point.';

create index profile_entries_user_id_kind_position_idx
  on public.profile_entries (user_id, kind, position);

create table public.profile_skills (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  position integer not null default 0,
  category text,
  items text not null check (items <> ''),
  created_at timestamptz not null default now()
);

comment on table public.profile_skills is
  'Skill groups of the CV, e.g. category "Frontend" with items "React, Next.js".';

create index profile_skills_user_id_position_idx on public.profile_skills (user_id, position);

create table public.profile_languages (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  position integer not null default 0,
  language text not null check (language <> ''),
  level text,
  created_at timestamptz not null default now()
);

comment on table public.profile_languages is 'Languages of the CV with level, e.g. "Englisch – verhandlungssicher".';

create index profile_languages_user_id_position_idx on public.profile_languages (user_id, position);

create function public.profiles_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.profiles_set_updated_at();

revoke all on function public.profiles_set_updated_at() from public, anon, authenticated;

do $$
declare
  t text;
begin
  foreach t in array array['profiles', 'profile_entries', 'profile_skills', 'profile_languages']
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

-- Replaces the caller's whole profile in one transaction. The input uses the field names of the
-- apps' domain type (`src/domain/profile.ts`, camelCase). Runs as the caller (security invoker),
-- so RLS still applies; `user_id` comes from `auth.uid()`, never from the input. `onboarded_at`
-- is kept if set, otherwise set now.
create function public.replace_profile(profile jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  insert into public.profiles (
    user_id, first_name, last_name, headline, street, postal_code, city, phone, email,
    birth_date, birth_place, summary, onboarded_at
  )
  values (
    v_user_id,
    coalesce(profile ->> 'firstName', ''),
    coalesce(profile ->> 'lastName', ''),
    nullif(profile ->> 'headline', ''),
    nullif(profile ->> 'street', ''),
    nullif(profile ->> 'postalCode', ''),
    nullif(profile ->> 'city', ''),
    nullif(profile ->> 'phone', ''),
    nullif(profile ->> 'email', ''),
    nullif(profile ->> 'birthDate', '')::date,
    nullif(profile ->> 'birthPlace', ''),
    nullif(profile ->> 'summary', ''),
    now()
  )
  on conflict (user_id) do update set
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    headline = excluded.headline,
    street = excluded.street,
    postal_code = excluded.postal_code,
    city = excluded.city,
    phone = excluded.phone,
    email = excluded.email,
    birth_date = excluded.birth_date,
    birth_place = excluded.birth_place,
    summary = excluded.summary,
    onboarded_at = coalesce(public.profiles.onboarded_at, excluded.onboarded_at);

  delete from public.profile_entries where user_id = v_user_id;
  delete from public.profile_skills where user_id = v_user_id;
  delete from public.profile_languages where user_id = v_user_id;

  insert into public.profile_entries (
    user_id, kind, position, title, organization, location, description, start_date, end_date,
    is_current
  )
  select
    v_user_id,
    lists.kind,
    (e.ordinality - 1)::integer,
    e.value ->> 'title',
    nullif(e.value ->> 'organization', ''),
    nullif(e.value ->> 'location', ''),
    nullif(e.value ->> 'description', ''),
    nullif(e.value ->> 'startDate', ''),
    nullif(e.value ->> 'endDate', ''),
    coalesce((e.value ->> 'isCurrent')::boolean, false)
  from (values ('experience', 'experience'), ('education', 'education')) as lists (kind, field)
  cross join lateral jsonb_array_elements(coalesce(profile -> lists.field, '[]'::jsonb))
    with ordinality as e (value, ordinality);

  insert into public.profile_skills (user_id, position, category, items)
  select v_user_id, (s.ordinality - 1)::integer, nullif(s.value ->> 'category', ''), s.value ->> 'items'
  from jsonb_array_elements(coalesce(profile -> 'skills', '[]'::jsonb))
    with ordinality as s (value, ordinality);

  insert into public.profile_languages (user_id, position, language, level)
  select v_user_id, (l.ordinality - 1)::integer, l.value ->> 'language', nullif(l.value ->> 'level', '')
  from jsonb_array_elements(coalesce(profile -> 'languages', '[]'::jsonb))
    with ordinality as l (value, ordinality);
end;
$$;

comment on function public.replace_profile(jsonb) is
  'Replaces the caller''s profile, entries, skills and languages in one transaction.';

revoke all on function public.replace_profile(jsonb) from public, anon;
grant execute on function public.replace_profile(jsonb) to authenticated;
