-- A source title not found on TMDB enters the showtimes as a movie without
-- TMDB, with the data of the main source, instead of leaving the reading
-- incomplete, as ADR 0017 of bubbacore/dan decides. The movie is identified by
-- its normalized source title, the same in every cinema and source, and has no
-- genres, overview, trailer, credits or ratings.

alter table public.movies
  alter column tmdb_id drop not null,
  add column normalized_source_title text unique check (btrim(normalized_source_title) <> ''),
  add constraint movies_without_tmdb_have_normalized_source_title
    check ((tmdb_id is null) = (normalized_source_title is not null));

comment on column public.movies.title is
  'The title in Brazil, from TMDB, or, in a movie without TMDB, the source title without the language and format markers.';
comment on column public.movies.normalized_source_title is
  'Identifies a movie without TMDB: the same normalized source title is the same movie in every cinema and source.';

-- The cinemas where each movie without TMDB has already appeared, so that its
-- first appearance in each cinema raises the alert only once.
create table public.movie_without_tmdb_appearances (
  movie_id bigint not null references public.movies,
  cinema_id bigint not null references public.cinemas,
  first_seen_at timestamptz not null,
  primary key (movie_id, cinema_id)
);

create index movie_without_tmdb_appearances_cinema_id_idx
  on public.movie_without_tmdb_appearances (cinema_id);

alter table public.movie_without_tmdb_appearances enable row level security;
revoke all on public.movie_without_tmdb_appearances from anon, authenticated;

-- The movie's address follows the original language of its title. A title
-- without any letter or digit, like one in Japanese, falls back to the title
-- in Brazil. When another movie already has the address, the movie's year
-- tells them apart; when the year is missing or repeats, the TMDB id does, or,
-- in a movie without TMDB, the first free number from 2 on. The address is
-- recorded when the movie enters the catalog and never changes.
create or replace function private.new_movie_slug(
  original_title text,
  title text,
  year smallint,
  tmdb_id integer
)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  base text := coalesce(
    nullif(private.slugify(original_title), ''),
    nullif(private.slugify(title), ''),
    'filme'
  );
begin
  if not exists (select 1 from public.movies where slug = base) then
    return base;
  end if;

  if new_movie_slug.year is not null and not exists (
    select 1
    from public.movies as movie
    where movie.slug = base || '-' || new_movie_slug.year
      or (movie.slug = base and movie.year = new_movie_slug.year)
  ) then
    return base || '-' || new_movie_slug.year;
  end if;

  if new_movie_slug.tmdb_id is not null then
    return base || '-' || new_movie_slug.tmdb_id;
  end if;

  return base || '-' || (
    select min(candidate)
    from generate_series(2, (select count(*)::integer + 2 from public.movies)) as candidate
    where not exists (select 1 from public.movies where slug = base || '-' || candidate)
  );
end;
$$;

-- The catalog movie of an entry of the reading: the TMDB movie with the
-- proposed TMDB id or, in a movie without TMDB, the one with the same
-- normalized source title. Null while the movie is not in the catalog.
create function private.reading_movie_id(entry jsonb)
returns bigint
language sql
stable
set search_path = ''
as $$
  select movie.id
  from public.movies as movie
  where jsonb_typeof(entry -> 'tmdb_id') = 'number'
    and movie.tmdb_id = (entry ->> 'tmdb_id')::integer
  union all
  select movie.id
  from public.movies as movie
  where jsonb_typeof(entry -> 'tmdb_id') = 'null'
    and movie.normalized_source_title = private.normalized_source_title(entry ->> 'source_title');
$$;

