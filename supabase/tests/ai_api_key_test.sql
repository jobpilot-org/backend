-- Tests for per-user AI API key storage in Supabase Vault.
--
-- Two accounts stand in for two app users: user one ('1111...') and user two ('2222...').
-- Keys are decrypted through the caller-scoped `public.get_ai_api_key()`, which derives the user
-- from `auth.uid()`; the tests therefore always switch the session claims and the role.
begin;

create extension if not exists pgtap with schema extensions;

select plan(62);

-- -------------------------------------------------------------------------------------------------
-- Schema, RLS, and role privileges
-- -------------------------------------------------------------------------------------------------

select has_table('public', 'ai_api_keys', 'credential metadata table exists');

select columns_are(
  'public',
  'ai_api_keys',
  array['user_id', 'secret_id', 'created_at', 'updated_at'],
  'credential metadata holds a Vault reference and timestamps but no key material'
);

select col_is_pk('public', 'ai_api_keys', 'user_id', 'each user has at most one settings row');

select ok(
  exists (
    select 1
      from pg_catalog.pg_constraint c
     where c.conrelid = 'public.ai_api_keys'::regclass
       and c.contype = 'f'
       and c.confrelid = 'auth.users'::regclass
       and c.confdeltype = 'c'
  ),
  'settings rows are removed together with the owning auth user'
);

select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.ai_api_keys'::regclass),
  'row level security is enabled'
);

select policies_are(
  'public',
  'ai_api_keys',
  array['Users read their own AI API key metadata'],
  'only a read policy exists, so clients cannot write credential rows'
);

select table_privs_are(
  'public', 'ai_api_keys', 'anon', array[]::text[], 'anon has no privileges on credential metadata'
);

select table_privs_are(
  'public',
  'ai_api_keys',
  'authenticated',
  array['SELECT'],
  'authenticated may only select credential metadata'
);

select ok(
  not has_table_privilege('anon', 'vault.secrets', 'select'),
  'anon cannot read vault.secrets'
);

select ok(
  not has_table_privilege('authenticated', 'vault.secrets', 'select'),
  'authenticated cannot read vault.secrets'
);

select ok(
  not has_table_privilege('anon', 'vault.decrypted_secrets', 'select'),
  'anon cannot read vault.decrypted_secrets'
);

select ok(
  not has_table_privilege('authenticated', 'vault.decrypted_secrets', 'select'),
  'authenticated cannot read vault.decrypted_secrets'
);

select function_privs_are(
  'public',
  'save_ai_api_key',
  array['text'],
  'authenticated',
  array['EXECUTE'],
  'authenticated may execute the save function'
);

select function_privs_are(
  'public',
  'delete_ai_api_key',
  array[]::text[],
  'authenticated',
  array['EXECUTE'],
  'authenticated may execute the delete function'
);

select function_privs_are(
  'public',
  'get_ai_api_key',
  array[]::text[],
  'authenticated',
  array['EXECUTE'],
  'authenticated may execute the caller-scoped decryption function'
);

select function_privs_are(
  'public',
  'get_ai_api_key',
  array[]::text[],
  'service_role',
  array[]::text[],
  'no role decrypts keys on behalf of another user'
);

select ok(
  not exists (
    select 1
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = 'get_ai_api_key'
       and p.pronargs <> 0
  ),
  'the decryption function takes no user id, so it cannot address another account'
);

select function_privs_are(
  'public',
  'ai_api_keys_delete_vault_secret',
  array[]::text[],
  'authenticated',
  array[]::text[],
  'authenticated may not execute the cleanup trigger function'
);

select ok(
  not has_function_privilege('anon', 'public.save_ai_api_key(text)', 'execute'),
  'anon cannot execute the save function'
);

select ok(
  not has_function_privilege('anon', 'public.get_ai_api_key()', 'execute'),
  'anon cannot execute the decryption function'
);

select ok(
  p.prosecdef and 'search_path=""' = any(p.proconfig),
  'the cleanup trigger function is security definer with a pinned search_path'
)
from pg_catalog.pg_proc p
where p.oid = 'public.ai_api_keys_delete_vault_secret()'::regprocedure;

select ok(
  p.prosecdef and 'search_path=""' = any(p.proconfig),
  'save_ai_api_key is security definer with a pinned search_path'
)
from pg_catalog.pg_proc p
where p.oid = 'public.save_ai_api_key(text)'::regprocedure;

