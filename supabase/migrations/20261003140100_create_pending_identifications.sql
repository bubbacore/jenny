-- Pending identification and its resolution. A source title whose proposed
-- TMDB id differs from the top search result becomes a pending
-- identification, and its sessions are retained, out of the site. The owner
-- resolves it by choosing the movie, and the resolution is remembered for that
-- source title in that cinema.

-- Case, accents and repeated spaces do not tell two source titles apart.
create function private.normalized_source_title(title text)
returns text
language sql
stable
set search_path = ''
as $$
  select lower(extensions.unaccent(
    'extensions.unaccent'::regdictionary,
    regexp_replace(btrim(title), '\s+', ' ', 'g')
  ));
$$;

create type public.pending_identification_status as enum ('pending', 'resolved');

-- source_title, the proposal, the top search result and the reason are the
-- ones of the last appearance. A source title has at most one pending
-- identification per cinema, and the resolved ones stay as history.
create table public.pending_identifications (
  id uuid primary key default gen_random_uuid(),
  cinema_id bigint not null references public.cinemas,
  source_title text not null check (btrim(source_title) <> ''),
  normalized_source_title text not null check (normalized_source_title <> ''),
  proposed_tmdb_id integer not null check (proposed_tmdb_id > 0),
  search_top_tmdb_id integer check (search_top_tmdb_id > 0),
  reason text not null check (btrim(reason) <> ''),
  status public.pending_identification_status not null default 'pending',
  resolved_tmdb_id integer check (resolved_tmdb_id > 0),
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  resolved_at timestamptz,
  constraint pending_identifications_seen_in_order check (first_seen_at <= last_seen_at),
  constraint pending_identifications_resolution_is_complete check (
    (status = 'resolved') = (resolved_tmdb_id is not null)
    and (resolved_tmdb_id is null) = (resolved_at is null)
  )
);

create unique index pending_identifications_one_pending_per_title
  on public.pending_identifications (cinema_id, normalized_source_title)
  where status = 'pending';

-- The movie chosen for a source title of a cinema. A new resolution of the
-- same source title replaces it.
create table public.resolved_source_titles (
  cinema_id bigint not null references public.cinemas,
  normalized_source_title text not null check (normalized_source_title <> ''),
  source_title text not null check (btrim(source_title) <> ''),
  tmdb_id integer not null check (tmdb_id > 0),
  pending_identification_id uuid not null references public.pending_identifications,
  resolved_at timestamptz not null,
  primary key (cinema_id, normalized_source_title)
);

create index resolved_source_titles_pending_identification_id_idx
  on public.resolved_source_titles (pending_identification_id);

alter table public.pending_identifications enable row level security;
alter table public.resolved_source_titles enable row level security;
revoke all on public.pending_identifications, public.resolved_source_titles from anon, authenticated;