-- Each session of a reading with what the ingestion does with it. Sessions
-- outside the window and on a closed day are discarded; a session whose
-- proposed TMDB id differs from the top search result is retained. A movie
-- without TMDB has no proposed movie, and its sessions are accepted. A session
-- without a format comes out as 2D, the common session.
create or replace function private.reading_sessions(reading jsonb, today date, closed_weekdays smallint[])
returns table (session jsonb, tmdb_id integer, starts_at timestamp, outcome text)
language sql
immutable
set search_path = ''
as $$
  select listed_session.value
      || jsonb_build_object('format', coalesce(listed_session.value ->> 'format', '2d')),
    (listed_movie.value ->> 'tmdb_id')::integer,
    start.at,
    case
      when start.at::date not between today and today + 6 then 'outside_window'
      when extract(isodow from start.at)::smallint = any (closed_weekdays) then 'closed_day'
      when jsonb_typeof(listed_movie.value -> 'tmdb_id') = 'null' then 'accepted'
      when listed_movie.value -> 'tmdb_id' is distinct from listed_movie.value -> 'tmdb_search_top_id'
        then 'retained'
      else 'accepted'
    end
  from jsonb_array_elements(reading -> 'sessions') as listed_session (value)
  join jsonb_array_elements(reading -> 'movies') as listed_movie (value)
    on listed_movie.value ->> 'key' = listed_session.value ->> 'movie_key'
  cross join lateral (select (listed_session.value ->> 'starts_at')::timestamp as at) as start;
$$;

-- A source title resolved in the cinema takes the chosen movie, also when the
-- reading brought it as a movie without TMDB, and loses the TMDB data of
-- another movie and the source data of a movie without TMDB.
create or replace function private.with_resolved_source_titles(reading jsonb, chosen_cinema_id bigint)
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
      ) - 'without_tmdb'
        || jsonb_build_object('tmdb_id', resolved.tmdb_id, 'tmdb_search_top_id', resolved.tmdb_id)
    end
    order by listed.position
  ), '[]'))
  from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
  left join public.resolved_source_titles as resolved
    on resolved.cinema_id = chosen_cinema_id
    and resolved.normalized_source_title
      = private.normalized_source_title(listed.value ->> 'source_title');
$$;

-- A movie without TMDB enters the catalog with the source data of the reading
-- in which it first appears: the title without the language and format
-- markers, the original title or, without one, the same title, the year and
-- the duration. Later readings only fill in what is missing.
create function private.import_movie_without_tmdb(entry jsonb, reference_time timestamptz)
returns void
language plpgsql
set search_path = ''
as $$
declare
  data jsonb := entry -> 'without_tmdb';
  normalized text := private.normalized_source_title(entry ->> 'source_title');
  target_id bigint;
begin
  select id
  into target_id
  from public.movies
  where normalized_source_title = normalized
  for update;

  if not found then
    insert into public.movies (normalized_source_title, slug, title, original_title)
    values (
      normalized,
      private.new_movie_slug(null, data ->> 'title', (data ->> 'year')::smallint, null),
      data ->> 'title',
      coalesce(data ->> 'original_title', data ->> 'title')
    )
    returning id into target_id;
  end if;

  -- On the right side, the columns hold the values before the update.
  update public.movies
  set year = coalesce(year, (data ->> 'year')::smallint),
    runtime_minutes = coalesce(runtime_minutes, (data ->> 'duration_minutes')::smallint),
    metadata_updated_at = import_movie_without_tmdb.reference_time
  where id = target_id;
end;
$$;

-- The source data a movie without TMDB still lacks, named as in the reading.
create function private.missing_movie_without_tmdb_fields(movie public.movies)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(field.name order by field.position), '[]')
  from (
    values
      (1, 'year', movie.year is null),
      (2, 'duration_minutes', movie.runtime_minutes is null)
  ) as field (position, name, missing)
  where field.missing;
$$;

