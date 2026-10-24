begin;

select plan(11);

-- Título na fonte normalizado

select is(
  private.normalized_source_title('  BTS World Tour ´Arirang` in  São Paulo: Live Viewing '),
  private.normalized_source_title('BTS World Tour ''Arirang'' In São Paulo: Live Viewing'),
  'a normalização lê ´ e ` como apóstrofo'
);

select is(
  private.normalized_source_title('Ocean’s Eleven'),
  'ocean''s eleven',
  'a normalização continua lendo ’ como apóstrofo'
);

select isnt(
  private.normalized_source_title('BTS World Tour "Arirang" in São Paulo: Live Viewing'),
  private.normalized_source_title('BTS World Tour ''Arirang'' in São Paulo: Live Viewing'),
  'as aspas duplas continuam sendo outra grafia'
);

-- Recálculo dos títulos guardados

-- The records as the earlier normalization left them: the same show as two
-- movies without TMDB, one per spelling, and records of the same cinema that
-- now coincide.
create temporary table recorded as
with collection as (
  insert into public.collections (type, started_at, finished_at, site_publication)
  values ('daily', '2026-10-24 06:00-03', '2026-10-24 06:30-03', true)
  returning id
),
reading as (
  insert into public.readings (
    collection_id, cinema_id, source_id, status, collection_release, started_at, finished_at,
    sessions_received, sessions_discarded, sessions_accepted, sessions_retained, alerts
  )
  select collection.id, cinema.id, source.id, 'success', 'v0.1.0', '2026-10-24 06:01-03',
    '2026-10-24 06:02-03', 2, 0, 2, 0, '[]'
  from collection
  cross join public.cinemas as cinema
  join public.sources as source on source.cinema_id = cinema.id
  where cinema.slug in ('cinemark-shopping-jardins', 'cinesercla-premio')
  returning id, cinema_id, source_id
),
cinemark as (
  insert into public.movies (normalized_source_title, slug, title, original_title, runtime_minutes)
  values ('bts world tour ''arirang'' in sao paulo: live viewing', 'bts-cinemark',
    'BTS World Tour ''Arirang'' In São Paulo: Live Viewing',
    'BTS World Tour ''Arirang'' In São Paulo: Live Viewing', 120)
  returning id
),
cinesercla as (
  insert into public.movies (normalized_source_title, slug, title, original_title, year, runtime_minutes)
  values ('bts world tour ´arirang` in sao paulo: live viewing', 'bts-cinesercla',
    'BTS World Tour ´Arirang` in São Paulo: Live Viewing',
    'BTS World Tour ´Arirang` in São Paulo: Live Viewing', 2026, 90)
  returning id
),
alone as (
  insert into public.movies (normalized_source_title, slug, title, original_title)
  values ('show ´unico`', 'show-unico', 'Show ´Único`', 'Show ´Único`')
  returning id
)
select reading.id as reading_id, reading.cinema_id, reading.source_id, cinema.slug as cinema,
  cinemark.id as cinemark_movie_id, cinesercla.id as cinesercla_movie_id, alone.id as alone_movie_id
from reading
join public.cinemas as cinema on cinema.id = reading.cinema_id
cross join cinemark
cross join cinesercla
cross join alone;

insert into public.sessions (cinema_id, movie_id, reading_id, starts_at, room, audio, format)
select recorded.cinema_id, movie.id, recorded.reading_id, movie.starts_at, 'Sala 1', 'dubbed', '2d'
from recorded
cross join lateral (
  values
    (recorded.cinemark_movie_id, '2026-10-25 20:00'::timestamp, 'cinemark-shopping-jardins'),
    (recorded.cinesercla_movie_id, '2026-10-25 20:00', 'cinemark-shopping-jardins'),
    (recorded.cinesercla_movie_id, '2026-10-25 19:00', 'cinesercla-premio'),
    (recorded.cinesercla_movie_id, '2026-10-25 21:00', 'cinesercla-premio')
) as movie (id, starts_at, cinema)
where movie.cinema = recorded.cinema;

insert into public.movie_without_tmdb_appearances (movie_id, cinema_id, first_seen_at)
select movie.id, recorded.cinema_id, movie.first_seen_at
from recorded
cross join lateral (
  values
    (recorded.cinemark_movie_id, '2026-10-24 06:01-03'::timestamptz, 'cinemark-shopping-jardins'),
    (recorded.cinesercla_movie_id, '2026-10-23 06:01-03', 'cinemark-shopping-jardins'),
    (recorded.cinesercla_movie_id, '2026-10-24 06:02-03', 'cinesercla-premio')
) as movie (id, first_seen_at, cinema)
where movie.cinema = recorded.cinema;

insert into public.source_values (movie_id, source_id, data, value, reading_id, informed_at)
select recorded.cinesercla_movie_id, recorded.source_id, 'content_rating', '12',
  recorded.reading_id, '2026-10-24 06:02-03'
from recorded
where recorded.cinema = 'cinesercla-premio';

insert into public.resolved_source_titles (
  cinema_id, normalized_source_title, source_title, tmdb_id, resolved_at
)
select recorded.cinema_id, resolved.normalized, resolved.source_title, resolved.tmdb_id,
  resolved.resolved_at
