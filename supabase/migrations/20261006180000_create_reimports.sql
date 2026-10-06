-- The reimport: a new reading, in TMDB, of movies and people already in the
-- catalog. The weekly round covers the movies with sessions, and the manual
-- round the chosen movies and people, or the whole catalog. What changed is
-- updated, and what vanished from TMDB stays in the catalog, recorded as a
-- loss of the reimport.

create type public.reimport_type as enum ('weekly', 'manual');

-- A reimport starts with its plan and finishes when the Hermes sends what it
-- read in TMDB.
create table public.reimports (
  id uuid primary key default gen_random_uuid(),
  type public.reimport_type not null,
  started_at timestamptz not null,
  finished_at timestamptz,
  constraint reimports_finish_after_start check (finished_at >= started_at)
);

-- The movies of the plan, and whether the reimport covered each one.
create table public.reimport_movies (
  reimport_id uuid not null references public.reimports on delete cascade,
  movie_id bigint not null references public.movies on delete cascade,
  covered boolean not null default false,
  primary key (reimport_id, movie_id)
);

create index reimport_movies_movie_id_idx on public.reimport_movies (movie_id);

-- The people of the plan and those that came through the credits of the
-- reimported movies, outside the plan.
create table public.reimport_people (
  reimport_id uuid not null references public.reimports on delete cascade,
  person_id bigint not null references public.people on delete cascade,
  planned boolean not null,
  covered boolean not null default false,
  primary key (reimport_id, person_id)
);

create index reimport_people_person_id_idx on public.reimport_people (person_id);

-- What vanished from TMDB in a reimport and stayed in the catalog: a whole
-- movie or person, a field of the movie or of the person named as in the
-- reading contract, or a credit or the character of a cast credit. A loss is
-- new when the previous reimport that covered the same movie or person did
-- not record it, and only the new losses reach the alert.
create table public.reimport_losses (
  id bigint generated always as identity primary key,
  reimport_id uuid not null references public.reimports on delete cascade,
  movie_id bigint references public.movies on delete cascade,
  person_id bigint references public.people on delete cascade,
  field text not null,
  credit_type public.credit_type,
  new_loss boolean not null default true,
  constraint reimport_losses_once unique nulls not distinct
    (reimport_id, movie_id, person_id, field, credit_type),
  constraint reimport_losses_field_is_known check (
    (
      movie_id is not null and person_id is null and credit_type is null
      and field in (
        'movie', 'title', 'original_title', 'imdb_id', 'overview', 'year', 'countries',
        'original_language', 'genres', 'runtime', 'budget', 'revenue', 'content_rating',
        'poster_path', 'trailers', 'credits'
      )
    )
    or (
      movie_id is null and person_id is not null and credit_type is null
      and field in ('person', 'photo_path')
    )
    or (
      movie_id is not null and person_id is not null and credit_type is not null
      and (field = 'credit' or (field = 'character' and credit_type = 'cast'))
    )
  )
);

create index reimport_losses_movie_id_idx on public.reimport_losses (movie_id);
create index reimport_losses_person_id_idx on public.reimport_losses (person_id);

alter table public.reimports enable row level security;
alter table public.reimport_movies enable row level security;
alter table public.reimport_people enable row level security;
alter table public.reimport_losses enable row level security;
revoke all on public.reimports, public.reimport_movies, public.reimport_people,
  public.reimport_losses from anon, authenticated;

-- The credits a movie keeps from TMDB's credits: the first five of the cast by
-- TMDB's order, one credit per person, and every director, as in the import.
create function private.chosen_credits(credits jsonb)
returns table (person jsonb, type public.credit_type, "character" text, cast_order integer)
language sql
immutable
set search_path = ''
as $$
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
        from jsonb_array_elements(coalesce(credits -> 'cast', '[]')) as listed (credit)
        order by (listed.credit #>> '{person,tmdb_id}')::integer,
          (listed.credit ->> 'order')::integer
      ) as per_person
      order by per_person.cast_order, (per_person.person ->> 'tmdb_id')::integer
      limit 5
    ) as first_five
    union all
    select listed.credit -> 'person', 'director', null, null, 2, listed.position
    from jsonb_array_elements(coalesce(credits -> 'directors', '[]'))
      with ordinality as listed (credit, position)
  ) as credited
  order by credited.group_position, credited.position;
