-- Fit of the user's profile for a job posting, as assessed by the AI (edge function `job-fit`).
--
-- The result is stored on the posting together with hashes of the profile and of the posting text
-- it was computed from. The apps compare these hashes with the current ones: the result is shown as
-- "outdated" (and recomputed only on request) when either has changed – this saves tokens.

alter table public.job_postings
  add column fit_score integer check (fit_score between 0 and 100),
  add column fit_result jsonb,
  add column fit_profile_hash text,
  add column fit_posting_hash text,
  add column fit_model text,
  add column fit_at timestamptz;

comment on column public.job_postings.fit_score is
  'Fit of the profile for this posting, 0–100 (AI); null = not assessed yet.';
comment on column public.job_postings.fit_result is
  'Full fit assessment: level, summary, pros, cons, prognosis, what to emphasize.';
comment on column public.job_postings.fit_profile_hash is
  'Hash of the profile the assessment was based on; differs from the current one = outdated.';
comment on column public.job_postings.fit_posting_hash is
  'Hash of the posting text the assessment was based on.';
