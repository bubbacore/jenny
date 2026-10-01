-- The database has no public read. The anon role (publishable key) and the
-- authenticated role never get privileges on anything in the public schema.
-- Only service_role, used by the ingestion and by the site build through
-- their own secret keys, reaches the tables and views.

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated, public;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated, public;

-- Helper functions live in private, a schema the Data API does not expose.
create schema private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

-- In Supabase, views ignore row level security unless they run with the
-- privileges of the caller. Refuse any view in public without it.
create function private.require_security_invoker_views()
returns event_trigger
language plpgsql
set search_path = ''
as $$
declare
  command record;
begin
  for command in
    select objid, object_identity
    from pg_event_trigger_ddl_commands()
    where object_type = 'view' and schema_name = 'public'
  loop
    if not exists (
      select 1
      from pg_class
      where oid = command.objid
        and reloptions && array['security_invoker=true', 'security_invoker=on']
    ) then
      raise exception 'a visão % precisa de security_invoker = true', command.object_identity;
    end if;
  end loop;
end;
$$;

revoke all on function private.require_security_invoker_views() from anon, authenticated, public;

create event trigger require_security_invoker_views
  on ddl_command_end
  when tag in ('CREATE VIEW', 'ALTER VIEW')
  execute function private.require_security_invoker_views();
