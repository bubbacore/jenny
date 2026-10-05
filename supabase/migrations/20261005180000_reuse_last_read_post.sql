-- The posts read on the official sites. A reading of a post keeps the post
-- it read, with the link and the date, and the showtimes the post brought. A
-- reading without a new post comes without movies or sessions, and the
-- ingestion reuses the showtimes of the cinema's last post read, with the
-- usual rules: once they have no session from today on, the reading is
-- outdated. The source of a post is the source of its reading.

-- post_showtimes keeps the movies and the sessions as the post brought them,
-- so a reading without a new post also takes the resolutions made since then.
-- reused_reading_id is the reading of the last post read whose showtimes a
-- reading without a new post reused.
alter table public.readings
  add column post_url text check (btrim(post_url) <> ''),
  add column post_published_at timestamptz,
  add column post_showtimes jsonb check (jsonb_typeof(post_showtimes) = 'object'),
  add column no_new_post boolean not null default false,
  add column reused_reading_id uuid references public.readings,
  add constraint readings_post_is_complete check (
    (post_url is null) = (post_published_at is null)
    and (post_url is null) = (post_showtimes is null)
  ),
  add constraint readings_no_new_post_reuses_a_post check (
    no_new_post = (reused_reading_id is not null)
    and not (no_new_post and post_url is not null)
  );

create index readings_cinema_id_last_post_idx on public.readings (cinema_id, finished_at desc)
  where post_url is not null;
create index readings_reused_reading_id_idx on public.readings (reused_reading_id);

-- The cinema's last post read up to the given time, in any of its readings
-- that finished, with the source type of the reading.
create function private.last_read_post(chosen_cinema_id bigint, read_by timestamptz)
returns table (
  reading_id uuid,
  source_type public.source_type,
  url text,
  published_at timestamptz,
  showtimes jsonb
)
language sql
stable
set search_path = ''
as $$
  select reading.id, source.type, reading.post_url, reading.post_published_at, reading.post_showtimes
  from public.readings as reading
  join public.sources as source on source.id = reading.source_id
  where reading.cinema_id = chosen_cinema_id
    and reading.post_url is not null
    and reading.finished_at <= read_by
  order by reading.finished_at desc
  limit 1;
$$;

-- Records a reading of the reserved cinema. The reading follows the contract,
-- already checked by the ingestion. A successful reading replaces the
-- cinema's whole showtimes, and a failed one erases them. A reading without a
-- new post takes the showtimes of the last post read. The movies it accepts
-- enter the catalog, with the source values, and the source tickets of its
-- accepted sessions are recorded before their prices. Returns the result with
-- the alerts to send, or a refusal when the reservation does not allow it or
-- the reading does not fit the database.
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
  reuses_post boolean := coalesce(record_reading.reading -> 'no_new_post' = 'true'::jsonb, false);
  last_post_reading_id uuid;
  last_post_url text;
  last_post_showtimes jsonb;
  received integer;
  discarded integer := 0;
  closed_day integer := 0;
  closed_dates text;
  retained integer := 0;
  accepted integer := 0;
  failure public.reading_failure_type;
  failure_reason text;
  raised_alerts jsonb := '[]';
  identification_alerts jsonb := '[]';
  ticket_alerts jsonb := '[]';
