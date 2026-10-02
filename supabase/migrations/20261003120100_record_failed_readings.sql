-- Failed readings, the state of each day of the window and the cinemas to
-- recollect. A failed reading erases the cinema's whole programação, and the
-- site shows the cinema as updating (ADR 0005).

-- The Hermes reports error and incomplete; the database derives outdated.
create type public.reading_failure_type as enum ('error', 'incomplete', 'outdated');

alter table public.readings
  add column failure_type public.reading_failure_type,
  add column reason text check (btrim(reason) <> ''),
  drop constraint readings_success_is_complete,
  add constraint readings_finished_is_complete check (
    status not in ('success', 'failure') or (
      collection_release is not null
      and finished_at is not null
      and sessions_received is not null
      and sessions_discarded is not null
      and sessions_accepted is not null
      and sessions_retained is not null
      and alerts is not null
    )
  ),
  add constraint readings_failure_has_type_and_reason check (
    (status = 'failure') = (failure_type is not null)
    and (failure_type is null) = (reason is null)
  );

comment on column public.readings.sessions_discarded is
  'Sessions outside the window or on a closed day, which no other rule takes into account.';
comment on column public.readings.previous_sessions is
  'Accepted and retained sessions of the cinema''s previous successful reading.';

create index readings_cinema_id_finished_at_idx on public.readings (cinema_id, finished_at desc)
  where status in ('success', 'failure');

-- The cinema's last finished reading up to the given time.
create function private.last_finished_reading(chosen_cinema_id bigint, finished_by timestamptz)
returns table (status public.reading_status, finished_at timestamptz)
language sql
stable
set search_path = ''
as $$
  select reading.status, reading.finished_at
  from public.readings as reading
  where reading.cinema_id = chosen_cinema_id
    and reading.status in ('success', 'failure')
    and reading.finished_at <= finished_by
  order by reading.finished_at desc
  limit 1;
$$;

-- Each session of a reading with what the ingestion does with it. Sessions
-- outside the window and on a closed day are discarded; a session whose
-- proposed TMDB id differs from the top search result is retained.
create function private.reading_sessions(reading jsonb, today date, closed_weekdays smallint[])
returns table (session jsonb, tmdb_id integer, starts_at timestamp, outcome text)
language sql
immutable
set search_path = ''
as $$
  select listed_session.value,
    (listed_movie.value ->> 'tmdb_id')::integer,
    start.at,
    case
      when start.at::date not between today and today + 6 then 'outside_window'
      when extract(isodow from start.at)::smallint = any (closed_weekdays) then 'closed_day'
      when listed_movie.value -> 'tmdb_id' is distinct from listed_movie.value -> 'tmdb_search_top_id'
        then 'retained'
      else 'accepted'
    end
  from jsonb_array_elements(reading -> 'sessions') as listed_session (value)
  join jsonb_array_elements(reading -> 'movies') as listed_movie (value)
    on listed_movie.value ->> 'key' = listed_session.value ->> 'movie_key'
  cross join lateral (select (listed_session.value ->> 'starts_at')::timestamp as at) as start;
$$;

-- An alert, in the format of "Ocorrências". The subject is the type with the
-- cinema, so every alert of the same cinema and type joins one occurrence.
create function private.cinema_alert(type text, cinema_slug text, effect text, text text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'type', type,
    'subject', type || ':' || cinema_slug,
    'effect', effect,
    'text', text
  );
$$;

create function private.counted(amount integer, singular text, plural text)
returns text
language sql
immutable
set search_path = ''
as $$
  select amount || ' ' || case when amount = 1 then singular else plural end;
$$;

