-- The movie's address comes from its original title in TMDB instead of its
-- title in Brazil, and the movies already in the catalog get the new address.

-- The movie's address follows the original language of its title. A title
-- without any letter or digit, like one in Japanese, falls back to the title
-- in Brazil. When another movie already has the address, the movie's year
-- tells them apart; when the year is missing or repeats, the TMDB id does.
-- The address is recorded when the movie enters the catalog and never
-- changes.
create function private.new_movie_slug(
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

  return base || '-' || new_movie_slug.tmdb_id;
end;
$$;

drop function private.new_movie_slug(text, integer);

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
      private.new_movie_slug(
        data ->> 'original_title',
        data ->> 'title',
        (data ->> 'year')::smallint,
        chosen_tmdb_id
      ),
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

-- The movies already in the catalog get the new address in the order they
-- entered it. The site is not published yet, so no old address needs a
-- redirect. The temporary addresses free the old ones first.
update public.movies set slug = 'address-rewrite-' || id;

do $$
declare
  movie record;
begin
  for movie in select id, original_title, title, year, tmdb_id from public.movies order by id loop
    update public.movies
    set slug = private.new_movie_slug(movie.original_title, movie.title, movie.year, movie.tmdb_id)
    where id = movie.id;
  end loop;
end;
$$;

grant execute on function private.new_movie_slug(text, text, smallint, integer) to service_role;
