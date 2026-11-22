-- Cover letters: "du" or "Sie" as its own choice (suggested from the posting's own wording) and
-- more tones. Before, the tone "personal" also decided whether to use "du".

alter table public.cover_letters
  add column address text not null default 'sie' check (address in ('sie', 'du'));

alter table public.cover_letters drop constraint cover_letters_tone_check;
alter table public.cover_letters add constraint cover_letters_tone_check check (
  tone in ('formal', 'conservative', 'modern', 'personal', 'enthusiastic', 'creative', 'bold')
);

comment on column public.cover_letters.address is
  'Form of address in the letter: "sie" (formal) or "du" (informal).';
