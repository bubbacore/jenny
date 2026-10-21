-- Each movie now keeps whether Rotten Tomatoes gave it Certified Fresh, read
-- from the movie page on the Rotten Tomatoes site with the Tomatometer, so
-- that the movie page shows the logo of the seal. A change of Certified Fresh
-- counts as a change of the ratings in the collection, and the site reads it
-- from the view of the movies.

-- Whether Rotten Tomatoes gave the movie Certified Fresh. The seal belongs to
-- the Tomatometer read from the Rotten Tomatoes site, because OMDb does not
-- report it, so a movie without that Tomatometer never has it.
alter table public.movies
  add column certified_fresh boolean not null default false,
  add constraint movies_certified_fresh_has_rotten_tomatoes_site_tomatometer
    check (not certified_fresh or tomatometer_source = 'rotten_tomatoes_site');

-- Records the ratings of the movies, each with the IMDb rating and its votes,
-- or null without one, the Tomatometer with its origin and Certified Fresh,
-- or null without one, and the Rotten Tomatoes link with its kind, or null to
-- erase the stored one. A null Tomatometer also erases the stored Certified
-- Fresh, and a Tomatometer sent without Certified Fresh, as the Hermes sent it
-- before the seal, counts as one without it. Inside a collection, it records
-- whether a stored rating, Certified Fresh or link changed, for the end of the
-- collection. Without a collection, as in the weekly routine before ratings
-- moved into the collections, it affects no site publication, and a movie sent
-- without the link keeps the stored one. Every movie must be in the catalog,
-- or nothing is recorded. Returns the number of movies updated, or a refusal.
create or replace function public.update_ratings(
  movies jsonb,
  collection_id uuid default null,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  collection_finished_at timestamptz;
  unknown jsonb;
  updated integer;
  changed boolean;
begin
  if update_ratings.collection_id is not null then
    select collection.finished_at into collection_finished_at
    from public.collections as collection
    where collection.id = update_ratings.collection_id
    for update;

    if not found then
      return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_collection'));
    end if;
    if collection_finished_at is not null then
      return jsonb_build_object('refusal', jsonb_build_object('code', 'collection_finished'));
    end if;
  end if;

  select jsonb_agg(listed.index - 1 order by listed.index)
  into unknown
  from jsonb_array_elements(update_ratings.movies) with ordinality as listed (value, index)
  where not exists (
    select 1 from public.movies as movie where movie.tmdb_id = (listed.value ->> 'tmdb_id')::integer
  );

  if unknown is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_movie', 'indexes', unknown));
  end if;

  -- The main query still sees the movies as they were before the update, so
  -- it compares the stored values with the new ones.
  with listed as (
    select (value ->> 'tmdb_id')::integer as tmdb_id,
      (value #>> '{imdb,rating}')::numeric as imdb_rating,
      (value #>> '{imdb,votes}')::integer as imdb_votes,
      (value #>> '{tomatometer,score}')::smallint as tomatometer,
      value #>> '{tomatometer,source}' as tomatometer_source,
      coalesce((value #>> '{tomatometer,certified_fresh}')::boolean, false) as certified_fresh,
      value ? 'rotten_tomatoes_link' as sends_link,
      value #>> '{rotten_tomatoes_link,url}' as rotten_tomatoes_url,
      value #>> '{rotten_tomatoes_link,kind}' as rotten_tomatoes_url_kind
    from jsonb_array_elements(update_ratings.movies) as listed (value)
  ),
  stored as (
    update public.movies as movie
    set imdb_rating = listed.imdb_rating,
      imdb_votes = listed.imdb_votes,
      tomatometer = listed.tomatometer,
      tomatometer_source = listed.tomatometer_source,
      certified_fresh = listed.certified_fresh,
      rotten_tomatoes_url = case
        when listed.sends_link then listed.rotten_tomatoes_url
        else movie.rotten_tomatoes_url
      end,
      rotten_tomatoes_url_kind = case
        when listed.sends_link then listed.rotten_tomatoes_url_kind
        else movie.rotten_tomatoes_url_kind
      end,
      ratings_updated_at = update_ratings.reference_time
    from listed
    where movie.tmdb_id = listed.tmdb_id
    returning movie.id, movie.imdb_rating, movie.imdb_votes, movie.tomatometer,
      movie.tomatometer_source, movie.certified_fresh, movie.rotten_tomatoes_url,
      movie.rotten_tomatoes_url_kind
  )
  select count(*)::integer,
    coalesce(bool_or(
      (stored.imdb_rating, stored.imdb_votes, stored.tomatometer, stored.tomatometer_source,
        stored.certified_fresh, stored.rotten_tomatoes_url, stored.rotten_tomatoes_url_kind)
      is distinct from
      (previous.imdb_rating, previous.imdb_votes, previous.tomatometer, previous.tomatometer_source,
        previous.certified_fresh, previous.rotten_tomatoes_url, previous.rotten_tomatoes_url_kind)
    ), false)
  into updated, changed
  from stored
  join public.movies as previous on previous.id = stored.id;

  if changed and update_ratings.collection_id is not null then
    update public.collections
    set ratings_changed = true
    where id = update_ratings.collection_id;
  end if;

  return jsonb_build_object('updated_movies', updated);
end;
$$;

-- The movies with sessions in the showtimes, with their catalog data, the
-- chosen content rating, overview and trailer, the ratings, the Rotten
-- Tomatoes link, which is the movie page or the site search, and whether the
-- movie has Certified Fresh. poster and photo are paths in the images bucket.
-- The budget and the revenue never reach the site in v1.
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
  movie.tomatometer,
  movie.rotten_tomatoes_url,
  movie.certified_fresh
from public.movies as movie
left join public.images as poster on poster.tmdb_path = movie.poster_path
where exists (
  select 1
  from public.sessions as session
  join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
  where session.movie_id = movie.id
);

revoke all on public.site_movies from anon, authenticated;
