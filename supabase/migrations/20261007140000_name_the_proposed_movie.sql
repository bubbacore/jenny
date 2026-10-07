-- The pending identification alert names the proposed movie and the top
-- search result, with the year and the TMDB link, when the Hermes sends them,
-- and carries the proposed movie for the Accept button. The titles and the
-- years of the last appearance stay with the pending identification.
alter table public.pending_identifications
  add column proposed_title text check (btrim(proposed_title) <> ''),
  add column proposed_year smallint check (proposed_year between 1870 and 2100),
  add column search_top_title text check (btrim(search_top_title) <> ''),
  add column search_top_year smallint check (search_top_year between 1870 and 2100);

comment on column public.pending_identifications.proposed_title is
  'Title in Brazil of the proposed movie, when the last appearance sent it.';
comment on column public.pending_identifications.search_top_title is
  'Title in Brazil of the top search result, when the last appearance sent it.';

-- A recollection that releases the sessions retained by a pending
-- identification publishes the site, so the released sessions show up the
-- same day.
alter table public.readings
  add column sessions_released integer not null default 0 check (sessions_released >= 0);

comment on column public.readings.sessions_released is
  'Accepted sessions of a source title resolved after the cinema''s last reading, which retained them.';

-- A movie in TMDB as the alerts name it: the title with the year and the
-- id, or only the id when the title is unknown.
create function private.tmdb_movie_name(tmdb_id integer, title text, release_year integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when title is null then 'o TMDB ' || tmdb_id
    else title || coalesce(' (' || release_year || ')', '') || ', TMDB ' || tmdb_id
  end;
$$;

create function private.tmdb_movie_url(tmdb_id integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'https://www.themoviedb.org/movie/' || tmdb_id;
$$;

-- The alert of a pending identification that the reading raises, with the
-- proposed movie for the Accept button.
create function private.pending_identification_alert(
  cinema_slug text,
  normalized_source_title text,
  effect text,
  text text,
  proposed_movie jsonb
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select private.pending_identification_alert(cinema_slug, normalized_source_title, effect, text)
    || jsonb_build_object('proposed_movie', proposed_movie);
$$;

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
  movie jsonb;
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
  kept_dates date[] := '{}';
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

-- Ends the collection and decides whether it ends with a site publication.
-- The daily collection publishes; a recollection publishes only when some of
-- its readings changed result or released sessions retained by a pending
-- identification; both stay quiet while the automatic publication is
-- suspended. A manual collection publishes unless the owner
-- asked otherwise, and when it publishes it ends the suspension.
create or replace function public.finish_collection(collection_id uuid, reference_time timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  collection record;
  suspended boolean;
  publishes boolean;
begin
  select id, type, site_publication_requested, finished_at into collection
  from public.collections
  where id = finish_collection.collection_id
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_collection'));
  end if;
  if collection.finished_at is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'collection_finished'));
  end if;

  suspended := exists (
    select 1 from public.automatic_publication_suspensions where ended_at is null
  );

  publishes := case collection.type
    when 'daily' then not suspended
    when 'recollection' then not suspended and exists (
      select 1
      from public.readings as reading
      where reading.collection_id = collection.id
        and reading.status in ('success', 'failure')
        and (reading.sessions_released > 0 or reading.status is distinct from (
          select earlier.status
          from public.readings as earlier
          where earlier.cinema_id = reading.cinema_id
            and earlier.id <> reading.id
            and earlier.status in ('success', 'failure')
            and earlier.finished_at <= reading.started_at
          order by earlier.finished_at desc
          limit 1
        ))
    )
    when 'manual' then collection.site_publication_requested
  end;

  if collection.type = 'manual' and publishes and suspended then
    update public.automatic_publication_suspensions
    set ended_at = reference_time, ended_by_collection_id = collection.id
    where ended_at is null;
    suspended := false;
  end if;

  update public.collections
  set finished_at = reference_time, site_publication = publishes
  where id = collection.id;

  return jsonb_build_object(
    'collection_id', collection.id,
    'site_publication', publishes,
    'automatic_publication_suspended', suspended
  );
end;
$$;

grant execute on function private.tmdb_movie_name(integer, text, integer) to service_role;
grant execute on function private.tmdb_movie_url(integer) to service_role;
grant execute on function private.pending_identification_alert(text, text, text, text, jsonb)
  to service_role;
