-- A reading is born when the Hermes reserves a cinema and ends when the
-- ingestion records it. Readings of the same cinema never run at the same
-- time: at most one is in progress, and a reservation left behind expires
-- after 30 minutes, so it never locks the cinema.

create type public.reading_status as enum ('in_progress', 'abandoned', 'success');

-- previous_sessions holds the accepted sessions of the cinema's previous
-- successful reading. sessions_discarded counts the sessions outside the
-- window, which no rule takes into account.
create table public.readings (
  id uuid primary key default gen_random_uuid(),
  cinema_id bigint not null references public.cinemas,
  source_id bigint not null references public.sources,
  status public.reading_status not null default 'in_progress',
  collection_release text check (collection_release ~ '^v[0-9]+\.[0-9]+\.[0-9]+$'),
  started_at timestamptz not null,
  finished_at timestamptz,
  sessions_received integer check (sessions_received >= 0),
  sessions_discarded integer check (sessions_discarded >= 0),
  sessions_accepted integer check (sessions_accepted >= 0),
  sessions_retained integer check (sessions_retained >= 0),
  previous_sessions integer check (previous_sessions >= 0),
  alerts jsonb check (jsonb_typeof(alerts) = 'array'),
  constraint readings_success_is_complete check (
    status <> 'success' or (
      collection_release is not null
      and finished_at is not null
      and sessions_received is not null
      and sessions_discarded is not null
      and sessions_accepted is not null
      and sessions_retained is not null
      and alerts is not null
    )
  )
);

create unique index readings_one_in_progress_per_cinema on public.readings (cinema_id)
  where status = 'in_progress';
create index readings_cinema_id_started_at_idx on public.readings (cinema_id, started_at);
create index readings_source_id_idx on public.readings (source_id);

alter table public.readings enable row level security;
revoke all on public.readings from anon, authenticated;

create function private.reservation_expires_at(started_at timestamptz)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select started_at + interval '30 minutes';
$$;

-- Reserves the cinema for a reading. Returns the reading, or a refusal when
-- the cinema is unknown or inactive or another reading is in progress.
create function public.start_reading(cinema_slug text, reference_time timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  chosen record;
  reading record;
begin
  select cinema.id as cinema_id, source.id as source_id
  into chosen
  from public.cinemas as cinema
  join public.sources as source on source.cinema_id = cinema.id and source.active
  where cinema.slug = cinema_slug and cinema.active;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_cinema'));
  end if;

  update public.readings
  set status = 'abandoned'
  where cinema_id = chosen.cinema_id
    and status = 'in_progress'
    and private.reservation_expires_at(started_at) <= reference_time;

  begin
    insert into public.readings (cinema_id, source_id, started_at)
    values (chosen.cinema_id, chosen.source_id, reference_time)
    returning id, started_at into reading;
  exception when unique_violation then
    return jsonb_build_object('refusal', jsonb_build_object(
      'code', 'reading_in_progress',
      'expires_at', (
        select private.reservation_expires_at(started_at)
        from public.readings
        where cinema_id = chosen.cinema_id and status = 'in_progress'
      )
    ));
  end;

  return jsonb_build_object(
    'reading_id', reading.id,
    'cinema', cinema_slug,
    'expires_at', private.reservation_expires_at(reading.started_at)
  );
end;
$$;

revoke all on function public.start_reading(text, timestamptz) from anon, authenticated, public;
grant execute on function public.start_reading(text, timestamptz) to service_role;
grant execute on function private.reservation_expires_at(timestamptz) to service_role;