-- The accepted movies of a successful reading enter the catalog, the values
-- their main source informed are recorded, and their values are chosen
-- again. Each movie enters through the first of the reading's entries for it
-- that brings TMDB data, preferring one with the titles, and each source
-- value comes from the first entry that informs it. A trailer from another
-- service than YouTube is discarded, and one without a version counts as
-- dubbed, so that a subtitled one is never assumed. A movie without TMDB
-- enters through the first entry for its normalized source title, and only
-- its content rating comes from the source, because it shows no overview nor
-- trailer.
create or replace function private.record_reading_movies(
  reading jsonb,
  chosen_reading_id uuid,
  chosen_source_id bigint,
  reference_time timestamptz
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  movie jsonb;
  accepted_movie_id bigint;
begin
  for movie in
    select distinct on ((listed.value ->> 'tmdb_id')::integer) listed.value
    from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
    where jsonb_typeof(listed.value -> 'tmdb_id') = 'number'
      and listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
      and listed.value ? 'tmdb'
    order by (listed.value ->> 'tmdb_id')::integer,
      listed.value #>> '{tmdb,title}' is null,
      listed.position
  loop
    perform private.import_movie(movie, record_reading_movies.reference_time);
  end loop;

  for movie in
    select distinct on (private.normalized_source_title(listed.value ->> 'source_title'))
      listed.value
    from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
    where jsonb_typeof(listed.value -> 'tmdb_id') = 'null'
    order by private.normalized_source_title(listed.value ->> 'source_title'), listed.position
  loop
    perform private.import_movie_without_tmdb(movie, record_reading_movies.reference_time);
  end loop;

  insert into public.source_values (movie_id, source_id, data, value, trailer_version, reading_id, informed_at)
  select informed.movie_id, chosen_source_id, informed.data, informed.value, informed.trailer_version,
    chosen_reading_id, record_reading_movies.reference_time
  from (
    select distinct on (entry.movie_id, entry.data) entry.movie_id, entry.data, entry.value,
      entry.trailer_version
    from (
      select private.reading_movie_id(listed.value) as movie_id, listed.position, given.data,
        given.value, given.trailer_version
      from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
      cross join lateral (
        values
          ('content_rating'::public.source_value_data, listed.value ->> 'content_rating', null::text),
          ('overview', listed.value ->> 'overview', null),
          (
            'trailer',
            private.youtube_key(listed.value #>> '{trailer,url}'),
            coalesce(listed.value #>> '{trailer,version}', 'dubbed')
          )
      ) as given (data, value, trailer_version)
      where given.value is not null
        and (
          (
            jsonb_typeof(listed.value -> 'tmdb_id') = 'number'
            and listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
          )
          or (
            jsonb_typeof(listed.value -> 'tmdb_id') = 'null'
            and given.data = 'content_rating'
          )
        )
    ) as entry
    where entry.movie_id is not null
    order by entry.movie_id, entry.data, entry.position
  ) as informed
  on conflict (movie_id, source_id, data) do update
  set value = excluded.value,
    trailer_version = excluded.trailer_version,
    reading_id = excluded.reading_id,
    informed_at = excluded.informed_at;

  for accepted_movie_id in
    select distinct private.reading_movie_id(listed.value)
    from jsonb_array_elements(reading -> 'movies') as listed (value)
    where jsonb_typeof(listed.value -> 'tmdb_id') = 'null'
      or listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
  loop
    if accepted_movie_id is not null then
      perform private.choose_movie_values(accepted_movie_id);
    end if;
  end loop;
end;
$$;

-- The plan also returns, for each cinema, the last post read, with the source
-- type, the link and the date, or null when no reading read a post. A post
-- more recent than it is a new post. The movies of the catalog come by TMDB
-- id, and the movies without TMDB by normalized source title, each with the
-- fields it still lacks.
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
      where movie.tmdb_id is not null
    ),
    'movies_without_tmdb',
    (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'normalized_source_title', movie.normalized_source_title,
          'missing', private.missing_movie_without_tmdb_fields(movie)
        )
        order by movie.normalized_source_title
      ), '[]')
      from public.movies as movie
      where movie.tmdb_id is null
    )
  )
  from public.cinemas as cinema
  join public.cities as city on city.id = cinema.city_id
  join public.sources as source on source.cinema_id = cinema.id and source.active
  where cinema.active
    and (cinema_slugs is null or cinema.slug = any (cinema_slugs));
$$;