create or replace function private.failure_type_name(type public.reading_failure_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case type
    when 'error' then 'erro'
    when 'incomplete' then 'leitura incompleta'
    when 'outdated' then 'leitura desatualizada'
    when 'retained' then 'leitura retida'
  end;
$$;

-- A resolved source title uses the chosen movie directly, whatever the Hermes
-- proposed. The TMDB data of the entry describe the proposed movie, so they
-- stay only when it is the chosen one.
create function private.with_resolved_source_titles(reading jsonb, chosen_cinema_id bigint)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_set(reading, '{movies}', coalesce(jsonb_agg(
    case
      when resolved.tmdb_id is null then listed.value
      else (
        case
          when (listed.value ->> 'tmdb_id')::integer = resolved.tmdb_id then listed.value
          else listed.value - 'tmdb'
        end
      ) || jsonb_build_object('tmdb_id', resolved.tmdb_id, 'tmdb_search_top_id', resolved.tmdb_id)
    end
    order by listed.position
  ), '[]'))
  from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
  left join public.resolved_source_titles as resolved
    on resolved.cinema_id = chosen_cinema_id
    and resolved.normalized_source_title
      = private.normalized_source_title(listed.value ->> 'source_title');
$$;

-- The subject is the type with the cinema and the normalized source title, so
-- each pending identification has its own occurrence.
create function private.pending_identification_alert(
  cinema_slug text,
  normalized_source_title text,
  effect text,
  text text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'type', 'pending-identification',
    'subject', 'pending-identification:' || cinema_slug || ':' || normalized_source_title,
    'effect', effect,
    'text', text
  );
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
  effective jsonb;
  issues jsonb;
  today date;
  last_status public.reading_status;
  last_finished_at timestamptz;
  previous integer;
  movie jsonb;
  entry record;
  pending record;
  pending_reason text;
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
  identification_alerts jsonb := '[]';
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

  effective := private.with_resolved_source_titles(record_reading.reading, target.cinema_id);

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
    where effective ->> 'cinema' is distinct from target.cinema_slug
    union all
    select 1, jsonb_build_object(
      'path', '/reading/source',
      'message', format('A fonte principal do cinema na reserva é %s.', target.source_type)
    )
    where effective ->> 'source' is distinct from target.source_type
    union all
    select 1 + listed.position, jsonb_build_object(
      'path', format('/reading/movies/%s/tmdb', listed.position - 1),
      'message', 'Um filme novo precisa do title e do original_title do TMDB.'
    )
    from jsonb_array_elements(effective -> 'movies') with ordinality as listed (value, position)
    where reported = 'ok'
      and listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
      and not exists (
        select 1 from public.movies where tmdb_id = (listed.value ->> 'tmdb_id')::integer
      )
      and not exists (
        select 1
        from jsonb_array_elements(effective -> 'movies') as other (value)
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
    failure_reason := effective ->> 'reason';
  else
    select count(*) filter (where outcome in ('outside_window', 'closed_day')),
      count(*) filter (where outcome = 'closed_day'),
      count(*) filter (where outcome = 'retained'),
      count(*) filter (where outcome = 'accepted')
    into discarded, closed_day, retained, accepted
    from private.reading_sessions(effective, today, target.closed_weekdays);

    select string_agg(to_char(day, 'DD/MM'), ', ' order by day)
    into closed_dates
    from (
      select distinct starts_at::date as day
      from private.reading_sessions(effective, today, target.closed_weekdays)
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
    elsif accepted = 0 and retained > 0 then
      failure := 'retained';
      failure_reason := format(
        'Todas as sessões da leitura ficaram retidas por identificação pendente (%s)',
        private.counted(retained, 'sessão', 'sessões')
      );
    end if;

    -- Each source title with retained sessions is a pending identification.
    -- Only a new one raises the alert; a later appearance updates it.
    for pending in
      select distinct on (titles.normalized) titles.normalized, titles.movie, titles.retained
      from (
        select private.normalized_source_title(listed.value ->> 'source_title') as normalized,
          listed.value as movie,
          (
            select count(*)
            from private.reading_sessions(effective, today, target.closed_weekdays) as listed_session
            where listed_session.outcome = 'retained'
              and listed_session.session ->> 'movie_key' = listed.value ->> 'key'
          )::integer as retained
        from jsonb_array_elements(effective -> 'movies') as listed (value)
      ) as titles
      where titles.retained > 0
      order by titles.normalized, titles.retained desc
    loop
      pending_reason := case
        when pending.movie -> 'tmdb_search_top_id' = 'null'::jsonb then format(
          'A busca no TMDB não trouxe resultado, e o filme proposto foi o TMDB %s.',
          pending.movie ->> 'tmdb_id'
        )
        else format(
          'O filme proposto, o TMDB %s, difere do primeiro resultado da busca no TMDB, o %s.',
          pending.movie ->> 'tmdb_id',
          pending.movie ->> 'tmdb_search_top_id'
        )
      end;

      update public.pending_identifications
      set source_title = pending.movie ->> 'source_title',
        proposed_tmdb_id = (pending.movie ->> 'tmdb_id')::integer,
        search_top_tmdb_id = (pending.movie ->> 'tmdb_search_top_id')::integer,
        reason = pending_reason,
        last_seen_at = greatest(last_seen_at, record_reading.reference_time)
      where cinema_id = target.cinema_id
        and normalized_source_title = pending.normalized
        and status = 'pending';

      if not found then
        insert into public.pending_identifications (
          cinema_id, source_title, normalized_source_title, proposed_tmdb_id,
          search_top_tmdb_id, reason, first_seen_at, last_seen_at
        )
        values (
          target.cinema_id,
          pending.movie ->> 'source_title',
          pending.normalized,
          (pending.movie ->> 'tmdb_id')::integer,
          (pending.movie ->> 'tmdb_search_top_id')::integer,
          pending_reason,
          record_reading.reference_time,
          record_reading.reference_time
        );

        identification_alerts := identification_alerts || private.pending_identification_alert(
          target.cinema_slug,
          pending.normalized,
          'open',
          format(
            '%s: o título na fonte "%s" ficou em identificação pendente, com %s. %s Escolha o filme para liberar as sessões.',
            target.cinema_name,
            pending.movie ->> 'source_title',
            private.counted(pending.retained, 'sessão retida', 'sessões retidas'),
            pending_reason
          )
        );
      end if;
    end loop;
  end if;

  delete from public.sessions where cinema_id = target.cinema_id;

  if failure is null then
    for movie in
      select distinct on ((listed.value ->> 'tmdb_id')::integer) listed.value
      from jsonb_array_elements(effective -> 'movies') as listed (value)
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
      from private.reading_sessions(effective, today, target.closed_weekdays) as listed
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
          private.failure_type_name(failure),
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

  raised_alerts := raised_alerts || identification_alerts;

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

-- Resolves the pending identification of a source title in a cinema with the
-- chosen movie, which the next readings of that source title use directly.
-- Returns the cinema to recollect, so the retained sessions come back, and
-- the alert that resolves the occurrence; or a refusal when the cinema has no
-- pending identification of that source title.
create function public.resolve_pending_identification(
  cinema_slug text,
  source_title text,
  tmdb_id integer,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  pending record;
begin
  select identification.id, identification.cinema_id, identification.source_title,
    identification.normalized_source_title, cinema.slug as cinema_slug, cinema.name as cinema_name
  into pending
  from public.pending_identifications as identification
  join public.cinemas as cinema on cinema.id = identification.cinema_id
  where cinema.slug = resolve_pending_identification.cinema_slug
    and identification.normalized_source_title
      = private.normalized_source_title(resolve_pending_identification.source_title)
    and identification.status = 'pending'
  for update of identification;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_identification'));
  end if;

  update public.pending_identifications
  set status = 'resolved',
    resolved_tmdb_id = resolve_pending_identification.tmdb_id,
    resolved_at = resolve_pending_identification.reference_time
  where id = pending.id;

  insert into public.resolved_source_titles (
    cinema_id, normalized_source_title, source_title, tmdb_id, pending_identification_id, resolved_at
  )
  values (
    pending.cinema_id,
    pending.normalized_source_title,
    pending.source_title,
    resolve_pending_identification.tmdb_id,
    pending.id,
    resolve_pending_identification.reference_time
  )
  on conflict (cinema_id, normalized_source_title) do update
  set source_title = excluded.source_title,
    tmdb_id = excluded.tmdb_id,
    pending_identification_id = excluded.pending_identification_id,
    resolved_at = excluded.resolved_at;

  return jsonb_build_object(
    'recollection_cinema', pending.cinema_slug,
    'alerts', jsonb_build_array(private.pending_identification_alert(
      pending.cinema_slug,
      pending.normalized_source_title,
      'resolve',
      format(
        '%s: o título na fonte "%s" foi ligado ao TMDB %s. O cinema será recoletado para liberar as sessões.',
        pending.cinema_name,
        pending.source_title,
        resolve_pending_identification.tmdb_id
      )
    ))
  );
end;
$$;

-- The plan also returns, for each cinema, the source titles already resolved,
-- which the Hermes sends with the chosen movie.
create or replace function public.collection_plan(cinema_slugs text[] default null, reference_time timestamptz default now())
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'cinemas',
    coalesce(jsonb_agg(
      jsonb_build_object(
        'slug', cinema.slug,
        'name', cinema.name,
        'city', city.slug,
        'timezone', city.timezone,
        'window', (
          select jsonb_agg(to_char((reference_time at time zone city.timezone)::date + day, 'YYYY-MM-DD') order by day)
          from generate_series(0, 6) as day
        ),
        'closed_weekdays', (
          select coalesce(jsonb_agg(
            (array['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'])[weekday]
            order by weekday
          ), '[]')
          from unnest(cinema.closed_weekdays) as weekday
        ),
        'source', jsonb_build_object('type', source.type, 'config', source.config),
        'resolved_source_titles', (
          select coalesce(jsonb_agg(
            jsonb_build_object('source_title', resolved.source_title, 'tmdb_id', resolved.tmdb_id)
            order by resolved.normalized_source_title
          ), '[]')
          from public.resolved_source_titles as resolved
          where resolved.cinema_id = cinema.id
        )
      )
      order by cinema.slug
    ), '[]')
  )
  from public.cinemas as cinema
  join public.cities as city on city.id = cinema.city_id
  join public.sources as source on source.cinema_id = cinema.id and source.active
  where cinema.active
    and (cinema_slugs is null or cinema.slug = any (cinema_slugs));
$$;

revoke all on function public.resolve_pending_identification(text, text, integer, timestamptz)
  from anon, authenticated, public;
grant execute on function public.resolve_pending_identification(text, text, integer, timestamptz)
  to service_role;
grant execute on function private.normalized_source_title(text) to service_role;
grant execute on function private.with_resolved_source_titles(jsonb, bigint) to service_role;
grant execute on function private.pending_identification_alert(text, text, text, text) to service_role;
