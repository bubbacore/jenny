-- Redefines four functions without the plpgsql_check warnings: the variable
-- defaults get explicit casts, and the unused and shadowed variables go away.
-- Signatures, results, permissions and behavior stay the same.

-- Records a reading of the reserved cinema. The reading follows the contract,
-- already checked by the ingestion. A successful reading replaces the
-- cinema's whole showtimes, and a failed one erases them. A reading without a
-- new post takes the showtimes and the period of the last post read. A post
-- reading with a period is outdated once today is past its last day, and
-- one without a period follows the rule of the other sources. The movies it accepts
-- enter the catalog, with the source values, and the source tickets of its
-- accepted sessions are recorded before their prices. The session drop counts
-- only the sessions of the previous successful reading still in the window.
-- A pending identification alerts on its first appearance and on the first
-- reading of each day in which it still retains sessions, naming the
-- proposed movie and the top search result with their TMDB links. The
-- accepted sessions of a source title resolved since the cinema's last
-- reading count as released.
-- Returns the result with the alerts to send, or a refusal when the
-- reservation does not allow it or the reading does not fit the database.
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
  previous_in_window boolean;
  entry record;
  pending record;
  known record;
  pending_reason text;
  pending_links text;
  proposed_movie jsonb;
  new_session_id bigint;
  reported text := record_reading.reading ->> 'status';
  reuses_post boolean := coalesce(record_reading.reading -> 'no_new_post' = 'true'::jsonb, false);
  last_post_reading_id uuid;
  last_post_url text;
  last_post_showtimes jsonb;
  post_last_day date := (record_reading.reading #>> '{post,period,last_day}')::date;
  received integer;
  discarded integer := 0;
  closed_day integer := 0;
  closed_dates text;
  retained integer := 0;
  accepted integer := 0;
  released integer := 0;
  kept_dates date[] := '{}'::date[];
  failure public.reading_failure_type;
  failure_reason text;
  raised_alerts jsonb := '[]'::jsonb;
  identification_alerts jsonb := '[]'::jsonb;
  ticket_alerts jsonb := '[]'::jsonb;
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

  -- A reading without a new post carries the showtimes and the period of the
  -- last post read, read before this reading started.
  if reuses_post then
    select last_post.reading_id, last_post.url, last_post.showtimes, last_post_reading.post_last_day
    into last_post_reading_id, last_post_url, last_post_showtimes, post_last_day
    from private.last_read_post(target.cinema_id, target.started_at) as last_post
    join public.readings as last_post_reading on last_post_reading.id = last_post.reading_id;
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
  -- one started. Only its sessions still in the window count, unless it was
  -- recorded before the session dates were kept.
  select case
      when session_dates is null then sessions_accepted + sessions_retained
      else (
        select count(*)::integer
        from unnest(session_dates) as session_date
        where session_date between today and today + 6
      )
    end,
    session_dates is not null
  into previous, previous_in_window
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

    select coalesce(array_agg(starts_at::date order by starts_at), '{}')
    into kept_dates
    from private.reading_sessions(effective, today, target.closed_weekdays)
    where outcome in ('accepted', 'retained');

    select string_agg(to_char(day, 'DD/MM'), ', ' order by day)
    into closed_dates
    from (
      select distinct starts_at::date as day
      from private.reading_sessions(effective, today, target.closed_weekdays)
      where outcome = 'closed_day'
    ) as closed;

    -- A post with a period is outdated only once the period is over, even
    -- without sessions from today on.
    if post_last_day < today then
      failure := 'outdated';
      failure_reason := format(
        'O período do %s terminou em %s.',
        case when reuses_post then 'último post lido' else 'post lido' end,
        to_char(post_last_day, 'DD/MM')
      );
    elsif post_last_day is null and accepted + retained = 0 and exists (
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
    -- A new one raises the alert, and so does the first appearance of a known
    -- one on a later day, in the city's time zone. Any other appearance only
    -- updates it.
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
          'O filme proposto é %s, mas a busca pelo título na fonte e pelo ano não trouxe resultado.',
          private.tmdb_movie_name(
            (pending.movie ->> 'tmdb_id')::integer,
            pending.movie ->> 'tmdb_title',
            (pending.movie ->> 'tmdb_year')::integer
          )
        )
        else format(
          'O filme proposto é %s, mas o primeiro resultado da busca pelo título na fonte e pelo ano é %s.',
          private.tmdb_movie_name(
            (pending.movie ->> 'tmdb_id')::integer,
            pending.movie ->> 'tmdb_title',
            (pending.movie ->> 'tmdb_year')::integer
          ),
          private.tmdb_movie_name(
            (pending.movie ->> 'tmdb_search_top_id')::integer,
            pending.movie ->> 'tmdb_search_top_title',
            (pending.movie ->> 'tmdb_search_top_year')::integer
          )
        )
      end;
      pending_links := E'\nFilme proposto: ' || private.tmdb_movie_url((pending.movie ->> 'tmdb_id')::integer)
        || coalesce(
          E'\nPrimeiro resultado: '
            || private.tmdb_movie_url((pending.movie ->> 'tmdb_search_top_id')::integer),
          ''
        );
      proposed_movie := jsonb_strip_nulls(jsonb_build_object(
        'tmdb_id', (pending.movie ->> 'tmdb_id')::integer,
        'title', pending.movie ->> 'tmdb_title',
        'year', (pending.movie ->> 'tmdb_year')::integer
      ));

      select identification.id, identification.first_seen_at, identification.last_seen_at
      into known
      from public.pending_identifications as identification
      where identification.cinema_id = target.cinema_id
        and identification.normalized_source_title = pending.normalized
        and identification.status = 'pending'
      for update;

      if found then
        update public.pending_identifications
        set source_title = pending.movie ->> 'source_title',
          proposed_tmdb_id = (pending.movie ->> 'tmdb_id')::integer,
          search_top_tmdb_id = (pending.movie ->> 'tmdb_search_top_id')::integer,
          proposed_title = pending.movie ->> 'tmdb_title',
          proposed_year = (pending.movie ->> 'tmdb_year')::integer,
          search_top_title = pending.movie ->> 'tmdb_search_top_title',
          search_top_year = (pending.movie ->> 'tmdb_search_top_year')::integer,
          reason = pending_reason,
          last_seen_at = greatest(last_seen_at, record_reading.reference_time)
        where id = known.id;

        if (known.last_seen_at at time zone target.timezone)::date < today then
          identification_alerts := identification_alerts || private.pending_identification_alert(
            target.cinema_slug,
            pending.normalized,
            'open',
            format(
              '%s: o título na fonte "%s" continua em identificação pendente desde %s, com %s. %s Aceite o filme proposto ou escolha outro para liberar as sessões.%s',
              target.cinema_name,
              pending.movie ->> 'source_title',
              to_char(known.first_seen_at at time zone target.timezone, 'DD/MM'),
              private.counted(pending.retained, 'sessão retida', 'sessões retidas'),
              pending_reason,
              pending_links
            ),
            proposed_movie
          );
        end if;
      else
        insert into public.pending_identifications (
          cinema_id, source_title, normalized_source_title, proposed_tmdb_id,
          search_top_tmdb_id, proposed_title, proposed_year, search_top_title, search_top_year,
          reason, first_seen_at, last_seen_at
        )
        values (
          target.cinema_id,
          pending.movie ->> 'source_title',
          pending.normalized,
          (pending.movie ->> 'tmdb_id')::integer,
          (pending.movie ->> 'tmdb_search_top_id')::integer,
          pending.movie ->> 'tmdb_title',
          (pending.movie ->> 'tmdb_year')::integer,
          pending.movie ->> 'tmdb_search_top_title',
          (pending.movie ->> 'tmdb_search_top_year')::integer,
          pending_reason,
          record_reading.reference_time,
          record_reading.reference_time
        );

        identification_alerts := identification_alerts || private.pending_identification_alert(
          target.cinema_slug,
          pending.normalized,
          'open',
          format(
            '%s: o título na fonte "%s" ficou em identificação pendente, com %s. %s Aceite o filme proposto ou escolha outro para liberar as sessões.%s',
            target.cinema_name,
            pending.movie ->> 'source_title',
            private.counted(pending.retained, 'sessão retida', 'sessões retidas'),
            pending_reason,
            pending_links
          ),
          proposed_movie
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

    -- The sessions of a source title resolved after the cinema's last reading
    -- were retained there and are released here.
    select count(*)::integer
    into released
    from private.reading_sessions(effective, today, target.closed_weekdays) as listed
    join jsonb_array_elements(effective -> 'movies') as listed_movie (value)
      on listed_movie.value ->> 'key' = listed.session ->> 'movie_key'
    join public.resolved_source_titles as resolved
      on resolved.cinema_id = target.cinema_id
      and resolved.normalized_source_title
        = private.normalized_source_title(listed_movie.value ->> 'source_title')
    where listed.outcome = 'accepted'
      and resolved.resolved_at <= target.started_at
      and (last_finished_at is null or resolved.resolved_at > last_finished_at);
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
        '%s: queda brusca de sessões, de %s na última leitura com sucesso%s para %s nesta. As sessões foram aceitas.',
        target.cinema_name,
        previous,
        case when previous_in_window then ', contando só as que ainda estão na janela,' else '' end,
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
    sessions_released = released,
    previous_sessions = previous,
    session_dates = kept_dates,
    alerts = raised_alerts,
    post_url = record_reading.reading #>> '{post,url}',
    post_published_at = (record_reading.reading #>> '{post,published_at}')::timestamptz,
    post_first_day = (record_reading.reading #>> '{post,period,first_day}')::date,
    post_last_day = (record_reading.reading #>> '{post,period,last_day}')::date,
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

-- Calculates the source reliability from the content ratings informed in the
-- last 8 weeks. For each movie, each source type counts with its most recent
-- value, and a movie is compared when at least two source types inform it,
-- so cinemas of the same source type are never compared with each other.
-- TMDB stays out. When a value is held by more than half of the source types,
-- the divergence counts against the others; without such a majority, against
-- every one of them. A source type's rate is the share of its compared movies
-- in which it diverged. The source types with at least 10 compared movies
-- take, in the initial order, the places of the initial ranking that belong
-- to them, and one moves above its neighbor only when the neighbor's rate is
-- more than 10 percentage points higher. The others keep their place in the
-- initial ranking. When the ranking changes, the movies with source values
-- get their values chosen again, and the alert informs the new ranking.
create or replace function public.update_source_reliability(reference_time timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  initial public.source_type[] := private.initial_source_ranking();
  types integer := array_length(private.initial_source_ranking(), 1);
  counts jsonb;
  compared integer[] := '{}'::integer[];
  divergences integer[] := '{}'::integer[];
  ordered integer[] := '{}'::integer[];
  ranking integer[] := '{}'::integer[];
  previous public.source_type[];
  current_ranking public.source_type[];
  changed boolean;
  new_calculation_id bigint;
  next_eligible integer := 1;
  swap integer;
  held integer;
  affected_movie_id bigint;
  result jsonb;
begin
  with recent as (
    select distinct on (informed.movie_id, source.type) informed.movie_id, source.type, informed.value
    from public.source_values as informed
    join public.sources as source on source.id = informed.source_id
    where informed.data = 'content_rating'
      and informed.informed_at > update_source_reliability.reference_time - interval '8 weeks'
      and informed.informed_at <= update_source_reliability.reference_time
    order by informed.movie_id, source.type, informed.informed_at desc
  ),
  compared_movies as (
    select movie_id, count(*) as types from recent group by movie_id having count(*) >= 2
  ),
  majorities as (
    select recent.movie_id, recent.value
    from recent
    join compared_movies using (movie_id)
    group by recent.movie_id, recent.value, compared_movies.types
    having 2 * count(*) > compared_movies.types
  )
  select coalesce(jsonb_object_agg(per_type.type, jsonb_build_array(per_type.compared, per_type.divergences)), '{}')
  into counts
  from (
    select recent.type,
      count(*) as compared,
      count(*) filter (where majority.value is distinct from recent.value) as divergences
    from recent
    join compared_movies using (movie_id)
    left join majorities as majority using (movie_id)
    group by recent.type
  ) as per_type;

  for slot in 1 .. types loop
    compared := compared || coalesce((counts -> initial[slot]::text ->> 0)::integer, 0);
    divergences := divergences || coalesce((counts -> initial[slot]::text ->> 1)::integer, 0);
  end loop;

  -- The insertion keeps the initial order unless the rates differ by more
  -- than 10 percentage points.
  for slot in 1 .. types loop
    if compared[slot] >= 10 then
      ordered := ordered || slot;
      swap := array_length(ordered, 1);
      while swap > 1
        and divergences[ordered[swap - 1]]::numeric / compared[ordered[swap - 1]]
          - divergences[ordered[swap]]::numeric / compared[ordered[swap]] > 0.10
      loop
        held := ordered[swap - 1];
        ordered[swap - 1] := ordered[swap];
        ordered[swap] := held;
        swap := swap - 1;
      end loop;
    end if;
  end loop;

  for slot in 1 .. types loop
    if compared[slot] >= 10 then
      ranking := ranking || ordered[next_eligible];
      next_eligible := next_eligible + 1;
    else
      ranking := ranking || slot;
    end if;
  end loop;

  select array_agg(source_type order by place) into previous from private.source_ranking();
  select array_agg(initial[type_index] order by position)
  into current_ranking
  from unnest(ranking) with ordinality as ranked (type_index, position);
  changed := current_ranking is distinct from previous;

  insert into public.source_reliability_calculations (calculated_at, changed)
  values (update_source_reliability.reference_time, changed)
  returning id into new_calculation_id;

  insert into public.source_reliabilities (calculation_id, source_type, position, compared, divergences, reason)
  select new_calculation_id, initial[ranked.type_index], ranked.position,
    compared[ranked.type_index], divergences[ranked.type_index],
    case
      when compared[ranked.type_index] >= 10 then format(
        '%s: %s em %s (%s%%)',
        private.source_type_name(initial[ranked.type_index]),
        private.counted(divergences[ranked.type_index], 'divergência', 'divergências'),
        private.counted(compared[ranked.type_index], 'filme comparado', 'filmes comparados'),
        round(100.0 * divergences[ranked.type_index] / compared[ranked.type_index])
      )
      else format(
        '%s: %s em %s, menos de 10; mantém a posição do ranking inicial',
        private.source_type_name(initial[ranked.type_index]),
        private.counted(divergences[ranked.type_index], 'divergência', 'divergências'),
        private.counted(compared[ranked.type_index], 'filme comparado', 'filmes comparados')
      )
    end
  from unnest(ranking) with ordinality as ranked (type_index, position);

  if changed then
    for affected_movie_id in select distinct movie_id from public.source_values loop
      perform private.choose_movie_values(affected_movie_id);
    end loop;
  end if;

  select jsonb_build_object(
    'changed', changed,
    'ranking', jsonb_agg(
      jsonb_build_object(
        'position', reliability.position,
        'source_type', reliability.source_type,
        'compared', reliability.compared,
        'divergences', reliability.divergences,
        'reason', reliability.reason
      )
      order by reliability.position
    ),
    'alerts', case when changed then jsonb_build_array(jsonb_build_object(
      'type', 'source-reliability',
      'subject', 'source-reliability',
      'effect', 'inform',
      'text', 'A confiabilidade da fonte mudou:' || E'\n' || string_agg(
        reliability.position || '. ' || reliability.reason,
        E'\n' order by reliability.position
      )
    )) else '[]'::jsonb end
  )
  into result
  from public.source_reliabilities as reliability
  where reliability.calculation_id = new_calculation_id;

  return result;
end;
$$;

-- Records the weekly Google rating of the cinema and the coordinates and
-- Google reviews link the Hermes proposes, each one optional. A proposal is
-- new when it differs from the approved values, from the pending proposal and
-- from every proposal the owner rejected; a new proposal replaces the pending
-- one and raises the alert that opens the proposal occurrence. Returns the
-- alerts and, when a proposal came, what it was: new, pending, approved or
-- rejected.
create or replace function public.update_cinema(
  cinema_slug text,
  google_rating jsonb default null,
  proposal jsonb default null,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  cinema record;
  proposed record;
  pending record;
  outcome text;
  alerts jsonb := '[]'::jsonb;
begin
  select id, slug, name, latitude, longitude, google_reviews_url
  into cinema
  from public.cinemas
  where slug = update_cinema.cinema_slug
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_cinema'));
  end if;

  if update_cinema.google_rating is not null then
    update public.cinemas
    set google_rating = (update_cinema.google_rating ->> 'rating')::numeric,
      google_reviews_count = (update_cinema.google_rating ->> 'reviews')::integer,
      google_rating_updated_at = update_cinema.reference_time
    where id = cinema.id;
  end if;

  if update_cinema.proposal is null then
    return jsonb_build_object('alerts', alerts);
  end if;

  -- Rounded as the columns keep them, so that the same place compares equal.
  select (update_cinema.proposal ->> 'latitude')::numeric(8, 6) as latitude,
    (update_cinema.proposal ->> 'longitude')::numeric(9, 6) as longitude,
    update_cinema.proposal ->> 'google_reviews_url' as google_reviews_url
  into proposed;

  select id, latitude, longitude, google_reviews_url
  into pending
  from public.cinema_proposals
  where cinema_id = cinema.id and decision is null
  for update;

  outcome := case
    when (cinema.latitude, cinema.longitude, cinema.google_reviews_url)
      is not distinct from (proposed.latitude, proposed.longitude, proposed.google_reviews_url)
      then 'approved'
    when pending.id is not null
      and (pending.latitude, pending.longitude, pending.google_reviews_url)
        = (proposed.latitude, proposed.longitude, proposed.google_reviews_url)
      then 'pending'
    when exists (
      select 1
      from public.cinema_proposals as rejected
      where rejected.cinema_id = cinema.id
        and rejected.decision = 'rejected'
        and (rejected.latitude, rejected.longitude, rejected.google_reviews_url)
          = (proposed.latitude, proposed.longitude, proposed.google_reviews_url)
    ) then 'rejected'
    else 'new'
  end;

  if outcome = 'new' then
    delete from public.cinema_proposals where id = pending.id;
    insert into public.cinema_proposals (cinema_id, latitude, longitude, google_reviews_url, proposed_at)
    values (cinema.id, proposed.latitude, proposed.longitude, proposed.google_reviews_url,
      update_cinema.reference_time);

    alerts := jsonb_build_array(private.cinema_alert(
      'proposal',
      cinema.slug,
      'open',
      format(
        '%s: o Hermes propôs %s. %s Aprove para que a proposta valha no site, ou rejeite para '
          || 'manter o que vale hoje.',
        cinema.name,
        private.proposal_values_text(proposed.latitude, proposed.longitude, proposed.google_reviews_url),
        coalesce(
          'Hoje valem '
            || private.proposal_values_text(cinema.latitude, cinema.longitude, cinema.google_reviews_url)
            || '.',
          'Hoje o cinema não tem coordenadas nem link das avaliações do Google.'
        )
      )
    ));
  end if;

  return jsonb_build_object('proposal', outcome, 'alerts', alerts);
end;
$$;

-- Records the source tickets of the accepted sessions of a successful
-- reading, before their prices. A source ticket sent without a ticket type
-- and never seen in the source type enters pending ticket type, and only that
-- first appearance raises the alert. A resolved source ticket whose source
-- informs a structured ticket type different from the assignment raises the
-- alert once for that ticket type, and the assignment still holds. Returns
-- the alerts to send.
create or replace function private.record_source_tickets(
  reading jsonb,
  today date,
  closed_weekdays smallint[],
  chosen_source_type public.source_type,
  cinema_name text,
  reference_time timestamptz
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  seen record;
  known record;
  disagreeing public.ticket_type;
  new_id bigint;
  raised_alerts jsonb := '[]'::jsonb;
begin
  for seen in
    select listed.normalized,
      (array_agg(listed.source_ticket order by listed.session_position, listed.price_position))[1]
        as source_ticket,
      (array_agg(listed.kind order by listed.session_position, listed.price_position)
        filter (where listed.kind is not null)) as kinds,
      bool_or(listed.kind is null) as without_kind,
      min(listed.price_cents) as lowest,
      max(listed.price_cents) as highest,
      count(distinct listed.session_position)::integer as sessions
    from (
      select private.normalized_source_ticket(price.value ->> 'source_ticket') as normalized,
        price.value ->> 'source_ticket' as source_ticket,
        (price.value ->> 'kind')::public.ticket_type as kind,
        (price.value ->> 'price_cents')::integer as price_cents,
        accepted.session_position,
        price.price_position
      from private.reading_sessions(reading, today, closed_weekdays)
        with ordinality as accepted (session, tmdb_id, starts_at, outcome, session_position)
      cross join lateral jsonb_array_elements(accepted.session -> 'prices')
        with ordinality as price (value, price_position)
      where accepted.outcome = 'accepted'
    ) as listed
    group by listed.normalized
    order by listed.normalized
  loop
    select ticket.id, ticket.status, ticket.ticket_type, ticket.not_box_office,
      ticket.disputed_ticket_type
    into known
    from public.source_tickets as ticket
    where ticket.source_type = chosen_source_type
      and ticket.normalized_source_ticket = seen.normalized
    for update;

    if found then
      update public.source_tickets
      set source_ticket = seen.source_ticket,
        last_seen_at = greatest(last_seen_at, record_source_tickets.reference_time)
      where id = known.id;

      if known.status = 'resolved' then
        select kind into disagreeing
        from unnest(seen.kinds) as kind
        where kind is distinct from known.ticket_type
        limit 1;

        if disagreeing is not null and disagreeing is distinct from known.disputed_ticket_type then
          update public.source_tickets set disputed_ticket_type = disagreeing where id = known.id;

          raised_alerts := raised_alerts || private.unknown_ticket_type_alert(
            chosen_source_type,
            seen.normalized,
            'open',
            format(
              '%s: %s informou o ingresso na fonte "%s" como %s, mas ele está atribuído como %s. '
                || 'Vale a atribuição até você revê-la.',
              private.source_type_name(chosen_source_type),
              cinema_name,
              seen.source_ticket,
              private.ticket_type_name(disagreeing),
              coalesce(private.ticket_type_name(known.ticket_type), 'não sendo preço de bilheteria')
            )
          );
        end if;
      end if;
    elsif seen.without_kind then
      new_id := null;

      insert into public.source_tickets (
        source_type, source_ticket, normalized_source_ticket, first_seen_at, last_seen_at
      )
      values (
        chosen_source_type,
        seen.source_ticket,
        seen.normalized,
        record_source_tickets.reference_time,
        record_source_tickets.reference_time
      )
      on conflict on constraint source_tickets_one_per_source_type do nothing
      returning id into new_id;

      if new_id is not null then
        raised_alerts := raised_alerts || private.unknown_ticket_type_alert(
          chosen_source_type,
          seen.normalized,
          'open',
          format(
            '%s: o ingresso na fonte "%s" ficou em tipo de ingresso pendente. %s o informou em %s, '
              || 'com %s. Atribua o tipo de ingresso ou indique que ele não é preço de bilheteria; '
              || 'até lá, o valor fica fora do site.',
            private.source_type_name(chosen_source_type),
            seen.source_ticket,
            cinema_name,
            private.counted(seen.sessions, 'sessão', 'sessões'),
            case
              when seen.lowest = seen.highest then private.brl(seen.lowest)
              else 'valores de ' || private.brl(seen.lowest) || ' a ' || private.brl(seen.highest)
            end
          )
        );
      end if;
    end if;
  end loop;

  return raised_alerts;
end;
$$;
