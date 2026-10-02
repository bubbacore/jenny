-- Movies, sessions and box office prices, and the recording of a successful
-- reading, which replaces the cinema's whole programação.

create extension if not exists unaccent with schema extensions;

-- For now a movie holds only what accepting sessions needs. The rest of the
-- collection arrives with the full movie data.
create table public.movies (
  id bigint generated always as identity primary key,
  tmdb_id integer not null unique check (tmdb_id > 0),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title text not null check (btrim(title) <> ''),
  original_title text not null check (btrim(original_title) <> '')
);

comment on column public.movies.title is 'The title in Brazil, from TMDB.';

create type public.session_audio as enum ('dubbed', 'subtitled', 'original');
create type public.session_format as enum ('2d', '3d', 'imax');

-- starts_at is local time in the cinema's city. A session belongs to the
-- calendar date it starts on, including the small hours.
create table public.sessions (
  id bigint generated always as identity primary key,
  cinema_id bigint not null references public.cinemas,
  movie_id bigint not null references public.movies,
  reading_id uuid not null references public.readings,
  starts_at timestamp not null,
  date date not null generated always as (starts_at::date) stored,
  room text check (btrim(room) <> ''),
  audio public.session_audio,
  format public.session_format,
  tags text[] not null default '{}' check (array_position(tags, null) is null),
  external_id text check (btrim(external_id) <> ''),
  constraint sessions_are_unique
    unique nulls not distinct (cinema_id, movie_id, starts_at, room, audio, format)
);

create index sessions_movie_id_idx on public.sessions (movie_id);
create index sessions_reading_id_idx on public.sessions (reading_id);

create type public.ticket_type as enum ('full', 'half', 'promo');

-- price_cents is the box office price, without the convenience fee, which is
-- never recorded.
create table public.box_office_prices (
  id bigint generated always as identity primary key,
  session_id bigint not null references public.sessions on delete cascade,
  ticket_type public.ticket_type not null,
  source_ticket text not null check (btrim(source_ticket) <> ''),
  price_cents integer not null check (price_cents > 0),
  constraint box_office_prices_one_per_source_ticket unique (session_id, source_ticket)
);

alter table public.movies enable row level security;
alter table public.sessions enable row level security;
alter table public.box_office_prices enable row level security;
revoke all on public.movies, public.sessions, public.box_office_prices from anon, authenticated;

create function private.slugify(value text)
returns text
language sql
stable
set search_path = ''
as $$
  select btrim(
    regexp_replace(lower(extensions.unaccent('extensions.unaccent'::regdictionary, value)), '[^a-z0-9]+', '-', 'g'),
    '-'
  );
$$;

-- The movie's address comes from its title in Brazil and never changes. When
-- another movie already has it, the TMDB id tells them apart.
create function private.new_movie_slug(title text, tmdb_id integer)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  base text := coalesce(nullif(private.slugify(title), ''), 'filme');
begin
  if exists (select 1 from public.movies where slug = base) then
    return base || '-' || tmdb_id;
  end if;
  return base;
end;
$$;

-- Records a successful reading of the reserved cinema. The reading follows the
-- contract, already checked by the ingestion. Returns the result, or a refusal
-- when the reservation does not allow it or the reading does not fit the
-- database.
create function public.record_reading(
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
  previous integer;
  movie jsonb;
  entry record;
  new_session_id bigint;
  received integer := jsonb_array_length(record_reading.reading -> 'sessions');
  discarded integer := 0;
  retained integer := 0;
  accepted integer := 0;
begin
  select recorded.id, recorded.status, recorded.started_at, recorded.cinema_id,
    cinema.slug as cinema_slug, source.type::text as source_type, city.timezone
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
  -- at least one of the reading's entries for it.
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
    where listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
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

  -- The previous reading is the last successful one that finished before this
  -- one started.
  select sessions_accepted
  into previous
  from public.readings
  where cinema_id = target.cinema_id
    and status = 'success'
    and finished_at <= target.started_at
  order by finished_at desc
  limit 1;

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

  delete from public.sessions where cinema_id = target.cinema_id;

  -- A session is accepted only when the proposed TMDB id matches the top
  -- search result. Otherwise it is retained and stays out of the programação.
  for entry in
    select listed_session.value as session,
      (listed_session.value ->> 'starts_at')::timestamp as starts_at,
      accepted_movie.id as movie_id
    from jsonb_array_elements(record_reading.reading -> 'sessions') as listed_session (value)
    join jsonb_array_elements(record_reading.reading -> 'movies') as listed_movie (value)
      on listed_movie.value ->> 'key' = listed_session.value ->> 'movie_key'
    left join public.movies as accepted_movie
      on listed_movie.value -> 'tmdb_id' = listed_movie.value -> 'tmdb_search_top_id'
      and accepted_movie.tmdb_id = (listed_movie.value ->> 'tmdb_id')::integer
  loop
    if entry.starts_at::date not between today and today + 6 then
      discarded := discarded + 1;
    elsif entry.movie_id is null then
      retained := retained + 1;
    else
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

      accepted := accepted + 1;
    end if;
  end loop;

  update public.readings
  set status = 'success',
    collection_release = record_reading.collection_release,
    finished_at = record_reading.reference_time,
    sessions_received = received,
    sessions_discarded = discarded,
    sessions_accepted = accepted,
    sessions_retained = retained,
    previous_sessions = previous,
    alerts = '[]'
  where id = target.id;

  return jsonb_build_object(
    'reading_id', target.id,
    'result', 'success',
    'sessions', jsonb_build_object(
      'received', received,
      'discarded', discarded,
      'accepted', accepted,
      'retained', retained
    ),
    'alerts', '[]'::jsonb
  );
end;
$$;

revoke all on function public.record_reading(uuid, text, jsonb, timestamptz) from anon, authenticated, public;
grant execute on function public.record_reading(uuid, text, jsonb, timestamptz) to service_role;
grant execute on function private.slugify(text) to service_role;
grant execute on function private.new_movie_slug(text, integer) to service_role;
