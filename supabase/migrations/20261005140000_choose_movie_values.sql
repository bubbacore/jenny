-- The content rating, the overview and the trailer of each movie, chosen
-- between TMDB and what the main sources informed, and the source reliability
-- that decides between sources that disagree.

-- TMDB's values keep their own columns, which the collection plan checks for
-- missing fields. The former columns now hold the chosen value, whose
-- source type is null when it comes from TMDB.
alter table public.movies rename column overview to tmdb_overview;
alter table public.movies rename column content_rating to tmdb_content_rating;
alter table public.movies rename column trailer_youtube_key to tmdb_trailer_youtube_key;
alter table public.movies rename column trailer_version to tmdb_trailer_version;
alter table public.movies
  rename constraint movies_trailer_has_version to movies_tmdb_trailer_has_version;

alter table public.movies
  add column overview text check (btrim(overview) <> ''),
  add column overview_source_type public.source_type,
  add column content_rating text check (content_rating in ('L', '10', '12', '14', '16', '18')),
  add column content_rating_source_type public.source_type,
  add column trailer_youtube_key text check (btrim(trailer_youtube_key) <> ''),
  add column trailer_version text check (trailer_version in ('subtitled', 'dubbed', 'original')),
  add column trailer_source_type public.source_type,
  add constraint movies_trailer_has_version
    check ((trailer_youtube_key is null) = (trailer_version is null)),
  add constraint movies_overview_origin_needs_value
    check (overview is not null or overview_source_type is null),
  add constraint movies_content_rating_origin_needs_value
    check (content_rating is not null or content_rating_source_type is null),
  add constraint movies_trailer_origin_needs_value
    check (trailer_youtube_key is not null or trailer_source_type is null);

update public.movies
set overview = tmdb_overview,
  content_rating = tmdb_content_rating,
  trailer_youtube_key = tmdb_trailer_youtube_key,
  trailer_version = tmdb_trailer_version;

create type public.source_value_data as enum ('content_rating', 'overview', 'trailer');

-- What each main source said about each movie, with the last reading that
-- said it. A reading that no longer informs a value keeps the last one. A
-- trailer keeps the YouTube key and its version.
create table public.source_values (
  movie_id bigint not null references public.movies on delete cascade,
  source_id bigint not null references public.sources,
  data public.source_value_data not null,
  value text not null check (btrim(value) <> ''),
  trailer_version text check (trailer_version in ('subtitled', 'dubbed', 'original')),
  reading_id uuid not null references public.readings,
  informed_at timestamptz not null,
  primary key (movie_id, source_id, data),
  constraint source_values_version_only_in_trailer
    check ((data = 'trailer') = (trailer_version is not null)),
  constraint source_values_content_rating_in_list
    check (data <> 'content_rating' or value in ('L', '10', '12', '14', '16', '18'))
);

create index source_values_source_id_idx on public.source_values (source_id);
create index source_values_reading_id_idx on public.source_values (reading_id);
create index source_values_data_informed_at_idx on public.source_values (data, informed_at);

-- Each calculation of the source reliability, kept as history. The current
-- ranking is the one of the last calculation recorded.
create table public.source_reliability_calculations (
  id bigint generated always as identity primary key,
  calculated_at timestamptz not null,
  changed boolean not null
);

create table public.source_reliabilities (
  calculation_id bigint not null references public.source_reliability_calculations on delete cascade,
  source_type public.source_type not null,
  position smallint not null check (position > 0),
  compared integer not null check (compared >= 0),
  divergences integer not null check (divergences between 0 and compared),
  reason text not null check (btrim(reason) <> ''),
  primary key (calculation_id, source_type),
  constraint source_reliabilities_one_per_position unique (calculation_id, position)
);

alter table public.source_values enable row level security;
alter table public.source_reliability_calculations enable row level security;
alter table public.source_reliabilities enable row level security;
revoke all on public.source_values, public.source_reliability_calculations,
  public.source_reliabilities from anon, authenticated;

-- The structured sources come first, and the official site, read from
-- images, comes last. It breaks ties and holds the place of the source types
-- without enough comparisons.
create function private.initial_source_ranking()
returns public.source_type[]
language sql
immutable
set search_path = ''
as $$
  select array['ingresso_com', 'veloxtickets', 'cinesercla_site', 'official_site']::public.source_type[];