select ok(
  p.prosecdef and 'search_path=""' = any(p.proconfig),
  'delete_ai_api_key is security definer with a pinned search_path'
)
from pg_catalog.pg_proc p
where p.oid = 'public.delete_ai_api_key()'::regprocedure;

select ok(
  p.prosecdef and 'search_path=""' = any(p.proconfig),
  'get_ai_api_key is security definer with a pinned search_path'
)
from pg_catalog.pg_proc p
where p.oid = 'public.get_ai_api_key()'::regprocedure;

-- -------------------------------------------------------------------------------------------------
-- Test accounts
-- -------------------------------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values
  (
    '11111111-1111-1111-1111-111111111111',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'user-one@example.com',
    now(),
    now()
  ),
  (
    '22222222-2222-2222-2222-222222222222',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'user-two@example.com',
    now(),
    now()
  );

-- -------------------------------------------------------------------------------------------------
-- Anonymous callers are rejected everywhere
-- -------------------------------------------------------------------------------------------------

set local role anon;

select throws_ok(
  'select count(*) from public.ai_api_keys',
  '42501',
  null,
  'anon cannot read credential metadata'
);

select throws_ok(
  $$select public.save_ai_api_key('sk-ant-api03-anon-key')$$,
  '42501',
  null,
  'anon cannot save a key'
);

select throws_ok(
  $$select public.delete_ai_api_key()$$,
  '42501',
  null,
  'anon cannot delete a key'
);

reset role;

-- -------------------------------------------------------------------------------------------------
-- Authenticated role without a session user is rejected as well
-- -------------------------------------------------------------------------------------------------

select set_config('request.jwt.claims', '{"role":"authenticated"}', true);

set local role authenticated;

select throws_ok(
  $$select public.save_ai_api_key('sk-ant-api03-without-session')$$,
  '42501',
  null,
  'a session without a user cannot save a key'
);

select throws_ok(
  $$select public.delete_ai_api_key()$$,
  '42501',
  null,
  'a session without a user cannot delete a key'
);

reset role;

-- -------------------------------------------------------------------------------------------------
-- User one saves a key; validation and ownership come from auth.uid()
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select throws_ok(
  $$select public.save_ai_api_key(null)$$,
  '22023',
  null,
  'a null key is rejected'
);

select throws_ok(
  $$select public.save_ai_api_key('   ')$$,
  '22023',
  null,
  'a blank key is rejected'
);

select lives_ok(
  $$select public.save_ai_api_key('sk-ant-api03-user-one-key')$$,
  'user one saves a key'
);

select is(
  (select count(*) from public.ai_api_keys)::int,
  1,
  'user one sees exactly one settings row'
);

select is(
  (select user_id from public.ai_api_keys),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'user one only sees their own settings row'
);

-- -------------------------------------------------------------------------------------------------
-- User two is isolated from user one
-- -------------------------------------------------------------------------------------------------

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is(
  (select count(*) from public.ai_api_keys)::int,
  0,
  'user two cannot see user one credentials'
);

select lives_ok(
  $$select public.save_ai_api_key('sk-ant-api03-user-two-key')$$,
  'user two saves a key'
);

select is(
  (select count(*) from public.ai_api_keys)::int,
  1,
  'user two sees exactly one settings row'
);

select is(
  (select user_id from public.ai_api_keys),
  '22222222-2222-2222-2222-222222222222'::uuid,
  'user two only sees their own settings row'
);

-- -------------------------------------------------------------------------------------------------
-- User one still sees only their own row and cannot write it directly
-- -------------------------------------------------------------------------------------------------

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select is(
  (select count(*) from public.ai_api_keys)::int,
  1,
  'user one is unaffected by user two credentials'
);

select is(
  (select user_id from public.ai_api_keys),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'user one still sees only their own settings row'
);

select throws_ok(
  $$update public.ai_api_keys set secret_id = gen_random_uuid()$$,
  '42501',
  null,
  'clients cannot update credential rows directly'
);

select throws_ok(
  $$insert into public.ai_api_keys (user_id, secret_id)
    values ('11111111-1111-1111-1111-111111111111', gen_random_uuid())$$,
  '42501',
  null,
  'clients cannot insert credential rows directly'
);

select throws_ok(
  'delete from public.ai_api_keys',
  '42501',
  null,
  'clients cannot delete credential rows directly'
);