begin
  select recorded.id, recorded.status, recorded.started_at, recorded.cinema_id, recorded.source_id,
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

  -- A reading without a new post carries the showtimes of the last post read,
  -- read before this reading started.
  if reuses_post then
    select last_post.reading_id, last_post.url, last_post.showtimes
    into last_post_reading_id, last_post_url, last_post_showtimes
    from private.last_read_post(target.cinema_id, target.started_at) as last_post;
  end if;

  effective := private.with_resolved_source_titles(
    record_reading.reading || coalesce(last_post_showtimes, '{}'),
    target.cinema_id
  );
  received := jsonb_array_length(effective -> 'sessions');

  -- An accepted movie the database does not know yet needs its titles from
  -- at least one of the reading's entries for it, and every image the reading
  -- cites must have been recorded. A failure reported by the Hermes accepts
  -- no movie.
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

  if reported = 'ok' then
    issues := issues || private.unrecorded_images(effective);
  end if;

  -- The movies of reused showtimes are not in the request. One of them may
  -- still lack what TMDB brings, when a resolution chose a movie outside the
  -- catalog after the post was read; only a new reading of the post brings it.
  if reuses_post and last_post_reading_id is null then
    issues := issues || jsonb_build_array(jsonb_build_object(
      'path', '/reading/no_new_post',
      'message', 'O cinema não tem post lido para reaproveitar. Leia o post mais recente.'
    ));
  elsif reuses_post and exists (
    select 1 from jsonb_array_elements(issues) as listed (issue)
    where listed.issue ->> 'path' like '/reading/movies/%'
  ) then
    select coalesce(jsonb_agg(listed.issue order by listed.position), '[]')
      || jsonb_build_array(jsonb_build_object(
        'path', '/reading/no_new_post',
        'message', format(
          'A programação do último post lido, em %s, tem um filme que ainda não está no acervo e que ela não traz completo. Leia o post de novo.',
          last_post_url
        )
      ))
    into issues
    from jsonb_array_elements(issues) with ordinality as listed (issue, position)
    where listed.issue ->> 'path' not like '/reading/movies/%';
  end if;

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
      failure_reason := case
        when reuses_post then 'A programação do último post lido não tem mais nenhuma sessão '
          || 'de hoje em diante, e o cinema funciona em algum dia da janela.'
        else 'A leitura não trouxe nenhuma sessão de hoje em diante, '
          || 'e o cinema funciona em algum dia da janela.'
      end;
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

  -- The accepted movies enter the catalog with what the source informed about
  -- them, before their sessions.
  if failure is null then
    perform private.record_reading_movies(
      effective,
      target.id,
      target.source_id,
      record_reading.reference_time
    );

    ticket_alerts := private.record_source_tickets(
      effective,
      today,
      target.closed_weekdays,
      target.source_type::public.source_type,
      target.cinema_name,
      record_reading.reference_time
    );

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

      perform private.record_session_prices(
        new_session_id,
        entry.session -> 'prices',
        target.source_type::public.source_type
      );
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

  raised_alerts := raised_alerts || identification_alerts || ticket_alerts;

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
    alerts = raised_alerts,
    post_url = record_reading.reading #>> '{post,url}',
    post_published_at = (record_reading.reading #>> '{post,published_at}')::timestamptz,
    post_showtimes = case
      when record_reading.reading ? 'post' then jsonb_build_object(
        'movies', record_reading.reading -> 'movies',
        'sessions', record_reading.reading -> 'sessions'
      )
    end,
    no_new_post = reuses_post,
    reused_reading_id = last_post_reading_id
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

-- The plan also returns, for each cinema, the last post read, with the source
-- type, the link and the date, or null when no reading read a post. A post
-- more recent than it is a new post.
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
        ),
        'last_read_post', (
          select jsonb_build_object(
            'source', last_post.source_type,
            'url', last_post.url,
            'published_at', last_post.published_at
          )
          from private.last_read_post(cinema.id, reference_time) as last_post
        )
      )
      order by cinema.slug
    ), '[]'),
    'known_movies',
    (
      select coalesce(jsonb_agg(
        jsonb_build_object('tmdb_id', movie.tmdb_id, 'missing', private.missing_movie_fields(movie))
        order by movie.tmdb_id
      ), '[]')
      from public.movies as movie
    )
  )
  from public.cinemas as cinema
  join public.cities as city on city.id = cinema.city_id
  join public.sources as source on source.cinema_id = cinema.id and source.active
  where cinema.active
    and (cinema_slugs is null or cinema.slug = any (cinema_slugs));
$$;

grant execute on function private.last_read_post(bigint, timestamptz) to service_role;
