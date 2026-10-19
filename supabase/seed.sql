-- Fixed test data for the local database only. The v1 registry comes from the
-- migrations; nothing here reaches production.

-- An inactive cinema, which the collection plan must leave out.
insert into public.cinemas (slug, name, city_id, active)
select 'cinema-desativado-de-teste', 'Cinema Desativado de Teste', id, false
from public.cities
where slug = 'aracaju';

insert into public.sources (cinema_id, type, config, active)
select id, 'ingresso_com', '{"theater_id": 999999, "city_id": 4}', false
from public.cinemas
where slug = 'cinema-desativado-de-teste';

-- A movie with an IMDb id whose only sessions are in the inactive cinema,
-- which the ratings plan must leave out.
with collection as (
  insert into public.collections (type, started_at, finished_at, site_publication)
  values ('manual', '2026-10-01 09:00-03', '2026-10-01 09:10-03', false)
  returning id
),
reading as (
  insert into public.readings (
    collection_id, cinema_id, source_id, status, collection_release, started_at, finished_at,
    sessions_received, sessions_discarded, sessions_accepted, sessions_retained, alerts
  )
  select collection.id, cinema.id, source.id, 'success', 'v0.1.0', '2026-10-01 09:01-03',
    '2026-10-01 09:02-03', 1, 0, 1, 0, '[]'
  from collection
  cross join public.cinemas as cinema
  join public.sources as source on source.cinema_id = cinema.id
  where cinema.slug = 'cinema-desativado-de-teste'
  returning id, cinema_id
),
movie as (
  insert into public.movies (tmdb_id, slug, title, original_title, imdb_id, year)
  values (9990001, 'filme-do-cinema-desativado', 'Filme do Cinema Desativado',
    'Inactive Cinema Movie', 'tt9990001', 2026)
  returning id
)
insert into public.sessions (cinema_id, movie_id, reading_id, starts_at, room, audio, format)
select reading.cinema_id, movie.id, reading.id, '2026-10-05 20:00', 'Sala 1', 'dubbed', '2d'
from reading
cross join movie;