-- -------------------------------------------------------------------------------------------------
-- The caller-scoped function decrypts only the caller's own key
-- -------------------------------------------------------------------------------------------------

select is(
  public.get_ai_api_key(),
  'sk-ant-api03-user-one-key',
  'user one decrypts their own key while user two also has one stored'
);

reset role;

select set_config(
  'jobpilot_test.user_one_secret_id',
  (
    select secret_id::text
      from public.ai_api_keys
     where user_id = '11111111-1111-1111-1111-111111111111'
  ),
  true
);

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"22222222-2222-2222-2222-222222222222"}',
  true
);

set local role authenticated;

select is(
  public.get_ai_api_key(),
  'sk-ant-api03-user-two-key',
  'user two decrypts their own key'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"33333333-3333-3333-3333-333333333333"}',
  true
);

set local role authenticated;

select is(
  public.get_ai_api_key(),
  null::text,
  'a caller without stored credentials gets null'
);

reset role;

select ok(
  (
    select position('sk-ant-api03-user-one-key' in s.secret) = 0
      from vault.secrets s
     where s.id = current_setting('jobpilot_test.user_one_secret_id')::uuid
  ),
  'Vault stores ciphertext instead of the plaintext key'
);

select is(
  (
    select count(*)
      from vault.secrets
     where name = 'jobpilot-ai-api-key-11111111-1111-1111-1111-111111111111'
  )::int,
  1,
  'user one owns exactly one Vault secret'
);

select is(
  (
    select count(*)
      from vault.secrets
     where name = 'jobpilot-ai-api-key-22222222-2222-2222-2222-222222222222'
  )::int,
  1,
  'user two owns exactly one Vault secret'
);

-- -------------------------------------------------------------------------------------------------
-- Replacing a key keeps one settings row and one Vault secret
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select lives_ok(
  $$select public.save_ai_api_key('sk-ant-api03-user-one-key-rotated')$$,
  'user one replaces the key'
);

select is(
  (select count(*) from public.ai_api_keys)::int,
  1,
  'replacing keeps a single settings row'
);

select is(
  (select secret_id::text from public.ai_api_keys),
  current_setting('jobpilot_test.user_one_secret_id'),
  'replacing reuses the same Vault secret'
);

reset role;

set local role authenticated;

select is(
  public.get_ai_api_key(),
  'sk-ant-api03-user-one-key-rotated',
  'the caller reads the replaced key'
);

reset role;

select is(
  (
    select count(*)
      from vault.secrets
     where name = 'jobpilot-ai-api-key-11111111-1111-1111-1111-111111111111'
  )::int,
  1,
  'replacing key material leaves no additional Vault secret behind'
);

-- -------------------------------------------------------------------------------------------------
-- Deleting credentials removes metadata and Vault secret
-- -------------------------------------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"11111111-1111-1111-1111-111111111111"}',
  true
);

set local role authenticated;

select lives_ok(
  $$select public.delete_ai_api_key()$$,
  'user one deletes the key'
);

select is(
  (select count(*) from public.ai_api_keys)::int,
  0,
  'deleting removes the settings row'
);

select lives_ok(
  $$select public.delete_ai_api_key()$$,
  'deleting again stays idempotent'
);

reset role;

select is(
  (
    select count(*)
      from vault.secrets
     where id = current_setting('jobpilot_test.user_one_secret_id')::uuid
  )::int,
  0,
  'deleting removes the Vault secret'
);

set local role authenticated;

select is(
  public.get_ai_api_key(),
  null::text,
  'a deleted key no longer decrypts'
);

reset role;

-- -------------------------------------------------------------------------------------------------
-- Deleting the auth user removes metadata and Vault secret through the cascade
-- -------------------------------------------------------------------------------------------------

delete from auth.users where id = '22222222-2222-2222-2222-222222222222';

select is(
  (
    select count(*)
      from public.ai_api_keys
     where user_id = '22222222-2222-2222-2222-222222222222'
  )::int,
  0,
  'deleting the auth user removes the settings row'
);

select is(
  (
    select count(*)
      from vault.secrets
     where name = 'jobpilot-ai-api-key-22222222-2222-2222-2222-222222222222'
  )::int,
  0,
  'deleting the auth user removes the Vault secret'
);

select is(
  (select count(*) from public.ai_api_keys)::int,
  0,
  'no credential metadata is left after both users are gone'
);

select * from finish();

rollback;