-- Records a reading of the reserved cinema. The reading follows the contract,
-- already checked by the ingestion. A successful reading replaces the
-- cinema's whole showtimes, and an outdated one erases them. An error, an
-- incomplete reading or a retained reading keeps the showtimes of the last
-- successful reading whole, with no time limit, and the alert of the first
-- failure of the day says so. A reading without a new post takes the showtimes
-- and the period of the last post read. A post reading with a period is
-- outdated once today is past its last day, and one without a period follows
-- the rule of the other sources. The movies it accepts enter the catalog, with
-- the source values, and the source tickets of its accepted sessions are
-- recorded before their prices. The session drop counts only the sessions of
-- the previous successful reading still in the window. A pending
-- identification alerts on its first appearance and on the first reading of
-- each day in which it still retains sessions, naming the proposed movie and
-- the top search result with their TMDB links. A movie without TMDB has its
-- sessions accepted and informs its first appearance in each cinema, once.
-- The accepted sessions of a source title resolved since the cinema's last
-- reading count as released. Returns the result with the alerts to send, or a
-- refusal when the reservation does not allow it or the reading does not fit
-- the database.
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
  keeps_success boolean;
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
  appearance record;
  without_tmdb_alerts jsonb := '[]'::jsonb;
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
      and jsonb_typeof(listed.value -> 'tmdb_id') = 'number'
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

  -- The cinema's showtimes come from a successful reading unless the last
  -- reading that set them was outdated, or no reading ever set them.
  select showtimes_reading.status = 'success'
  into keeps_success
  from private.last_showtimes_reading(target.cinema_id, target.started_at) as showtimes_reading;
  keeps_success := coalesce(keeps_success, false);

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

  -- A successful reading replaces the cinema's showtimes, and an outdated one
  -- erases them. Any other failure keeps the showtimes whole, and the
  -- sessions of an incomplete reading are discarded instead of mixed in.
  if failure is null or failure = 'outdated' then
    delete from public.sessions where cinema_id = target.cinema_id;
  end if;

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
      select listed.session, listed.starts_at, private.reading_movie_id(listed_movie.value) as movie_id
      from private.reading_sessions(effective, today, target.closed_weekdays) as listed
      join jsonb_array_elements(effective -> 'movies') as listed_movie (value)
        on listed_movie.value ->> 'key' = listed.session ->> 'movie_key'
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

    -- The first appearance of a movie without TMDB in the cinema is informed,
    -- and later appearances there are not.
    for appearance in
      select listed_movie.normalized,
        (array_agg(listed_movie.value ->> 'source_title' order by listed.starts_at))[1]
          as source_title,
        count(*)::integer as sessions
      from private.reading_sessions(effective, today, target.closed_weekdays) as listed
      join lateral (
        select listed_entry.value,
          private.normalized_source_title(listed_entry.value ->> 'source_title') as normalized
        from jsonb_array_elements(effective -> 'movies') as listed_entry (value)
        where listed_entry.value ->> 'key' = listed.session ->> 'movie_key'
      ) as listed_movie on true
      where listed.outcome = 'accepted'
        and listed.tmdb_id is null
      group by listed_movie.normalized
      order by listed_movie.normalized
    loop
      insert into public.movie_without_tmdb_appearances (movie_id, cinema_id, first_seen_at)
      select movie.id, target.cinema_id, record_reading.reference_time
      from public.movies as movie
      where movie.normalized_source_title = appearance.normalized
      on conflict (movie_id, cinema_id) do nothing;

      if found then
        without_tmdb_alerts := without_tmdb_alerts || jsonb_build_object(
          'type', 'movie-without-tmdb',
          'subject', 'movie-without-tmdb:' || target.cinema_slug || ':' || appearance.normalized,
          'effect', 'inform',
          'text', format(
            '%s: o título na fonte "%s" não foi encontrado no TMDB e entrou como filme sem TMDB, com %s. Confira se o TMDB tem o filme e a busca deixou de achá-lo.',
            target.cinema_name,
            appearance.source_title,
            private.counted(appearance.sessions, 'sessão aceita', 'sessões aceitas')
          )
        );
      end if;
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
          '%s: leitura com falha (%s). Motivo: %s. %s',
          target.cinema_name,
          private.failure_type_name(failure),
          rtrim(btrim(failure_reason), '.'),
          case
            when failure = 'outdated'
              then 'A programação do cinema foi apagada, e o site mostra "atualizando".'
            when keeps_success
              then 'O site continua com a programação da última leitura com sucesso.'
            else 'O cinema continua sem programação, e o site mostra "atualizando".'
          end
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

  raised_alerts := raised_alerts || identification_alerts || without_tmdb_alerts || ticket_alerts;

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

