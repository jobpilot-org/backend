-- Sources of a job posting: the same posting is often found on a job portal (Indeed, StepStone …)
-- and on the company's own career page – with different details (title, salary, contact person,
-- application e-mail or link). Each place the user saved it from is one row in
-- `job_posting_sources`; the posting's own columns are derived from its sources by a trigger:
-- per field the first non-empty value from the company page, otherwise from the newest source.
-- Salary min/max always come together from the same source.
--
-- New on the posting: `apply_email` and `apply_url` (how to apply). Existing postings get their
-- current data as their first source.

alter table public.job_postings
  add column apply_email text,
  add column apply_url text;

comment on column public.job_postings.apply_email is 'E-mail address for applications (from the sources).';
comment on column public.job_postings.apply_url is 'Link to apply, e.g. "Jetzt bewerben" on the company page.';

create table public.job_posting_sources (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  posting_id text not null,
  kind text not null check (kind in ('portal', 'company')),
  source text,
  url text,
  company text,
  role text,
  location text,
  work_mode text check (work_mode in ('remote', 'hybrid', 'onsite')),
  salary_min integer,
  salary_max integer,
  job_description text,
  contact_name text,
  contact_email text,
  apply_email text,
  apply_url text,
  captured_at timestamptz not null default now(),
  foreign key (user_id, posting_id) references public.job_postings (user_id, id) on delete cascade,
  check (salary_min is null or salary_max is null or salary_min <= salary_max)
);

comment on table public.job_posting_sources is
  'Where a job posting was saved from (job portal or company page) with the details found there.';

create index job_posting_sources_posting_idx on public.job_posting_sources (user_id, posting_id);

alter table public.job_posting_sources enable row level security;
revoke all on table public.job_posting_sources from anon, authenticated;
grant select, insert, update, delete on table public.job_posting_sources to authenticated;
create policy "Users manage their own rows" on public.job_posting_sources for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Derives the posting's columns from its sources (company page first, then newest). Without
-- sources the posting keeps its values. Runs as the caller, so RLS applies.
create function public.refresh_job_posting(p_user_id uuid, p_posting_id text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.job_posting_sources
    where user_id = p_user_id and posting_id = p_posting_id
  ) then
    return;
  end if;

  update public.job_postings p set
    company = coalesce((
      select nullif(s.company, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.company, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.company),
    role = coalesce((
      select nullif(s.role, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.role, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.role),
    location = coalesce((
      select nullif(s.location, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.location, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.location),
    work_mode = coalesce((
      select s.work_mode from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and s.work_mode is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.work_mode),
    source = coalesce((
      select nullif(s.source, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.source, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.source),
    job_url = coalesce((
      select nullif(s.url, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.url, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.job_url),
    job_description = coalesce((
      select nullif(s.job_description, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.job_description, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.job_description),
    contact_name = coalesce((
      select nullif(s.contact_name, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.contact_name, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.contact_name),
    contact_email = coalesce((
      select nullif(s.contact_email, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.contact_email, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.contact_email),
    apply_email = coalesce((
      select nullif(s.apply_email, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.apply_email, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.apply_email),
    apply_url = coalesce((
      select nullif(s.apply_url, '') from public.job_posting_sources s
      where s.user_id = p.user_id and s.posting_id = p.id and nullif(s.apply_url, '') is not null
      order by (s.kind = 'company') desc, s.captured_at desc
      limit 1
    ), p.apply_url),
    salary_min = best_salary.salary_min,
    salary_max = best_salary.salary_max
  from (
    select s.salary_min, s.salary_max
    from public.job_posting_sources s
    where s.user_id = p_user_id and s.posting_id = p_posting_id
    order by (s.salary_min is not null or s.salary_max is not null) desc,
      (s.kind = 'company') desc, s.captured_at desc
    limit 1
  ) as best_salary
  where p.user_id = p_user_id and p.id = p_posting_id;
end;
$$;

revoke all on function public.refresh_job_posting(uuid, text) from public, anon;
grant execute on function public.refresh_job_posting(uuid, text) to authenticated;

create function public.job_posting_sources_refresh()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.refresh_job_posting(old.user_id, old.posting_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.refresh_job_posting(new.user_id, new.posting_id);
  end if;
  return null;
end;
$$;

create trigger job_posting_sources_refresh
  after insert or update or delete on public.job_posting_sources
  for each row execute function public.job_posting_sources_refresh();

revoke all on function public.job_posting_sources_refresh() from public, anon, authenticated;

-- Existing postings: their current data becomes the first source
insert into public.job_posting_sources (
  user_id, posting_id, kind, source, url, company, role, location, work_mode, salary_min,
  salary_max, job_description, contact_name, contact_email, captured_at
)
select
  user_id, id,
  case
    when job_url ~* '(indeed|stepstone|linkedin|xing|monster|jobware|arbeitsagentur|glassdoor|kununu|stellenanzeigen|jobs\.de)'
      then 'portal'
    else 'company'
  end,
  source, job_url, company, role, location, work_mode, salary_min, salary_max, job_description,
  contact_name, contact_email, created_at
from public.job_postings;
