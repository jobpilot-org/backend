-- Profile: volunteering (Ehrenamt) and links (social networks, code profiles, website).
--
-- - Volunteering entries are CV stations like work experience and education and share
--   `profile_entries`; they differ only in `kind` = 'volunteer'.
-- - `profile_links`: one row per link with a kind (LinkedIn, XING, GitHub, GitLab, website, other),
--   the URL (http/https only) and an optional label; `position` orders them.
-- - `replace_profile` now also takes `volunteering` and – only when present in the input – `links`,
--   so a CV import keeps volunteering in sync and older callers leave links untouched.

alter table public.profile_entries drop constraint profile_entries_kind_check;
alter table public.profile_entries
  add constraint profile_entries_kind_check check (kind in ('experience', 'education', 'volunteer'));

comment on table public.profile_entries is
  'CV stations: work experience, education and volunteering. Periods are YYYY or YYYY-MM.';

create table public.profile_links (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  position integer not null default 0,
  kind text not null check (kind in ('linkedin', 'xing', 'github', 'gitlab', 'website', 'other')),
  url text not null check (url ~* '^https?://[^\s]+$' and length(url) <= 500),
  label text check (label is null or length(label) <= 100),
  created_at timestamptz not null default now()
);

comment on table public.profile_links is
  'Links of the CV: LinkedIn, XING, GitHub, GitLab, website or other, with optional label.';

create index profile_links_user_id_position_idx on public.profile_links (user_id, position);

alter table public.profile_links enable row level security;
revoke all on table public.profile_links from anon, authenticated;
grant select, insert, update, delete on table public.profile_links to authenticated;
create policy "Users manage their own rows" on public.profile_links for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create or replace function public.replace_profile(profile jsonb)
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
  from (values ('experience', 'experience'), ('education', 'education'), ('volunteer', 'volunteering'))
    as lists (kind, field)
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

  -- Links nur ersetzen, wenn die Eingabe sie mitbringt – ältere Aufrufer lassen sie unberührt
  if profile ? 'links' then
    delete from public.profile_links where user_id = v_user_id;
    insert into public.profile_links (user_id, position, kind, url, label)
    select
      v_user_id,
      (k.ordinality - 1)::integer,
      k.value ->> 'kind',
      k.value ->> 'url',
      nullif(k.value ->> 'label', '')
    from jsonb_array_elements(coalesce(profile -> 'links', '[]'::jsonb)) with ordinality as k (value, ordinality);
  end if;
end;
$$;

comment on function public.replace_profile(jsonb) is
  'Replaces the caller''s profile, entries (incl. volunteering), skills, languages and – if given – links.';
