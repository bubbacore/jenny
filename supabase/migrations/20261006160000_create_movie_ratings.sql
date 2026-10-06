-- The IMDb and Rotten Tomatoes ratings of each movie, updated every week by
-- the Hermes while the movie is showing. imdb_rating is IMDb's rating with its
-- votes, and tomatometer is Rotten Tomatoes' Tomatometer with its origin:
-- OMDb or, when OMDb lacks it, the Rotten Tomatoes site.

alter table public.movies
  add column imdb_rating numeric(3, 1) check (imdb_rating between 1 and 10),
  add column imdb_votes integer check (imdb_votes > 0),
  add column tomatometer smallint check (tomatometer between 0 and 100),
  add column tomatometer_source text check (tomatometer_source in ('omdb', 'rotten_tomatoes_site')),
  add column ratings_updated_at timestamptz,
  add constraint movies_imdb_rating_has_votes
    check ((imdb_rating is null) = (imdb_votes is null)),
  add constraint movies_tomatometer_has_source
    check ((tomatometer is null) = (tomatometer_source is null));

-- Records the ratings of the movies, each with the IMDb rating and its votes,
-- or null without one, and the Tomatometer with its origin, or null without
-- one. Every movie must be in the catalog, or nothing is recorded. Returns the
-- number of movies updated, or a refusal with the index of each unknown movie.
create function public.update_ratings(
  movies jsonb,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  unknown jsonb;
  updated integer;
begin
  select jsonb_agg(listed.index - 1 order by listed.index)
  into unknown
  from jsonb_array_elements(update_ratings.movies) with ordinality as listed (value, index)
  where not exists (
    select 1 from public.movies as movie where movie.tmdb_id = (listed.value ->> 'tmdb_id')::integer
  );

  if unknown is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_movie', 'indexes', unknown));
  end if;

  update public.movies as movie
  set imdb_rating = (listed.value #>> '{imdb,rating}')::numeric,
    imdb_votes = (listed.value #>> '{imdb,votes}')::integer,
    tomatometer = (listed.value #>> '{tomatometer,score}')::smallint,
    tomatometer_source = listed.value #>> '{tomatometer,source}',
    ratings_updated_at = update_ratings.reference_time
  from jsonb_array_elements(update_ratings.movies) as listed (value)
  where movie.tmdb_id = (listed.value ->> 'tmdb_id')::integer;
  get diagnostics updated = row_count;

  return jsonb_build_object('updated_movies', updated);
end;
$$;

-- The movies with sessions in the showtimes, with their catalog data, the
-- chosen content rating, overview and trailer, and the ratings. poster and
-- photo are paths in the images bucket. The budget and the revenue never reach
-- the site in v1.
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
  movie.content_rating,
  movie.imdb_rating,
  movie.imdb_votes,
  movie.tomatometer
from public.movies as movie
left join public.images as poster on poster.tmdb_path = movie.poster_path
where exists (
  select 1
  from public.sessions as session
  join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
  where session.movie_id = movie.id
);

revoke all on public.site_movies from anon, authenticated;

revoke all on function public.update_ratings(jsonb, timestamptz) from anon, authenticated, public;
grant execute on function public.update_ratings(jsonb, timestamptz) to service_role;