$$;

-- The people TMDB credits in a movie, in the cast, whatever the place, or in
-- the direction.
create function private.tmdb_credited_people(credits jsonb)
returns table (person_tmdb_id integer, type public.credit_type)
language sql
immutable
set search_path = ''
as $$
  select (listed.credit #>> '{person,tmdb_id}')::integer, 'cast'::public.credit_type
  from jsonb_array_elements(coalesce(credits -> 'cast', '[]')) as listed (credit)
  union
  select (listed.credit #>> '{person,tmdb_id}')::integer, 'director'
  from jsonb_array_elements(coalesce(credits -> 'directors', '[]')) as listed (credit);
$$;

-- Starts a reimport and returns its plan. The weekly round covers the movies
-- with sessions in active cinemas. The manual round covers the chosen movies
-- and people, even those no longer showing, or the whole catalog when nothing
-- is chosen. Returns a refusal with the index of each chosen movie or person
-- outside the catalog.
create function public.reimport_plan(
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
  where case
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

-- Reimports a person, from the plan or from the credits of a reimported movie,
-- and returns its id. data is the person in TMDB, with the name and the photo,
-- or null when TMDB no longer has the person. A person not yet in the catalog,
-- credited in a reimported movie, is imported. A photo that vanished from TMDB
-- is kept.
create function private.reimport_person(
  chosen_reimport_id uuid,
  chosen_tmdb_id integer,
  data jsonb,
  planned boolean,
  reference_time timestamptz
)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  chosen_person_id bigint;
  kept_photo_path text;
begin
  select id, photo_path
  into chosen_person_id, kept_photo_path
  from public.people
  where tmdb_id = chosen_tmdb_id
  for update;

  if not found then
    insert into public.people (tmdb_id, name, photo_path, imported_at)
    values (chosen_tmdb_id, data ->> 'name', data ->> 'photo_path', reimport_person.reference_time)
    returning id into chosen_person_id;
  elsif data is null then
    insert into public.reimport_losses (reimport_id, person_id, field)
    values (chosen_reimport_id, chosen_person_id, 'person')
    on conflict do nothing;
  else
    if kept_photo_path is not null and data ->> 'photo_path' is null then
      insert into public.reimport_losses (reimport_id, person_id, field)
      values (chosen_reimport_id, chosen_person_id, 'photo_path')
      on conflict do nothing;
    end if;

    update public.people
    set name = data ->> 'name',
      photo_path = coalesce(data ->> 'photo_path', photo_path),
      reimported_at = reimport_person.reference_time
    where id = chosen_person_id;
  end if;

  insert into public.reimport_people (reimport_id, person_id, planned, covered)
  values (chosen_reimport_id, chosen_person_id, reimport_person.planned, true)
  on conflict (reimport_id, person_id) do update set covered = true;

  return chosen_person_id;
end;
$$;

-- Reimports a movie of the plan. data is the movie in TMDB, as in the reading
-- contract, or null when TMDB no longer has the movie. Every field TMDB gives
-- replaces the catalog's, and a field the catalog has and TMDB no longer gives
-- is kept, as a loss. TMDB's zero budget or revenue counts as absent. The
-- genres are replaced when TMDB gives any. The credits are those of the
-- import: a cast member who left the first five, but is still in TMDB's cast,
-- loses the credit, and a credit whose person vanished from TMDB's cast or
-- direction is kept, as a loss. The values of the movie are then chosen
-- again, with the content rating, the overview and the trailer of TMDB.
create function private.reimport_movie(
  chosen_reimport_id uuid,
  chosen_tmdb_id integer,
  data jsonb,
  reference_time timestamptz
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  movie public.movies;
  trailer jsonb;
  given_countries text[];
  credit record;
  credited_person_id bigint;
begin
  select * into movie from public.movies where tmdb_id = chosen_tmdb_id for update;

  update public.reimport_movies
  set covered = true
  where reimport_id = chosen_reimport_id and movie_id = movie.id;

  if data is null then
    insert into public.reimport_losses (reimport_id, movie_id, field)
    values (chosen_reimport_id, movie.id, 'movie')
    on conflict do nothing;
    return;
  end if;

  trailer := private.chosen_trailer(
    data -> 'trailers',
    coalesce(data ->> 'original_language', movie.original_language)
  );
  given_countries := nullif(
    array(select jsonb_array_elements_text(coalesce(data -> 'countries', '[]'))),
    '{}'
  );

  insert into public.reimport_losses (reimport_id, movie_id, field)
  select chosen_reimport_id, movie.id, lost.field
  from (
    values
      ('title', data ->> 'title' is null),
      ('original_title', data ->> 'original_title' is null),
      ('imdb_id', movie.imdb_id is not null and data ->> 'imdb_id' is null),
      ('overview', movie.tmdb_overview is not null and data ->> 'overview' is null),
      ('year', movie.year is not null and data ->> 'year' is null),
      ('countries', movie.countries is not null and given_countries is null),
      ('original_language', movie.original_language is not null and data ->> 'original_language' is null),
      (
        'genres',
        exists (select 1 from public.movie_genres where movie_id = movie.id)
          and jsonb_array_length(coalesce(data -> 'genres', '[]')) = 0
      ),
      ('runtime', movie.runtime_minutes is not null and data ->> 'runtime' is null),
      ('budget', movie.budget_usd is not null and nullif((data ->> 'budget')::bigint, 0) is null),
      ('revenue', movie.revenue_usd is not null and nullif((data ->> 'revenue')::bigint, 0) is null),
      ('content_rating', movie.tmdb_content_rating is not null and data ->> 'content_rating' is null),
      ('poster_path', movie.poster_path is not null and data ->> 'poster_path' is null),
      ('trailers', movie.tmdb_trailer_youtube_key is not null and trailer is null),
      (
        'credits',
        exists (select 1 from public.credits where movie_id = movie.id) and data -> 'credits' is null
      )
  ) as lost (field, vanished)
  where lost.vanished
  on conflict do nothing;

  update public.movies
  set title = coalesce(data ->> 'title', title),
    original_title = coalesce(data ->> 'original_title', original_title),
    imdb_id = coalesce(data ->> 'imdb_id', imdb_id),
    tmdb_overview = coalesce(data ->> 'overview', tmdb_overview),
    year = coalesce((data ->> 'year')::smallint, year),
    countries = coalesce(given_countries, countries),
    original_language = coalesce(data ->> 'original_language', original_language),
    runtime_minutes = coalesce((data ->> 'runtime')::smallint, runtime_minutes),
    budget_usd = coalesce(nullif((data ->> 'budget')::bigint, 0), budget_usd),
    revenue_usd = coalesce(nullif((data ->> 'revenue')::bigint, 0), revenue_usd),
    tmdb_content_rating = coalesce(data ->> 'content_rating', tmdb_content_rating),
    poster_path = coalesce(data ->> 'poster_path', poster_path),
    tmdb_trailer_youtube_key = coalesce(trailer ->> 'youtube_key', tmdb_trailer_youtube_key),
    tmdb_trailer_version = coalesce(trailer ->> 'version', tmdb_trailer_version),
    metadata_updated_at = reimport_movie.reference_time
  where id = movie.id;

  if jsonb_array_length(coalesce(data -> 'genres', '[]')) > 0 then
    insert into public.genres (tmdb_id, name, slug)
    select (genre ->> 'tmdb_id')::integer, genre ->> 'name', private.slugify(genre ->> 'english_name')
    from jsonb_array_elements(data -> 'genres') as genre
    on conflict (tmdb_id) do nothing;

    delete from public.movie_genres where movie_id = movie.id;

    insert into public.movie_genres (movie_id, genre_id, position)
    select movie.id, (listed.genre ->> 'tmdb_id')::integer, min(listed.position)
    from jsonb_array_elements(data -> 'genres') with ordinality as listed (genre, position)
    group by (listed.genre ->> 'tmdb_id')::integer;
  end if;

  if data -> 'credits' is not null then
    insert into public.reimport_losses (reimport_id, movie_id, person_id, field, credit_type)
    select chosen_reimport_id, movie.id, kept.person_id, 'credit', kept.type
    from public.credits as kept
    join public.people as person on person.id = kept.person_id
    where kept.movie_id = movie.id
      and not exists (
        select 1
        from private.tmdb_credited_people(data -> 'credits') as reimported
        where reimported.person_tmdb_id = person.tmdb_id and reimported.type = kept.type
      )
    on conflict do nothing;

    delete from public.credits as dropped
    using public.people as person
    where dropped.movie_id = movie.id
      and person.id = dropped.person_id
      and exists (
        select 1
        from private.tmdb_credited_people(data -> 'credits') as reimported
        where reimported.person_tmdb_id = person.tmdb_id and reimported.type = dropped.type
      )
      and not exists (
        select 1
        from private.chosen_credits(data -> 'credits') as chosen
        where (chosen.person ->> 'tmdb_id')::integer = person.tmdb_id and chosen.type = dropped.type
      );

    for credit in select * from private.chosen_credits(data -> 'credits') loop
      credited_person_id := private.reimport_person(
        chosen_reimport_id,
        (credit.person ->> 'tmdb_id')::integer,
        credit.person,
        false,
        reimport_movie.reference_time
      );

      if credit.type = 'cast' and credit.character is null and exists (
        select 1
        from public.credits as kept
        where kept.movie_id = movie.id
          and kept.person_id = credited_person_id
          and kept.type = 'cast'
          and kept.character is not null
      ) then
        insert into public.reimport_losses (reimport_id, movie_id, person_id, field, credit_type)
        values (chosen_reimport_id, movie.id, credited_person_id, 'character', 'cast')
        on conflict do nothing;
      end if;

      insert into public.credits (movie_id, person_id, type, character, cast_order)
      values (movie.id, credited_person_id, credit.type, credit.character, credit.cast_order)
      on conflict on constraint credits_one_per_type do update
      set character = coalesce(excluded.character, credits.character),
        cast_order = excluded.cast_order;
    end loop;
  end if;

  perform private.choose_movie_values(movie.id);
end;
$$;

-- How a loss reads in the alert.
create function private.loss_text(field text, credit_type public.credit_type, person_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case field
    when 'movie' then 'o filme, que não está mais no TMDB'
    when 'person' then 'a pessoa, que não está mais no TMDB'
    when 'title' then 'o título no Brasil'
    when 'original_title' then 'o título original'
    when 'imdb_id' then 'o identificador do IMDb'
    when 'overview' then 'a sinopse'
    when 'year' then 'o ano'
    when 'countries' then 'os países'
    when 'original_language' then 'a língua original'
    when 'genres' then 'os gêneros'
    when 'runtime' then 'a duração'
    when 'budget' then 'o orçamento'
    when 'revenue' then 'a receita'
    when 'content_rating' then 'a classificação indicativa'
    when 'poster_path' then 'o pôster'
    when 'trailers' then 'o trailer'
    when 'credits' then 'os créditos'
    when 'photo_path' then 'a foto'
    when 'credit' then format(
      'o crédito de %s %s',
      person_name,
      case credit_type when 'cast' then 'no elenco' else 'na direção' end
    )
    when 'character' then format('o personagem de %s', person_name)
  end;
$$;

-- The order of the losses in the alert, as in the reading contract.
create function private.loss_position(field text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select array_position(
    array[
      'movie', 'person', 'title', 'original_title', 'imdb_id', 'overview', 'year', 'countries',
      'original_language', 'genres', 'runtime', 'budget', 'revenue', 'content_rating',
      'poster_path', 'photo_path', 'trailers', 'credits', 'credit', 'character'
    ],
    field
  );
$$;

-- Finishes a reimport of the plan with what the Hermes read in TMDB. movies
-- and people hold, for each one, the TMDB id and the data in TMDB, or null
-- when TMDB no longer has it. Every movie and person must be in the plan, and
-- every image cited must have been recorded before. Returns how many movies
-- and people the reimport covered, the number of losses and the alert with the
-- new losses, or a refusal.
create function public.reimport(
  reimport_id uuid,
  movies jsonb,
  people jsonb,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  chosen record;
  issues jsonb;
  entry jsonb;
  alert_text text;
  result jsonb;
begin
  select id, type, finished_at
  into chosen
  from public.reimports
  where id = reimport.reimport_id
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_reimport'));
  end if;
  if chosen.finished_at is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'reimport_closed'));
  end if;

  select jsonb_agg(
    jsonb_build_object('path', issue.path, 'message', issue.message)
    order by issue.group_position, issue.position, issue.path
  )
  into issues
  from (
    select 1 as group_position, listed.position, format('/movies/%s/tmdb_id', listed.position - 1) as path,
      'O filme não está no plano desta reimportação.' as message
    from jsonb_array_elements(reimport.movies) with ordinality as listed (value, position)
    where not exists (
      select 1
      from public.reimport_movies as planned
      join public.movies as movie on movie.id = planned.movie_id
      where planned.reimport_id = chosen.id
        and movie.tmdb_id = (listed.value ->> 'tmdb_id')::integer
    )
    union all
    select 2, listed.position, format('/people/%s/tmdb_id', listed.position - 1),
      'A pessoa não está no plano desta reimportação.'
    from jsonb_array_elements(reimport.people) with ordinality as listed (value, position)
    where not exists (
      select 1
      from public.reimport_people as planned
      join public.people as person on person.id = planned.person_id
      where planned.reimport_id = chosen.id
        and planned.planned
        and person.tmdb_id = (listed.value ->> 'tmdb_id')::integer
    )
    union all
    -- The movies cite their images as the movies of a reading do.
    select 3, unrecorded.position, regexp_replace(unrecorded.issue ->> 'path', '^/reading', ''),
      'A imagem não foi gravada. Grave-a com record-image antes da reimportação.'
    from jsonb_array_elements(private.unrecorded_images(jsonb_build_object('movies', reimport.movies)))
      with ordinality as unrecorded (issue, position)
    union all
    select 4, listed.position, format('/people/%s/tmdb/photo_path', listed.position - 1),
      'A imagem não foi gravada. Grave-a com record-image antes da reimportação.'
    from jsonb_array_elements(reimport.people) with ordinality as listed (value, position)
    where listed.value #>> '{tmdb,photo_path}' is not null
      and not exists (
        select 1 from public.images where tmdb_path = listed.value #>> '{tmdb,photo_path}'
      )
  ) as issue;

  if issues is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'invalid_reimport', 'issues', issues));
  end if;

  for entry in select value from jsonb_array_elements(reimport.movies) loop
    perform private.reimport_movie(
      chosen.id,
      (entry ->> 'tmdb_id')::integer,
      nullif(entry -> 'tmdb', 'null'),
      reimport.reference_time
    );
  end loop;

  for entry in select value from jsonb_array_elements(reimport.people) loop
    perform private.reimport_person(
      chosen.id,
      (entry ->> 'tmdb_id')::integer,
      nullif(entry -> 'tmdb', 'null'),
      true,
      reimport.reference_time
    );
  end loop;

  -- A loss is new unless the previous reimport that covered the same movie,
  -- or the same person for a loss of the person, recorded it too.
  update public.reimport_losses as loss
  set new_loss = not exists (
    select 1
    from public.reimport_losses as earlier
    where earlier.reimport_id = (
        select previous.id
        from public.reimports as previous
        where previous.id <> chosen.id
          and previous.finished_at is not null
          and case
            when loss.movie_id is not null then exists (
              select 1
              from public.reimport_movies as covered
              where covered.reimport_id = previous.id
                and covered.movie_id = loss.movie_id
                and covered.covered
            )
            else exists (
              select 1
              from public.reimport_people as covered
              where covered.reimport_id = previous.id
                and covered.person_id = loss.person_id
                and covered.covered
            )
          end
        order by previous.finished_at desc, previous.started_at desc
        limit 1
      )
      and earlier.movie_id is not distinct from loss.movie_id
      and earlier.person_id is not distinct from loss.person_id
      and earlier.field = loss.field
      and earlier.credit_type is not distinct from loss.credit_type
  )
  where loss.reimport_id = chosen.id;

  update public.reimports
  set finished_at = reimport.reference_time
  where id = chosen.id;

  select string_agg(item.line, E'\n' order by item.group_position, item.name, item.tmdb_id)
  into alert_text
  from (
    select 1 as group_position, movie.title || coalesce(' (' || movie.year || ')', '') as name,
      movie.tmdb_id,
      '- ' || movie.title || coalesce(' (' || movie.year || ')', '') || ': ' || string_agg(
        private.loss_text(loss.field, loss.credit_type, person.name),
        ', ' order by private.loss_position(loss.field), loss.credit_type, person.name
      ) as line
    from public.reimport_losses as loss
    join public.movies as movie on movie.id = loss.movie_id
    left join public.people as person on person.id = loss.person_id
    where loss.reimport_id = chosen.id and loss.new_loss
    group by movie.id
    union all
    select 2, person.name, person.tmdb_id, '- ' || person.name || ': ' || string_agg(
      private.loss_text(loss.field, null, null),
      ', ' order by private.loss_position(loss.field)
    )
    from public.reimport_losses as loss
    join public.people as person on person.id = loss.person_id
    where loss.reimport_id = chosen.id and loss.new_loss and loss.movie_id is null
    group by person.id
  ) as item;

  select jsonb_build_object(
    'reimport_id', chosen.id,
    'movies', (
      select count(*) from public.reimport_movies
      where reimport_movies.reimport_id = chosen.id and covered
    ),
    'people', (
      select count(*) from public.reimport_people
      where reimport_people.reimport_id = chosen.id and covered
    ),
    'losses', (
      select count(*) from public.reimport_losses
      where reimport_losses.reimport_id = chosen.id
    ),
    'alerts', case when alert_text is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object(
      'type', 'tmdb-loss',
      'subject', 'tmdb-loss',
      'effect', 'open',
      'text', format(
        'Reimportação %s: o TMDB não tem mais o que segue, e o acervo manteve o que tinha.',
        case chosen.type when 'weekly' then 'semanal' else 'manual' end
      ) || E'\n' || alert_text
    )) end
  )
  into result;

  return result;
end;
$$;

revoke all on function public.reimport_plan(public.reimport_type, integer[], integer[], timestamptz)
  from anon, authenticated, public;
grant execute on function public.reimport_plan(public.reimport_type, integer[], integer[], timestamptz)
  to service_role;
revoke all on function public.reimport(uuid, jsonb, jsonb, timestamptz)
  from anon, authenticated, public;
grant execute on function public.reimport(uuid, jsonb, jsonb, timestamptz) to service_role;
grant execute on function private.chosen_credits(jsonb) to service_role;
grant execute on function private.tmdb_credited_people(jsonb) to service_role;
grant execute on function private.reimport_person(uuid, integer, jsonb, boolean, timestamptz)
  to service_role;
grant execute on function private.reimport_movie(uuid, integer, jsonb, timestamptz) to service_role;
grant execute on function private.loss_text(text, public.credit_type, text) to service_role;
grant execute on function private.loss_position(text) to service_role;