$$;

create function private.source_type_name(type public.source_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case type
    when 'ingresso_com' then 'ingresso.com'
    when 'veloxtickets' then 'Veloxtickets'
    when 'cinesercla_site' then 'site da Cinesercla'
    when 'official_site' then 'site oficial'
  end;
$$;

-- The ranking of the last calculation, or the initial ranking before the
-- first one.
create function private.source_ranking()
returns table (source_type public.source_type, place integer)
language sql
stable
set search_path = ''
as $$
  with last_calculation as (
    select id from public.source_reliability_calculations order by id desc limit 1
  )
  select reliability.source_type, reliability.position::integer
  from public.source_reliabilities as reliability
  where reliability.calculation_id = (select id from last_calculation)
  union all
  select initial.source_type, initial.position::integer
  from unnest(private.initial_source_ranking()) with ordinality as initial (source_type, position)
  where not exists (select 1 from last_calculation);
$$;

-- The YouTube key of a video URL, or null for any other service.
create function private.youtube_key(url text)
returns text
language sql
immutable
set search_path = ''
as $$
  select (regexp_match(
    url,
    '^https?://(?:(?:www|m)\.)?(?:youtube\.com/(?:watch\?(?:[^#]*&)?v=|embed/|shorts/)|youtu\.be/)([A-Za-z0-9_-]{11})(?:[?&#/]|$)'
  ))[1];
$$;

-- The value of a movie's data informed by the main source of highest
-- reliability. In a tie, the most recent reading wins.
create function private.best_source_value(chosen_movie_id bigint, chosen_data public.source_value_data)
returns table (value text, source_type public.source_type)
language sql
stable
set search_path = ''
as $$
  select informed.value, source.type
  from public.source_values as informed
  join public.sources as source on source.id = informed.source_id
  join private.source_ranking() as ranking on ranking.source_type = source.type
  where informed.movie_id = chosen_movie_id and informed.data = chosen_data
  order by ranking.place, informed.informed_at desc, informed.source_id
  limit 1;
$$;

-- Chooses the content rating, the overview and the trailer of a movie. The
-- content rating and the overview come from TMDB when it has them, and
-- otherwise from the main source of highest reliability. For the trailer, the
-- version comes before the origin, as in private.chosen_trailer, and within
-- the same version TMDB comes before the main sources. In a Portuguese movie,
-- a source's trailer counts as the original.
create function private.choose_movie_values(chosen_movie_id bigint)
returns void
language plpgsql
set search_path = ''
as $$
declare
  movie record;
  rating record;
  synopsis record;
  trailer record;
begin
  select id, tmdb_content_rating, tmdb_overview, tmdb_trailer_youtube_key, tmdb_trailer_version,
    original_language
  into movie
  from public.movies
  where id = chosen_movie_id
  for update;

  select * into rating from private.best_source_value(chosen_movie_id, 'content_rating');
  select * into synopsis from private.best_source_value(chosen_movie_id, 'overview');

  select candidate.youtube_key, candidate.version, candidate.source_type
  into trailer
  from (
    select movie.tmdb_trailer_youtube_key as youtube_key, movie.tmdb_trailer_version as version,
      null::public.source_type as source_type, 0 as origin_position, null::timestamptz as informed_at
    where movie.tmdb_trailer_youtube_key is not null
    union all
    select informed.value,
      case when movie.original_language = 'pt' then 'original' else informed.trailer_version end,
      source.type, ranking.place, informed.informed_at
    from public.source_values as informed
    join public.sources as source on source.id = informed.source_id
    join private.source_ranking() as ranking on ranking.source_type = source.type
    where informed.movie_id = chosen_movie_id and informed.data = 'trailer'
  ) as candidate
  order by array_position(array['subtitled', 'dubbed', 'original'], candidate.version),
    candidate.origin_position,
    candidate.informed_at desc,
    candidate.youtube_key
  limit 1;

  update public.movies
  set content_rating = coalesce(movie.tmdb_content_rating, rating.value),
    content_rating_source_type = case when movie.tmdb_content_rating is null then rating.source_type end,
    overview = coalesce(movie.tmdb_overview, synopsis.value),
    overview_source_type = case when movie.tmdb_overview is null then synopsis.source_type end,
    trailer_youtube_key = trailer.youtube_key,
    trailer_version = trailer.version,
    trailer_source_type = trailer.source_type
  where id = chosen_movie_id;
end;
$$;

-- The metadata fields still missing in a movie, named as in the reading
-- contract. A value chosen from a main source does not fill a TMDB field.
create or replace function private.missing_movie_fields(movie public.movies)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(field.name order by field.position), '[]')
  from (
    values
      (1, 'imdb_id', movie.imdb_id is null),
      (2, 'overview', movie.tmdb_overview is null),
      (3, 'year', movie.year is null),
      (4, 'countries', movie.countries is null),
      (5, 'original_language', movie.original_language is null),
      (6, 'genres', not exists (select 1 from public.movie_genres where movie_id = movie.id)),
      (7, 'runtime', movie.runtime_minutes is null),
      (8, 'budget', movie.budget_usd is null),
      (9, 'revenue', movie.revenue_usd is null),
      (10, 'content_rating', movie.tmdb_content_rating is null),
      (11, 'poster_path', movie.poster_path is null),
      (12, 'trailers', movie.tmdb_trailer_youtube_key is null),
      (13, 'credits', not exists (select 1 from public.credits where movie_id = movie.id))
  ) as field (position, name, missing)
  where field.missing;
