-- The database records status history itself instead of every app writing it.
--
-- Inserting an application logs `null -> status` at its `created_at`; changing `status` logs
-- `old -> new` at `now()`. Both happen in the same statement as the change, so history and current
-- status cannot drift apart when a client loses its connection halfway.
--
-- Clients only read `status_events` from now on. The trigger function is `security definer`, so it
-- can write the history although `authenticated` cannot; it always uses the application row's own
-- `user_id`, never a value from the client.

create function public.applications_log_status_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.status_events (user_id, application_id, from_status, to_status, at)
    values (new.user_id, new.id, null, new.status, new.created_at);
  elsif new.status is distinct from old.status then
    insert into public.status_events (user_id, application_id, from_status, to_status, at)
    values (new.user_id, new.id, old.status, new.status, now());
  end if;
  return null;
end;
$$;

comment on function public.applications_log_status_event() is
  'Appends a status_events row when an application is created or its status changes.';

create trigger applications_log_status_event
  after insert or update of status on public.applications
  for each row execute function public.applications_log_status_event();

revoke all on function public.applications_log_status_event() from public, anon, authenticated;

revoke insert, update, delete on table public.status_events from authenticated;