-- Starts a reimport and returns its plan. The weekly round covers the TMDB
-- movies with sessions in active cinemas. The manual round covers the chosen
-- movies and people, even those no longer showing, or the whole catalog when
-- nothing is chosen. A movie without TMDB never enters a reimport. Returns a
-- refusal with the index of each chosen movie or person outside the catalog.
create or replace function public.reimport_plan(
  reimport_type public.reimport_type,
  movie_tmdb_ids integer[] default null,
  person_tmdb_ids integer[] default null,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  unknown_movies jsonb;
  unknown_people jsonb;
  new_reimport_id uuid;
begin
  select jsonb_agg(chosen.position - 1 order by chosen.position)
  into unknown_movies
  from unnest(reimport_plan.movie_tmdb_ids) with ordinality as chosen (tmdb_id, position)
  where not exists (select 1 from public.movies as movie where movie.tmdb_id = chosen.tmdb_id);

  select jsonb_agg(chosen.position - 1 order by chosen.position)
  into unknown_people
  from unnest(reimport_plan.person_tmdb_ids) with ordinality as chosen (tmdb_id, position)
  where not exists (select 1 from public.people as person where person.tmdb_id = chosen.tmdb_id);

  if unknown_movies is not null or unknown_people is not null then
    return jsonb_build_object('refusal', jsonb_build_object(
      'code', 'unknown_catalog_item',
      'movies', coalesce(unknown_movies, '[]'),
      'people', coalesce(unknown_people, '[]')
    ));
  end if;

  insert into public.reimports (type, started_at)
  values (reimport_plan.reimport_type, reimport_plan.reference_time)
  returning id into new_reimport_id;

  insert into public.reimport_movies (reimport_id, movie_id)
  select new_reimport_id, movie.id
  from public.movies as movie
  where movie.tmdb_id is not null
    and case
      when reimport_plan.reimport_type = 'weekly' then exists (
        select 1
        from public.sessions as session
        join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
        where session.movie_id = movie.id
      )
      when reimport_plan.movie_tmdb_ids is null and reimport_plan.person_tmdb_ids is null then true
      else coalesce(movie.tmdb_id = any (reimport_plan.movie_tmdb_ids), false)
    end;

  insert into public.reimport_people (reimport_id, person_id, planned)
  select new_reimport_id, person.id, true
  from public.people as person
  where person.tmdb_id = any (reimport_plan.person_tmdb_ids);

  return jsonb_build_object(
    'reimport_id', new_reimport_id,
    'movies', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'tmdb_id', movie.tmdb_id,
          'imdb_id', movie.imdb_id,
          'title', movie.title,
          'original_title', movie.original_title,
          'year', movie.year
        )
        order by movie.tmdb_id
      ), '[]')
      from public.reimport_movies as planned
      join public.movies as movie on movie.id = planned.movie_id
      where planned.reimport_id = new_reimport_id
    ),
    'people', (
      select coalesce(jsonb_agg(
        jsonb_build_object('tmdb_id', person.tmdb_id, 'name', person.name)
        order by person.tmdb_id
      ), '[]')
      from public.reimport_people as planned
      join public.people as person on person.id = planned.person_id
      where planned.reimport_id = new_reimport_id
    )
  );
end;
$$;

grant execute on function private.reading_movie_id(jsonb) to service_role;
grant execute on function private.import_movie_without_tmdb(jsonb, timestamptz) to service_role;
grant execute on function private.missing_movie_without_tmdb_fields(public.movies) to service_role;