$$;

-- Imports a movie of the reading into the catalog. A new movie is recorded
-- with everything the entry brings. A known movie gets only the fields still
-- missing in it, and its people only when it has no credits yet. A person
-- already in the catalog gets only the new credit. The cast keeps the first
-- five by TMDB's order, and every director. The caller then chooses the
-- movie's values, with private.choose_movie_values.
create or replace function private.import_movie(entry jsonb, reference_time timestamptz)
returns void
language plpgsql
set search_path = ''
as $$
declare
  data jsonb := entry -> 'tmdb';
  chosen_tmdb_id integer := (entry ->> 'tmdb_id')::integer;
  target_id bigint;
  known_language text;
  trailer jsonb;
  credit record;
begin
  select id, original_language
  into target_id, known_language
  from public.movies
  where tmdb_id = chosen_tmdb_id
  for update;

  if not found then
    insert into public.movies (tmdb_id, slug, title, original_title)
    values (
      chosen_tmdb_id,
      private.new_movie_slug(data ->> 'title', chosen_tmdb_id),
      data ->> 'title',
      data ->> 'original_title'
    )
    returning id into target_id;
  end if;

  trailer := private.chosen_trailer(
    data -> 'trailers',
    coalesce(known_language, data ->> 'original_language')
  );

  -- On the right side, the columns hold the values before the update.
  update public.movies
  set imdb_id = coalesce(imdb_id, data ->> 'imdb_id'),
    tmdb_overview = coalesce(tmdb_overview, data ->> 'overview'),
    year = coalesce(year, (data ->> 'year')::smallint),
    countries = coalesce(
      countries,
      nullif(array(select jsonb_array_elements_text(coalesce(data -> 'countries', '[]'))), '{}')
    ),
    original_language = coalesce(original_language, data ->> 'original_language'),
    runtime_minutes = coalesce(runtime_minutes, (data ->> 'runtime')::smallint),
    budget_usd = coalesce(budget_usd, nullif((data ->> 'budget')::bigint, 0)),
    revenue_usd = coalesce(revenue_usd, nullif((data ->> 'revenue')::bigint, 0)),
    tmdb_content_rating = coalesce(tmdb_content_rating, data ->> 'content_rating'),
    poster_path = coalesce(poster_path, data ->> 'poster_path'),
    tmdb_trailer_youtube_key = coalesce(tmdb_trailer_youtube_key, trailer ->> 'youtube_key'),
    tmdb_trailer_version = coalesce(tmdb_trailer_version, trailer ->> 'version'),
    metadata_updated_at = import_movie.reference_time
  where id = target_id;

  if not exists (select 1 from public.movie_genres where movie_id = target_id) then
    insert into public.genres (tmdb_id, name, slug)
    select (genre ->> 'tmdb_id')::integer, genre ->> 'name', private.slugify(genre ->> 'english_name')
    from jsonb_array_elements(coalesce(data -> 'genres', '[]')) as genre
    on conflict (tmdb_id) do nothing;

    insert into public.movie_genres (movie_id, genre_id, position)
    select target_id, (listed.genre ->> 'tmdb_id')::integer, min(listed.position)
    from jsonb_array_elements(coalesce(data -> 'genres', '[]')) with ordinality as listed (genre, position)
    group by (listed.genre ->> 'tmdb_id')::integer;
  end if;

  if not exists (select 1 from public.credits where movie_id = target_id) then
    for credit in
      select credited.person, credited.type, credited.character, credited.cast_order
      from (
        select first_five.person, 'cast'::public.credit_type as type, first_five.character,
          first_five.cast_order, 1 as group_position, first_five.cast_order::bigint as position
        from (
          select per_person.*
          from (
            select distinct on ((listed.credit #>> '{person,tmdb_id}')::integer)
              listed.credit -> 'person' as person,
              listed.credit ->> 'character' as character,
              (listed.credit ->> 'order')::integer as cast_order
            from jsonb_array_elements(coalesce(data #> '{credits,cast}', '[]')) as listed (credit)
            order by (listed.credit #>> '{person,tmdb_id}')::integer,
              (listed.credit ->> 'order')::integer
          ) as per_person
          order by per_person.cast_order, (per_person.person ->> 'tmdb_id')::integer
          limit 5
        ) as first_five
        union all
        select listed.credit -> 'person', 'director', null, null, 2, listed.position
        from jsonb_array_elements(coalesce(data #> '{credits,directors}', '[]'))
          with ordinality as listed (credit, position)
      ) as credited
      order by credited.group_position, credited.position
    loop
      insert into public.people (tmdb_id, name, photo_path, imported_at)
      values (
        (credit.person ->> 'tmdb_id')::integer,
        credit.person ->> 'name',
        credit.person ->> 'photo_path',
        import_movie.reference_time
      )
      on conflict (tmdb_id) do nothing;

      insert into public.credits (movie_id, person_id, type, character, cast_order)
      select target_id, person.id, credit.type, credit.character, credit.cast_order
      from public.people as person
      where person.tmdb_id = (credit.person ->> 'tmdb_id')::integer
      on conflict on constraint credits_one_per_type do nothing;
    end loop;
  end if;
end;
$$;

-- The accepted movies of a successful reading enter the catalog, the values
-- their main source informed are recorded, and their values are chosen
-- again. Each movie enters through the first of the reading's entries for it
-- that brings TMDB data, preferring one with the titles, and each source
-- value comes from the first entry that informs it. A trailer from another
-- service than YouTube is discarded, and one without a version counts as
-- dubbed, so that a subtitled one is never assumed.
create function private.record_reading_movies(
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
    where listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
      and listed.value ? 'tmdb'
    order by (listed.value ->> 'tmdb_id')::integer,
      listed.value #>> '{tmdb,title}' is null,
      listed.position
  loop
    perform private.import_movie(movie, record_reading_movies.reference_time);
  end loop;

  insert into public.source_values (movie_id, source_id, data, value, trailer_version, reading_id, informed_at)
  select accepted.id, chosen_source_id, informed.data, informed.value, informed.trailer_version,
    chosen_reading_id, record_reading_movies.reference_time
  from (
    select distinct on (entry.tmdb_id, entry.data) entry.tmdb_id, entry.data, entry.value,
      entry.trailer_version
    from (
      select (listed.value ->> 'tmdb_id')::integer as tmdb_id, listed.position, given.data,
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
      where listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
        and given.value is not null
    ) as entry
    order by entry.tmdb_id, entry.data, entry.position
  ) as informed
  join public.movies as accepted on accepted.tmdb_id = informed.tmdb_id
  on conflict (movie_id, source_id, data) do update
  set value = excluded.value,
    trailer_version = excluded.trailer_version,
    reading_id = excluded.reading_id,
    informed_at = excluded.informed_at;

  for accepted_movie_id in
    select distinct accepted.id
    from jsonb_array_elements(reading -> 'movies') as listed (value)
    join public.movies as accepted on accepted.tmdb_id = (listed.value ->> 'tmdb_id')::integer
    where listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
  loop
    perform private.choose_movie_values(accepted_movie_id);
  end loop;
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
create function public.update_source_reliability(reference_time timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  initial public.source_type[] := private.initial_source_ranking();
  types integer := array_length(private.initial_source_ranking(), 1);
  counts jsonb;
  compared integer[] := '{}';
  divergences integer[] := '{}';
  ordered integer[] := '{}';
  ranking integer[] := '{}';
  previous public.source_type[];
  current_ranking public.source_type[];
  changed boolean;
  new_calculation_id bigint;
  next_eligible integer := 1;
  slot integer;
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

-- Records a reading of the reserved cinema. The reading follows the contract,
-- already checked by the ingestion. A successful reading replaces the
-- cinema's whole showtimes, and a failed one erases them. The movies it
-- accepts enter the catalog, with the source values. Returns the result with the alerts to send, or a
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

  effective := private.with_resolved_source_titles(record_reading.reading, target.cinema_id);

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

  -- The accepted movies enter the catalog with what the source informed about
  -- them, before their sessions.
  if failure is null then
    perform private.record_reading_movies(
      effective,
      target.id,
      target.source_id,
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

-- The movies with sessions in the showtimes, with their catalog data and the
-- chosen content rating, overview and trailer. poster and photo are paths in
-- the images bucket. The budget and the revenue never reach the site in v1.
create or replace view public.site_movies
with (security_invoker = true)
as
select movie.slug,
  movie.tmdb_id,
  movie.title,
  movie.original_title,
  movie.imdb_id,
  movie.year,
  movie.countries,
  movie.original_language,
  movie.runtime_minutes,
  movie.overview,
  poster.storage_path as poster,
  case when movie.trailer_youtube_key is not null then
    jsonb_build_object('youtube_key', movie.trailer_youtube_key, 'version', movie.trailer_version)
  end as trailer,
  coalesce((
    select jsonb_agg(jsonb_build_object('slug', genre.slug, 'name', genre.name) order by listed.position)
    from public.movie_genres as listed
    join public.genres as genre on genre.tmdb_id = listed.genre_id
    where listed.movie_id = movie.id
  ), '[]') as genres,
  coalesce((
    select jsonb_agg(
      jsonb_build_object('tmdb_id', person.tmdb_id, 'name', person.name, 'photo', photo.storage_path)
      order by credit.id
    )
    from public.credits as credit
    join public.people as person on person.id = credit.person_id
    left join public.images as photo on photo.tmdb_path = person.photo_path
    where credit.movie_id = movie.id and credit.type = 'director'
  ), '[]') as directors,
  coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'tmdb_id', person.tmdb_id,
        'name', person.name,
        'character', credit.character,
        'photo', photo.storage_path
      )
      order by credit.cast_order, person.tmdb_id
    )
    from public.credits as credit
    join public.people as person on person.id = credit.person_id
    left join public.images as photo on photo.tmdb_path = person.photo_path
    where credit.movie_id = movie.id and credit.type = 'cast'
  ), '[]') as "cast",
  movie.content_rating
from public.movies as movie
left join public.images as poster on poster.tmdb_path = movie.poster_path
where exists (
  select 1
  from public.sessions as session
  join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
  where session.movie_id = movie.id
);

revoke all on public.site_movies from anon, authenticated;

revoke all on function public.update_source_reliability(timestamptz) from anon, authenticated, public;
grant execute on function public.update_source_reliability(timestamptz) to service_role;
grant execute on function private.initial_source_ranking() to service_role;
grant execute on function private.source_type_name(public.source_type) to service_role;
grant execute on function private.source_ranking() to service_role;
grant execute on function private.youtube_key(text) to service_role;
grant execute on function private.best_source_value(bigint, public.source_value_data) to service_role;
grant execute on function private.choose_movie_values(bigint) to service_role;
grant execute on function private.record_reading_movies(jsonb, uuid, bigint, timestamptz) to service_role;