from recorded
cross join (
  values
    ('o ''retorno''', 'O ''Retorno''', 9800101, '2026-10-20 10:00-03'::timestamptz),
    ('o ´retorno`', 'O ´Retorno`', 9800102, '2026-10-22 10:00-03')
) as resolved (normalized, source_title, tmdb_id, resolved_at)
where recorded.cinema = 'cinemark-shopping-jardins';

insert into public.pending_identifications (
  cinema_id, source_title, normalized_source_title, proposed_tmdb_id, reason, first_seen_at,
  last_seen_at
)
select recorded.cinema_id, pending.source_title, pending.normalized, 9800201, 'Ano diferente.',
  pending.first_seen_at, pending.last_seen_at
from recorded
cross join (
  values
    ('A ''Volta''', 'a ''volta''', '2026-10-20 06:00-03'::timestamptz, '2026-10-22 06:00-03'::timestamptz),
    ('A ´Volta`', 'a ´volta`', '2026-10-21 06:00-03', '2026-10-23 06:00-03')
) as pending (source_title, normalized, first_seen_at, last_seen_at)
where recorded.cinema = 'cinesercla-premio';

select private.recalculate_normalized_source_titles();

select results_eq(
  $$
    select movie.id, movie.slug, movie.year, movie.runtime_minutes, movie.content_rating
    from public.movies as movie
    where movie.normalized_source_title = 'bts world tour ''arirang'' in sao paulo: live viewing'
      or movie.slug in ('bts-cinemark', 'bts-cinesercla')
  $$,
  $$
    select distinct recorded.cinemark_movie_id, 'bts-cinemark', 2026::smallint, 120::smallint,
      '12'
    from recorded
  $$,
  'os dois filmes sem TMDB que coincidem viram o mais antigo, que completa só o que lhe falta e '
    || 'fica com os valores informados pela fonte do outro'
);

select results_eq(
  $$
    select cinema.slug, session.starts_at
    from public.sessions as session
    join public.cinemas as cinema on cinema.id = session.cinema_id
    where session.movie_id in (
      select recorded.cinemark_movie_id from recorded
      union
      select recorded.cinesercla_movie_id from recorded
    )
    order by cinema.slug, session.starts_at
  $$,
  $$
    values
      ('cinemark-shopping-jardins', '2026-10-25 20:00'::timestamp),
      ('cinesercla-premio', '2026-10-25 19:00'),
      ('cinesercla-premio', '2026-10-25 21:00')
  $$,
  'as sessões dos dois cinemas passam para o filme que fica, e a sessão repetida no mesmo cinema '
    || 'conta uma vez'
);

select is(
  (
    select count(*)
    from public.sessions as session
    where session.movie_id = (select distinct recorded.cinemark_movie_id from recorded)
  ),
  3::bigint,
  'o filme que fica tem as três sessões'
);

select results_eq(
  $$
    select cinema.slug, appearance.first_seen_at
    from public.movie_without_tmdb_appearances as appearance
    join public.cinemas as cinema on cinema.id = appearance.cinema_id
    where appearance.movie_id in (
      select recorded.cinemark_movie_id from recorded
      union
      select recorded.cinesercla_movie_id from recorded
    )
    order by cinema.slug
  $$,
  $$
    values
      ('cinemark-shopping-jardins', '2026-10-23 06:01-03'::timestamptz),
      ('cinesercla-premio', '2026-10-24 06:02-03')
  $$,
  'a primeira aparição em cada cinema é a mais antiga dos dois filmes'
);

select results_eq(
  $$
    select resolved.normalized_source_title, resolved.tmdb_id
    from public.resolved_source_titles as resolved
    where resolved.normalized_source_title like 'o %retorno%'
  $$,
  $$ values ('o ''retorno''', 9800102) $$,
  'dos títulos na fonte resolvidos que coincidem no mesmo cinema, fica o mais recente'
);

select results_eq(
  $$
    select pending.source_title, pending.normalized_source_title, pending.first_seen_at,
      pending.last_seen_at
    from public.pending_identifications as pending
    where pending.normalized_source_title like 'a %volta%'
  $$,
  $$
    values (
      'A ´Volta`', 'a ''volta''', '2026-10-20 06:00-03'::timestamptz,
      '2026-10-23 06:00-03'::timestamptz
    )
  $$,
  'das identificações pendentes que coincidem no mesmo cinema, fica a vista por último, desde a '
    || 'primeira aparição'
);

select is(
  (
    select count(*)
    from (
      select movie.normalized_source_title from public.movies as movie
      union all
      select resolved.normalized_source_title from public.resolved_source_titles as resolved
      union all
      select pending.normalized_source_title from public.pending_identifications as pending
    ) as stored
    where stored.normalized_source_title ~ '[´`’]'
  ),
  0::bigint,
  'nenhum título na fonte normalizado guardado tem ´, ` ou ’'
);

select is(
  (select movie.slug from public.movies as movie where movie.normalized_source_title = 'show ''unico'''),
  'show-unico',
  'um filme sem TMDB sem outro igual só tem o título normalizado recalculado'
);

select * from finish();

rollback;
