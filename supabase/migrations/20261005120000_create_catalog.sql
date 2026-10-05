-- The catalog: each movie that enters through a reading arrives with its TMDB
-- data, its credits and its images, and the collection plan points out what
-- is still missing in the known movies.

-- The images the Hermes downloads from TMDB and the ingestion keeps in
-- Storage, in a bucket without public read. The site build reads them with
-- its own secret key and publishes them as files of the site.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('images', 'images', false, 2097152, array['image/jpeg', 'image/png']);

-- An image is known by its path in TMDB, kept for the reimport, and stored
-- under the same name in the bucket.
create table public.images (
  tmdb_path text primary key check (tmdb_path ~ '^/[A-Za-z0-9_-]+\.[A-Za-z0-9]+$'),
  storage_path text not null unique check (btrim(storage_path) <> ''),
  content_type text not null check (content_type in ('image/jpeg', 'image/png')),
  size_bytes integer not null check (size_bytes > 0),
  recorded_at timestamptz not null
);

-- The TMDB data of the movie. budget_usd and revenue_usd are in dollars, as
-- TMDB gives them, and TMDB's zero is recorded as absent. content_rating is
-- TMDB's certification for Brazil, and the trailer is the YouTube video chosen
-- by private.chosen_trailer.
alter table public.movies
  add column imdb_id text check (imdb_id ~ '^tt[0-9]+$'),
  add column overview text check (btrim(overview) <> ''),
  add column year smallint check (year between 1870 and 2100),
  add column countries text[] check (countries <> '{}' and array_position(countries, null) is null),
  add column original_language text check (original_language ~ '^[a-z]{2}$'),
  add column runtime_minutes smallint check (runtime_minutes > 0),
  add column budget_usd bigint check (budget_usd > 0),
  add column revenue_usd bigint check (revenue_usd > 0),
  add column content_rating text check (content_rating in ('L', '10', '12', '14', '16', '18')),
  add column poster_path text references public.images,
  add column trailer_youtube_key text check (btrim(trailer_youtube_key) <> ''),
  add column trailer_version text check (trailer_version in ('subtitled', 'dubbed', 'original')),
  add column metadata_updated_at timestamptz,
  add constraint movies_trailer_has_version
    check ((trailer_youtube_key is null) = (trailer_version is null));

create index movies_poster_path_idx on public.movies (poster_path);

