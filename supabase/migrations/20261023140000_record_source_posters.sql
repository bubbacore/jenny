-- A movie without TMDB shows the poster of its main source, as ADR 0017 of
-- bubbacore/dan decides. The Hermes downloads it and sends it to the image
-- record before the reading that cites it, as it does with the TMDB images.

-- A source poster is known by its address in the main source, the way a TMDB
-- image is known by its path in TMDB, and is stored in the same images bucket
-- under a name drawn from that address. It has a table of its own because a
-- movie without TMDB has no TMDB path to key it.
create table public.source_posters (
  source_url text primary key check (source_url ~ '^https?://'),
  storage_path text not null unique check (storage_path ~ '^source-[0-9a-f]{64}\.(jpg|png)$'),
  content_type text not null check (content_type in ('image/jpeg', 'image/png')),
  size_bytes integer not null check (size_bytes > 0),
  recorded_at timestamptz not null
);

alter table public.source_posters enable row level security;
revoke all on public.source_posters from anon, authenticated;

-- Only a movie without TMDB has a source poster; a TMDB movie keeps the TMDB
-- poster, which the reimport renews.
alter table public.movies
  add column source_poster_url text references public.source_posters,
  add constraint movies_source_poster_only_without_tmdb
    check (source_poster_url is null or tmdb_id is null);

create index movies_source_poster_url_idx on public.movies (source_poster_url);

comment on column public.movies.source_poster_url is
  'The address in the main source of the poster of a movie without TMDB.';

-- Records a source poster already uploaded to the bucket. A new upload of the
-- same address replaces it.
create function public.record_source_poster(
  source_url text,
  storage_path text,
  content_type text,
  size_bytes integer,
  reference_time timestamptz default now()
)
returns void
language sql
set search_path = ''
as $$
  insert into public.source_posters (source_url, storage_path, content_type, size_bytes, recorded_at)
  values (source_url, storage_path, content_type, size_bytes, reference_time)
  on conflict on constraint source_posters_pkey do update
  set storage_path = excluded.storage_path,
    content_type = excluded.content_type,
    size_bytes = excluded.size_bytes,
    recorded_at = excluded.recorded_at;
$$;

-- The images cited by the reading that were not recorded before it, one
-- issue for each: the TMDB poster and photos and the source poster of a movie
-- without TMDB.
create or replace function private.unrecorded_images(reading jsonb)
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
      listed.value #>> '{tmdb,poster_path}' as tmdb_path,
      null::text as source_url
    from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
    union all
    select listed.position, credited.group_position, credit.position,
      format(
        '/reading/movies/%s/tmdb/credits/%s/%s/person/photo_path',
        listed.position - 1,
        credited.name,
        credit.position - 1
      ),
      credit.value #>> '{person,photo_path}',
      null
    from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
    cross join (values (1, 'cast'), (2, 'directors')) as credited (group_position, name)
    cross join jsonb_array_elements(coalesce(listed.value #> array['tmdb', 'credits', credited.name], '[]'))
      with ordinality as credit (value, position)
    union all
    select listed.position, 3, 0,
      format('/reading/movies/%s/without_tmdb/poster', listed.position - 1),
      null,
      listed.value #>> '{without_tmdb,poster}'
    from jsonb_array_elements(reading -> 'movies') with ordinality as listed (value, position)
  ) as cited
  where (
      cited.tmdb_path is not null
      and not exists (select 1 from public.images where tmdb_path = cited.tmdb_path)
    )
    or (
      cited.source_url is not null
      and not exists (select 1 from public.source_posters where source_url = cited.source_url)
    );
$$;

-- A movie without TMDB enters the catalog with the source data of the reading
-- in which it first appears: the title without the language and format
-- markers, the original title or, without one, the same title, the year, the
-- duration and the poster. Later readings only fill in what is missing.
create or replace function private.import_movie_without_tmdb(entry jsonb, reference_time timestamptz)
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
    source_poster_url = coalesce(source_poster_url, data ->> 'poster'),
    metadata_updated_at = import_movie_without_tmdb.reference_time
  where id = target_id;
end;
$$;

-- The source data a movie without TMDB still lacks, named as in the reading.
create or replace function private.missing_movie_without_tmdb_fields(movie public.movies)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(field.name order by field.position), '[]')
  from (
    values
      (1, 'year', movie.year is null),
      (2, 'duration_minutes', movie.runtime_minutes is null),
      (3, 'poster', movie.source_poster_url is null)
  ) as field (position, name, missing)
  where field.missing;
$$;

-- The movies with sessions in the showtimes, with their catalog data, the
-- chosen content rating, overview and trailer, the ratings, the Rotten
-- Tomatoes link, which is the movie page or the site search, and whether the
-- movie has Certified Fresh. poster and photo are paths in the images bucket,
-- and the poster of a movie without TMDB is its source poster. The budget and
-- the revenue never reach the site in v1.
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
  coalesce(poster.storage_path, source_poster.storage_path) as poster,
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
  movie.content_rating,
  movie.imdb_rating,
  movie.imdb_votes,
  movie.tomatometer,
  movie.rotten_tomatoes_url,
  movie.certified_fresh
from public.movies as movie
left join public.images as poster on poster.tmdb_path = movie.poster_path
left join public.source_posters as source_poster on source_poster.source_url = movie.source_poster_url
where exists (
  select 1
  from public.sessions as session
  join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
  where session.movie_id = movie.id
);

revoke all on function public.record_source_poster(text, text, text, integer, timestamptz)
  from anon, authenticated, public;
grant execute on function public.record_source_poster(text, text, text, integer, timestamptz)
  to service_role;
