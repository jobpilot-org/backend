-- Per-user AI API keys, encrypted at rest with Supabase Vault.
--
-- `public.ai_api_keys` only links an auth user to their Vault secret; neither plaintext nor
-- ciphertext key material is stored in that table. Keys are written through
-- `public.save_ai_api_key`, removed through `public.delete_ai_api_key`, and decrypted only by
-- `public.get_ai_api_key()`, which reads the caller's own row via `auth.uid()`. The API server sends
-- the caller's access token and needs no service-role key of its own.
--
-- Vault itself is provisioned by the platform (extension `supabase_vault`, schema `vault`), so the
-- statement below is a no-op on local and hosted projects that already ship it. The `vault` schema
-- stays closed to `anon` and `authenticated`; this migration grants no access there.
create extension if not exists supabase_vault with schema vault;

create table public.ai_api_keys (
  user_id uuid primary key references auth.users (id) on delete cascade,
  secret_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.ai_api_keys is
  'Links a Supabase auth user to the Supabase Vault secret holding their AI API key (Anthropic today).';
comment on column public.ai_api_keys.secret_id is
  'Vault secret id of the encrypted AI API key; the key material itself lives in vault.secrets.';

alter table public.ai_api_keys enable row level security;

-- Deny by default: clients only read their own metadata row and never write credential rows.
revoke all on table public.ai_api_keys from anon, authenticated;
grant select on table public.ai_api_keys to authenticated;

create policy "Users read their own AI API key metadata"
  on public.ai_api_keys
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Delete the Vault secret together with its metadata row, including rows removed by the
-- `on delete cascade` from auth.users.
create function public.ai_api_keys_delete_vault_secret()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from vault.secrets s where s.id = old.secret_id;
  return old;
end;
$$;

comment on function public.ai_api_keys_delete_vault_secret() is
  'Removes the Vault secret of a deleted ai_api_keys row so no orphaned ciphertext remains.';

create trigger ai_api_keys_delete_vault_secret
  after delete on public.ai_api_keys
  for each row execute function public.ai_api_keys_delete_vault_secret();

-- Saves or replaces the calling user's AI API key. The key is encrypted by Vault; only the secret
-- id is persisted here.
create function public.save_ai_api_key(api_key text)
returns table (user_id uuid, created_at timestamptz, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_secret_id uuid;
  v_key text := btrim(api_key);
begin
  if v_user_id is null then
    raise exception 'Saving an AI API key requires an authenticated session.'
      using errcode = '42501';
  end if;

  if v_key is null or v_key = '' then
    raise exception 'The AI API key must not be empty.' using errcode = '22023';
  end if;

  -- Serializes concurrent saves of one user, so a race cannot create a second Vault secret.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));

  select k.secret_id into v_secret_id
    from public.ai_api_keys k
   where k.user_id = v_user_id;

  if v_secret_id is null then
    v_secret_id := vault.create_secret(
      v_key,
      'jobpilot-ai-api-key-' || v_user_id::text,
      'AI API key for the JobPilot user ' || v_user_id::text
    );

    insert into public.ai_api_keys (user_id, secret_id)
    values (v_user_id, v_secret_id);
  else
    perform vault.update_secret(v_secret_id, v_key);

    update public.ai_api_keys k
       set updated_at = now()
     where k.user_id = v_user_id;
  end if;

  return query
    select k.user_id, k.created_at, k.updated_at
      from public.ai_api_keys k
     where k.user_id = v_user_id;
end;
$$;

comment on function public.save_ai_api_key(text) is
  'Stores or replaces the caller''s AI API key as an encrypted Vault secret.';

-- Deletes the calling user's credentials; the delete trigger removes the Vault secret.
create function public.delete_ai_api_key()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Deleting an AI API key requires an authenticated session.'
      using errcode = '42501';
  end if;

  delete from public.ai_api_keys k where k.user_id = v_user_id;
end;
$$;

comment on function public.delete_ai_api_key() is
  'Deletes the caller''s AI API key metadata and, through the delete trigger, the Vault secret.';

-- Returns the caller's own key. The API server sends the caller's access token and uses only the
-- publishable key, so Supabase itself checks that the token belongs to the row being read.
create function public.get_ai_api_key()
returns text
language sql
security definer
set search_path = ''
as $$
  select d.decrypted_secret
    from public.ai_api_keys k
    join vault.decrypted_secrets d on d.id = k.secret_id
   where k.user_id = (select auth.uid());
$$;

comment on function public.get_ai_api_key() is
  'Returns the decrypted AI API key of the calling user, or null when none is stored.';

revoke all on function public.ai_api_keys_delete_vault_secret() from public, anon, authenticated;

revoke all on function public.save_ai_api_key(text) from public, anon;
grant execute on function public.save_ai_api_key(text) to authenticated;

revoke all on function public.delete_ai_api_key() from public, anon;
grant execute on function public.delete_ai_api_key() to authenticated;

-- `service_role` holds EXECUTE through the project's default privileges on new functions; revoke it
-- explicitly so only the caller can decrypt their own key.
revoke all on function public.get_ai_api_key() from public, anon, service_role;
grant execute on function public.get_ai_api_key() to authenticated;