-- name is the Portuguese name shown on the site, and slug is TMDB's English
-- name normalized for the genre parameter, like science-fiction.
create table public.genres (
  tmdb_id integer primary key check (tmdb_id > 0),
  name text not null check (btrim(name) <> ''),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

create table public.movie_genres (
  movie_id bigint not null references public.movies on delete cascade,
  genre_id integer not null references public.genres,
  position smallint not null check (position > 0),
  primary key (movie_id, genre_id)
);

create index movie_genres_genre_id_idx on public.movie_genres (genre_id);

-- A person is unique in the catalog, whatever the number of credits.
create table public.people (
  id bigint generated always as identity primary key,
  tmdb_id integer not null unique check (tmdb_id > 0),
  name text not null check (btrim(name) <> ''),
  photo_path text references public.images,
  imported_at timestamptz not null,
  reimported_at timestamptz
);

create index people_photo_path_idx on public.people (photo_path);

create type public.credit_type as enum ('cast', 'director');

-- Someone who acts in and directs the same movie has two credits in it. Only
-- the cast keeps the character and TMDB's order.
create table public.credits (
  id bigint generated always as identity primary key,
  movie_id bigint not null references public.movies on delete cascade,
  person_id bigint not null references public.people,
  type public.credit_type not null,
  character text check (btrim(character) <> ''),
  cast_order integer check (cast_order >= 0),
  constraint credits_one_per_type unique (movie_id, person_id, type),
  constraint credits_order_only_in_cast check ((type = 'cast') = (cast_order is not null)),
  constraint credits_character_only_in_cast check (type = 'cast' or character is null)
);

create index credits_person_id_idx on public.credits (person_id);

alter table public.images enable row level security;
alter table public.genres enable row level security;
alter table public.movie_genres enable row level security;
alter table public.people enable row level security;
alter table public.credits enable row level security;
revoke all on public.images, public.genres, public.movie_genres, public.people, public.credits
  from anon, authenticated;

-- Records an image already uploaded to the bucket. A new upload of the same
-- TMDB path replaces it.
create function public.record_image(
  tmdb_path text,
  storage_path text,
  content_type text,
  size_bytes integer,
  reference_time timestamptz default now()
)
returns void
language sql
set search_path = ''
as $$
  insert into public.images (tmdb_path, storage_path, content_type, size_bytes, recorded_at)
  values (tmdb_path, storage_path, content_type, size_bytes, reference_time)
  on conflict on constraint images_pkey do update
  set storage_path = excluded.storage_path,
    content_type = excluded.content_type,
    size_bytes = excluded.size_bytes,
    recorded_at = excluded.recorded_at;
$$;

-- The YouTube trailer of a movie, with its version. In a movie not spoken in
-- Portuguese, the version comes before the origin: subtitled in Portuguese,
-- then dubbed in Portuguese, then the original language. A Portuguese trailer
-- without a version counts as dubbed. In a Portuguese movie, any Portuguese
-- trailer is the original. Within the same version, the official trailer
-- comes first, and then the most recent. A trailer from another site is
-- discarded. Returns null without any eligible trailer.
create function private.chosen_trailer(trailers jsonb, original_language text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('youtube_key', candidate.key, 'version', candidate.version)
  from (
    select trailer ->> 'key' as key,
      case
        when chosen_trailer.original_language = 'pt' then 'original'
        when trailer ->> 'language' = 'pt' then coalesce(trailer ->> 'version', 'dubbed')
        else 'original'
      end as version,
      (trailer ->> 'official')::boolean as official,
      (trailer ->> 'published_at')::timestamptz as published_at
    from jsonb_array_elements(coalesce(trailers, '[]')) as trailer
    where trailer ->> 'site' = 'YouTube'
      and (
        trailer ->> 'language' = 'pt'
        or (
          chosen_trailer.original_language <> 'pt'
          and trailer ->> 'language' = chosen_trailer.original_language
        )
      )
  ) as candidate
  order by array_position(array['subtitled', 'dubbed', 'original'], candidate.version),
    candidate.official desc,
    candidate.published_at desc,
    candidate.key
  limit 1;
$$;

-- The metadata fields still missing in a movie, named as in the reading
-- contract, so that the Hermes sends only those.
create function private.missing_movie_fields(movie public.movies)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(field.name order by field.position), '[]')
  from (
    values
      (1, 'imdb_id', movie.imdb_id is null),
      (2, 'overview', movie.overview is null),
      (3, 'year', movie.year is null),
      (4, 'countries', movie.countries is null),
      (5, 'original_language', movie.original_language is null),
      (6, 'genres', not exists (select 1 from public.movie_genres where movie_id = movie.id)),
      (7, 'runtime', movie.runtime_minutes is null),
      (8, 'budget', movie.budget_usd is null),
      (9, 'revenue', movie.revenue_usd is null),
      (10, 'content_rating', movie.content_rating is null),
      (11, 'poster_path', movie.poster_path is null),
      (12, 'trailers', movie.trailer_youtube_key is null),
      (13, 'credits', not exists (select 1 from public.credits where movie_id = movie.id))
  ) as field (position, name, missing)
  where field.missing;
$$;

-- The images cited by the reading that were not recorded before it, one
-- issue for each.
create function private.unrecorded_images(reading jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'path', cited.path,
      'message', 'A imagem não foi gravada. Grave-a com record-image antes de registrar a leitura.'
    )
    order by cited.movie_position, cited.group_position, cited.position
  ), '[]')
  from (
    select listed.position as movie_position, 0 as group_position, 0::bigint as position,
      format('/reading/movies/%s/tmdb/poster_path', listed.position - 1) as path,
      listed.value #>> '{tmdb,poster_path}' as tmdb_path
    from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
    union all
    select listed.position, credited.group_position, credit.position,
      format(
        '/reading/movies/%s/tmdb/credits/%s/%s/person/photo_path',
        listed.position - 1,
        credited.name,
        credit.position - 1
      ),
      credit.value #>> '{person,photo_path}'
    from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
    cross join (values (1, 'cast'), (2, 'directors')) as credited (group_position, name)
    cross join jsonb_array_elements(coalesce(listed.value #> array['tmdb', 'credits', credited.name], '[]'))
      with ordinality as credit (value, position)
  ) as cited
  where cited.tmdb_path is not null
    and not exists (select 1 from public.images where tmdb_path = cited.tmdb_path);
$$;

-- Imports a movie of the reading into the catalog. A new movie is recorded
-- with everything the entry brings. A known movie gets only the fields still
-- missing in it, and its people only when it has no credits yet. A person
-- already in the catalog gets only the new credit. The cast keeps the first
-- five by TMDB's order, and every director.
create function private.import_movie(entry jsonb, reference_time timestamptz)
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
    overview = coalesce(overview, data ->> 'overview'),
    year = coalesce(year, (data ->> 'year')::smallint),
    countries = coalesce(
      countries,
      nullif(array(select jsonb_array_elements_text(coalesce(data -> 'countries', '[]'))), '{}')
    ),
    original_language = coalesce(original_language, data ->> 'original_language'),
    runtime_minutes = coalesce(runtime_minutes, (data ->> 'runtime')::smallint),
    budget_usd = coalesce(budget_usd, nullif((data ->> 'budget')::bigint, 0)),
    revenue_usd = coalesce(revenue_usd, nullif((data ->> 'revenue')::bigint, 0)),
    content_rating = coalesce(content_rating, data ->> 'content_rating'),
    poster_path = coalesce(poster_path, data ->> 'poster_path'),
    trailer_youtube_key = coalesce(trailer_youtube_key, trailer ->> 'youtube_key'),
    trailer_version = coalesce(trailer_version, trailer ->> 'version'),
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

-- Records a reading of the reserved cinema. The reading follows the contract,
-- already checked by the ingestion. A successful reading replaces the
-- cinema's whole showtimes, and a failed one erases them. The movies it
-- accepts enter the catalog. Returns the result with the alerts to send, or a
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

  -- Each accepted movie enters the catalog through the first of the reading's
  -- entries for it that brings TMDB data, preferring one with the titles.
  if failure is null then
    for movie in
      select distinct on ((listed.value ->> 'tmdb_id')::integer) listed.value
      from jsonb_array_elements(effective -> 'movies') with ordinality as listed (value, position)
      where listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
        and listed.value ? 'tmdb'
      order by (listed.value ->> 'tmdb_id')::integer,
        listed.value #>> '{tmdb,title}' is null,
        listed.position
    loop
      perform private.import_movie(movie, record_reading.reference_time);
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

-- The plan also returns every movie in the catalog, with the metadata fields
-- still missing in it. A movie outside the list is new, and the Hermes
-- imports it whole.
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

-- The movies with sessions in the showtimes, now with their catalog data.
-- poster and photo are paths in the images bucket. The budget, the revenue
-- and the content rating stay out: the first two never reach the site in v1,
-- and the content rating waits for the choice between TMDB and the main
-- sources.
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
  ), '[]') as "cast"
from public.movies as movie
left join public.images as poster on poster.tmdb_path = movie.poster_path
where exists (
  select 1
  from public.sessions as session
  join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
  where session.movie_id = movie.id
);

revoke all on public.site_movies from anon, authenticated;

revoke all on function public.record_image(text, text, text, integer, timestamptz)
  from anon, authenticated, public;
grant execute on function public.record_image(text, text, text, integer, timestamptz)
  to service_role;
grant execute on function private.chosen_trailer(jsonb, text) to service_role;
grant execute on function private.missing_movie_fields(public.movies) to service_role;
grant execute on function private.unrecorded_images(jsonb) to service_role;
grant execute on function private.import_movie(jsonb, timestamptz) to service_role;