-- Records a reading of the reserved cinema. The reading follows the contract,
-- already checked by the ingestion. A successful reading replaces the cinema's
-- whole programação, and a failed one erases it. Returns the result with the
-- alerts to send, or a refusal when the reservation does not allow it or the
-- reading does not fit the database.
create or replace function public.record_reading(
  reading_id uuid,
  collection_release text,
  reading jsonb,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  target record;
  issues jsonb;
  today date;
  last_status public.reading_status;
  last_finished_at timestamptz;
  previous integer;
  movie jsonb;
  entry record;
  new_session_id bigint;
  reported text := record_reading.reading ->> 'status';
  received integer := jsonb_array_length(record_reading.reading -> 'sessions');
  discarded integer := 0;
  closed_day integer := 0;
  closed_dates text;
  retained integer := 0;
  accepted integer := 0;
  failure public.reading_failure_type;
  failure_reason text;
  raised_alerts jsonb := '[]';
begin
  select recorded.id, recorded.status, recorded.started_at, recorded.cinema_id,
    cinema.slug as cinema_slug, cinema.name as cinema_name, cinema.closed_weekdays,
    source.type::text as source_type, city.timezone
  into target
  from public.readings as recorded
  join public.cinemas as cinema on cinema.id = recorded.cinema_id
  join public.cities as city on city.id = cinema.city_id
  join public.sources as source on source.id = recorded.source_id
  where recorded.id = record_reading.reading_id
  for update of recorded;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_reading'));
  end if;
  if target.status <> 'in_progress' then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'reading_closed'));
  end if;
  if private.reservation_expires_at(target.started_at) <= record_reading.reference_time then
    update public.readings set status = 'abandoned' where id = target.id;
    return jsonb_build_object('refusal', jsonb_build_object('code', 'reservation_expired'));
  end if;

  -- An accepted movie the database does not know yet needs its titles from
  -- at least one of the reading's entries for it. A failure reported by the
  -- Hermes accepts no movie.
  select coalesce(jsonb_agg(issue order by position), '[]')
  into issues
  from (
    select 0 as position, jsonb_build_object(
      'path', '/reading/cinema',
      'message', format('A reserva é do cinema %s.', target.cinema_slug)
    ) as issue
    where record_reading.reading ->> 'cinema' is distinct from target.cinema_slug
    union all
    select 1, jsonb_build_object(
      'path', '/reading/source',
      'message', format('A fonte principal do cinema na reserva é %s.', target.source_type)
    )
    where record_reading.reading ->> 'source' is distinct from target.source_type
    union all
    select 1 + listed.position, jsonb_build_object(
      'path', format('/reading/movies/%s/tmdb', listed.position - 1),
      'message', 'Um filme novo precisa do title e do original_title do TMDB.'
    )
    from jsonb_array_elements(record_reading.reading -> 'movies') with ordinality as listed (value, position)
    where reported = 'ok'
      and listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
      and not exists (
        select 1 from public.movies where tmdb_id = (listed.value ->> 'tmdb_id')::integer
      )
      and not exists (
        select 1
        from jsonb_array_elements(record_reading.reading -> 'movies') as other (value)
        where other.value -> 'tmdb_id' = listed.value -> 'tmdb_id'
          and other.value #>> '{tmdb,title}' is not null
          and other.value #>> '{tmdb,original_title}' is not null
      )
  ) as found;

  if jsonb_array_length(issues) > 0 then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'invalid_reading', 'issues', issues));
  end if;

  today := (record_reading.reference_time at time zone target.timezone)::date;

  select last_reading.status, last_reading.finished_at
  into last_status, last_finished_at
  from private.last_finished_reading(target.cinema_id, target.started_at) as last_reading;

  -- The previous reading is the last successful one that finished before this
  -- one started.
  select sessions_accepted + sessions_retained
  into previous
  from public.readings
  where cinema_id = target.cinema_id
    and status = 'success'
    and finished_at <= target.started_at
  order by finished_at desc
  limit 1;

  if reported in ('error', 'incomplete') then
    failure := reported::public.reading_failure_type;
    failure_reason := record_reading.reading ->> 'reason';
  else
    select count(*) filter (where outcome in ('outside_window', 'closed_day')),
      count(*) filter (where outcome = 'closed_day'),
      count(*) filter (where outcome = 'retained'),
      count(*) filter (where outcome = 'accepted')
    into discarded, closed_day, retained, accepted
    from private.reading_sessions(record_reading.reading, today, target.closed_weekdays);

    select string_agg(to_char(day, 'DD/MM'), ', ' order by day)
    into closed_dates
    from (
      select distinct starts_at::date as day
      from private.reading_sessions(record_reading.reading, today, target.closed_weekdays)
      where outcome = 'closed_day'
    ) as closed;

    if accepted + retained = 0 and exists (
      select 1
      from generate_series(0, 6) as day
      where extract(isodow from today + day)::smallint <> all (target.closed_weekdays)
    ) then
      failure := 'outdated';
      failure_reason := 'A leitura não trouxe nenhuma sessão de hoje em diante, '
        || 'e o cinema funciona em algum dia da janela.';
    end if;
  end if;

  delete from public.sessions where cinema_id = target.cinema_id;

  if failure is null then
    for movie in
      select distinct on ((listed.value ->> 'tmdb_id')::integer) listed.value
      from jsonb_array_elements(record_reading.reading -> 'movies') as listed (value)
      where listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
        and listed.value #>> '{tmdb,title}' is not null
        and listed.value #>> '{tmdb,original_title}' is not null
      order by (listed.value ->> 'tmdb_id')::integer
    loop
      if not exists (select 1 from public.movies where tmdb_id = (movie ->> 'tmdb_id')::integer) then
        insert into public.movies (tmdb_id, slug, title, original_title)
        values (
          (movie ->> 'tmdb_id')::integer,
          private.new_movie_slug(movie #>> '{tmdb,title}', (movie ->> 'tmdb_id')::integer),
          movie #>> '{tmdb,title}',
          movie #>> '{tmdb,original_title}'
        );
      end if;
    end loop;

    for entry in
      select listed.session, listed.starts_at, accepted_movie.id as movie_id
      from private.reading_sessions(record_reading.reading, today, target.closed_weekdays) as listed
      join public.movies as accepted_movie on accepted_movie.tmdb_id = listed.tmdb_id
      where listed.outcome = 'accepted'
    loop
      insert into public.sessions (cinema_id, movie_id, reading_id, starts_at, room, audio, format, tags, external_id)
      values (
        target.cinema_id,
        entry.movie_id,
        target.id,
        entry.starts_at,
        entry.session ->> 'room',
        (entry.session ->> 'audio')::public.session_audio,
        (entry.session ->> 'format')::public.session_format,
        array(select jsonb_array_elements_text(entry.session -> 'tags')),
        entry.session ->> 'external_id'
      )
      returning id into new_session_id;

      -- Without the ticket type, the price waits for the pending ticket type.
      insert into public.box_office_prices (session_id, ticket_type, source_ticket, price_cents)
      select new_session_id,
        (price ->> 'kind')::public.ticket_type,
        price ->> 'source_ticket',
        (price ->> 'price_cents')::integer
      from jsonb_array_elements(entry.session -> 'prices') as price
      where price ? 'kind';
    end loop;
  end if;

  -- The first failure of the day opens the occurrence, and the next success
  -- of the cinema resolves it. A failure after another of the same day adds
  -- nothing.
  if failure is not null then
    if last_status is distinct from 'failure'
      or (last_finished_at at time zone target.timezone)::date < today then
      raised_alerts := raised_alerts || private.cinema_alert(
        'collection-failure',
        target.cinema_slug,
        'open',
        format(
          '%s: leitura com falha (%s). Motivo: %s. A programação do cinema foi apagada, e o site mostra "atualizando".',
          target.cinema_name,
          case failure
            when 'error' then 'erro'
            when 'incomplete' then 'leitura incompleta'
            when 'outdated' then 'leitura desatualizada'
          end,
          rtrim(btrim(failure_reason), '.')
        )
      );
    end if;
  elsif last_status = 'failure' then
    raised_alerts := raised_alerts || private.cinema_alert(
      'collection-failure',
      target.cinema_slug,
      'resolve',
      format(
        '%s: a leitura voltou a ter sucesso, com %s.',
        target.cinema_name,
        private.counted(accepted, 'sessão aceita', 'sessões aceitas')
      )
    );
  end if;

  -- More than half of the sessions gone is accepted, but alerted.
  if failure is null and previous > 0 and 2 * (accepted + retained) < previous then
    raised_alerts := raised_alerts || private.cinema_alert(
      'session-drop',
      target.cinema_slug,
      'open',
      format(
        '%s: queda brusca de sessões, de %s na última leitura com sucesso para %s nesta. As sessões foram aceitas.',
        target.cinema_name,
        previous,
        accepted + retained
      )
    );
  end if;

  if closed_day > 0 then
    raised_alerts := raised_alerts || private.cinema_alert(
      'closed-day-session',
      target.cinema_slug,
      'open',
      format(
        '%s: %s em dia sem funcionamento (%s). Confira se os dias de funcionamento do cinema mudaram.',
        target.cinema_name,
        case when closed_day = 1
          then '1 sessão foi descartada'
          else closed_day || ' sessões foram descartadas'
        end,
        closed_dates
      )
    );
  end if;

  update public.readings
  set status = case when failure is null then 'success' else 'failure' end::public.reading_status,
    failure_type = failure,
    reason = failure_reason,
    collection_release = record_reading.collection_release,
    finished_at = record_reading.reference_time,
    sessions_received = received,
    sessions_discarded = discarded,
    sessions_accepted = accepted,
    sessions_retained = retained,
    previous_sessions = previous,
    alerts = raised_alerts
  where id = target.id;

  return jsonb_build_object(
    'reading_id', target.id,
    'result', case when failure is null then 'success' else 'failure' end,
    'sessions', jsonb_build_object(
      'received', received,
      'discarded', discarded,
      'accepted', accepted,
      'retained', retained
    ),
    'alerts', raised_alerts
  ) || case
    when failure is null then '{}'::jsonb
    else jsonb_build_object('failure_type', failure, 'reason', failure_reason)
  end;
end;
$$;

-- For each active cinema and each day of the window, the one state the site
-- shows, in this precedence: updating, when the cinema's last reading failed
-- or it was never read; closed, on a closed day; with sessions; and not
-- announced, when the cinema is open, the reading succeeded and brought no
-- session for the day. The build passes the time it is built for.
create function public.site_cinema_days(reference_time timestamptz default now())
returns table (cinema text, date date, state text)
language sql
stable
set search_path = ''
as $$
  select cinema.slug,
    day.date,
    case
      when last_reading.status is distinct from 'success' then 'updating'
      when extract(isodow from day.date)::smallint = any (cinema.closed_weekdays) then 'closed'
      when exists (
        select 1
        from public.sessions as session
        where session.cinema_id = cinema.id and session.date = day.date
      ) then 'with_sessions'
      else 'not_announced'
    end
  from public.cinemas as cinema
  join public.cities as city on city.id = cinema.city_id
  cross join lateral (
    select (reference_time at time zone city.timezone)::date + offset_days as date
    from generate_series(0, 6) as offset_days
  ) as day
  left join lateral private.last_finished_reading(cinema.id, reference_time) as last_reading on true
  where cinema.active
  order by cinema.slug, day.date;
$$;

-- The cinemas whose last reading of the day failed, until 22h in each city's
-- time zone. From then on, the day's last word is the collection summary.
create function public.recollection_cinemas(reference_time timestamptz default now())
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('cinemas', coalesce(jsonb_agg(cinema.slug order by cinema.slug), '[]'))
  from public.cinemas as cinema
  join public.cities as city on city.id = cinema.city_id
  cross join lateral private.last_finished_reading(cinema.id, reference_time) as last_reading
  where cinema.active
    and last_reading.status = 'failure'
    and (last_reading.finished_at at time zone city.timezone)::date
      = (reference_time at time zone city.timezone)::date
    and (reference_time at time zone city.timezone)::time < time '22:00';
$$;

revoke all on function public.site_cinema_days(timestamptz) from anon, authenticated, public;
revoke all on function public.recollection_cinemas(timestamptz) from anon, authenticated, public;
grant execute on function public.site_cinema_days(timestamptz) to service_role;
grant execute on function public.recollection_cinemas(timestamptz) to service_role;
grant execute on function private.last_finished_reading(bigint, timestamptz) to service_role;
grant execute on function private.reading_sessions(jsonb, date, smallint[]) to service_role;
grant execute on function private.cinema_alert(text, text, text, text) to service_role;
grant execute on function private.counted(integer, text, text) to service_role;
