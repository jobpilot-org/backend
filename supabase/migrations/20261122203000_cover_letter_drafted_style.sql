-- Cover letters: remember the selection (du/Sie, tone, length) the text was written with, so the
-- app can tell after reopening that the selection changed and offer to regenerate.

alter table public.cover_letters add column drafted_style text;

comment on column public.cover_letters.drafted_style is
  'Selection the current text was generated with, as "address|tone|length"; null before the first draft.';
