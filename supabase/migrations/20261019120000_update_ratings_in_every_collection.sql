-- Every collection now updates, before its end, the ratings of the movies
-- with sessions that were not updated today, and each movie keeps its Rotten
-- Tomatoes link. A recollection whose ratings update changed a stored rating
-- or link ends with a site publication, and the site shows the link next to
-- the Tomatometer.

-- The Rotten Tomatoes link of the movie, with its kind: the movie page on the
-- Rotten Tomatoes site, which the next ratings updates read directly, or the
-- site search, which they repeat until the page is found.
alter table public.movies
  add column rotten_tomatoes_url text
    check (rotten_tomatoes_url ~ '^https://www\.rottentomatoes\.com/'),
  add column rotten_tomatoes_url_kind text
    check (rotten_tomatoes_url_kind in ('movie_page', 'search')),
  add constraint movies_rotten_tomatoes_url_has_kind
    check ((rotten_tomatoes_url is null) = (rotten_tomatoes_url_kind is null));

-- Whether a ratings update of the collection changed a stored rating or
-- link, which makes a recollection end with a site publication.
alter table public.collections
  add column ratings_changed boolean not null default false;

-- The movies whose ratings the collection updates: those with sessions in
-- active cinemas, with an IMDb id, whose ratings were last updated before
-- today, in the time zone of the city of each cinema, or never. Each one comes
-- with the TMDB and IMDb ids, the original title, the year and the stored
-- Rotten Tomatoes link. A movie that could not be read stays out of the
-- update, so it comes back in the plan of the next collection.
create function public.ratings_plan(collection_id uuid, reference_time timestamptz default now())
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  collection record;
begin
  select id, finished_at into collection
  from public.collections
  where id = ratings_plan.collection_id;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_collection'));
  end if;
  if collection.finished_at is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'collection_finished'));
  end if;

  return jsonb_build_object('movies', (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'tmdb_id', movie.tmdb_id,
        'imdb_id', movie.imdb_id,
        'original_title', movie.original_title,
        'year', movie.year,
        'rotten_tomatoes_link', case when movie.rotten_tomatoes_url is not null then
          jsonb_build_object('url', movie.rotten_tomatoes_url, 'kind', movie.rotten_tomatoes_url_kind)
        end
      )
      order by movie.tmdb_id
    ), '[]')
    from public.movies as movie
    where movie.imdb_id is not null
      and exists (
        select 1
        from public.sessions as session
        join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
        join public.cities as city on city.id = cinema.city_id
        where session.movie_id = movie.id
          and (
            movie.ratings_updated_at is null
            or (movie.ratings_updated_at at time zone city.timezone)::date
              < (ratings_plan.reference_time at time zone city.timezone)::date
          )
      )
  ));
end;
$$;

-- The ratings update now receives the collection, so the signature changes.
drop function public.update_ratings(jsonb, timestamptz);

-- Records the ratings of the movies, each with the IMDb rating and its votes,
-- or null without one, the Tomatometer with its origin, or null without one,
-- and the Rotten Tomatoes link with its kind, or null to erase the stored
-- one. Inside a collection, it records whether a stored rating or link
-- changed, for the end of the collection. Without a collection, as in the
-- weekly routine before ratings moved into the collections, it affects no
-- site publication, and a movie sent without the link keeps the stored one.
-- Every movie must be in the catalog, or nothing is recorded. Returns the
-- number of movies updated, or a refusal.
create function public.update_ratings(
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
      movie.tomatometer_source, movie.rotten_tomatoes_url, movie.rotten_tomatoes_url_kind
  )
  select count(*)::integer,
    coalesce(bool_or(
      (stored.imdb_rating, stored.imdb_votes, stored.tomatometer, stored.tomatometer_source,
        stored.rotten_tomatoes_url, stored.rotten_tomatoes_url_kind)
      is distinct from
      (previous.imdb_rating, previous.imdb_votes, previous.tomatometer, previous.tomatometer_source,
        previous.rotten_tomatoes_url, previous.rotten_tomatoes_url_kind)
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

-- Ends the collection and decides whether it ends with a site publication.
-- The daily collection publishes; a recollection publishes only when some of
-- its readings changed result or released sessions retained by a pending
-- identification, or when its ratings update changed a stored rating or
-- link; both stay quiet while the automatic publication is suspended. A
-- manual collection publishes unless the owner asked otherwise, and when it
-- publishes it ends the suspension.
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
  select id, type, site_publication_requested, finished_at, ratings_changed into collection
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
    when 'recollection' then not suspended and (collection.ratings_changed or exists (
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
    ))
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

-- The movies with sessions in the showtimes, with their catalog data, the
-- chosen content rating, overview and trailer, the ratings and the Rotten
-- Tomatoes link, which is the movie page or the site search. poster and photo
-- are paths in the images bucket. The budget and the revenue never reach the
-- site in v1.
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
  movie.rotten_tomatoes_url
from public.movies as movie
left join public.images as poster on poster.tmdb_path = movie.poster_path
where exists (
  select 1
  from public.sessions as session
  join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
  where session.movie_id = movie.id
);

revoke all on public.site_movies from anon, authenticated;

revoke all on function public.ratings_plan(uuid, timestamptz) from anon, authenticated, public;
revoke all on function public.update_ratings(jsonb, uuid, timestamptz)
  from anon, authenticated, public;
grant execute on function public.ratings_plan(uuid, timestamptz) to service_role;
grant execute on function public.update_ratings(jsonb, uuid, timestamptz) to service_role;
