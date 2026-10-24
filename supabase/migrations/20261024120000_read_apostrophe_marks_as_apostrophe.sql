-- The normalized source title also reads as an apostrophe the marks the
-- sources use in its place, as ADR 0017 of bubbacore/dan says since
-- 2026-10-24. Cinesercla wrote a show as "BTS World Tour ´Arirang` in São
-- Paulo: Live Viewing" and Cinemark as "BTS World Tour 'Arirang' In São Paulo:
-- Live Viewing", and the catalog got two movies without TMDB for the same show.

-- The source title as the ingestion compares it: without accents, in lower
-- case, with the spaces reduced to one and with ´, ` and ’ read as an
-- apostrophe. The same normalized source title is the same movie without TMDB,
-- the same pending identification and the same resolved source title. Other
-- different spellings stay different.
create or replace function private.normalized_source_title(title text)
returns text
language sql
stable
set search_path = ''
as $$
  select lower(extensions.unaccent(
    'extensions.unaccent'::regdictionary,
    regexp_replace(btrim(translate(title, '´`’', '''''''')), '\s+', ' ', 'g')
  ));
$$;

-- Each movie without TMDB whose normalized source title, recalculated,
-- coincides with the one of an older movie, with the oldest of them.
create function private.movies_without_tmdb_to_merge()
returns table (merged_id bigint, kept_id bigint)
language sql
stable
set search_path = ''
as $$
  select grouped.id, grouped.kept_id
  from (
    select movie.id,
      min(movie.id) over (
        partition by private.normalized_source_title(movie.normalized_source_title)
      ) as kept_id
    from public.movies as movie
    where movie.normalized_source_title is not null
  ) as grouped
  where grouped.id <> grouped.kept_id;
$$;

-- Recalculates the normalized source titles already recorded, after a change
-- in the normalization. Movies without TMDB whose titles now coincide become
-- the oldest of them, which takes their sessions, their appearances in each
-- cinema, the values their sources informed and the source data it lacks; the
-- others leave the catalog, and their addresses with them. Where two records
-- of the same cinema that exist only once now coincide, the most recent stays.
create function private.recalculate_normalized_source_titles()
returns void
language plpgsql
set search_path = ''
as $$
declare
  kept_ids bigint[] := array(
    select distinct merged.kept_id
    from private.movies_without_tmdb_to_merge() as merged
  );
begin
  -- The kept movie keeps its own data and takes from the merged ones, the
  -- oldest first, only what it lacks.
  update public.movies as kept
  set year = coalesce(kept.year, merged.year),
    runtime_minutes = coalesce(kept.runtime_minutes, merged.runtime_minutes),
    source_poster_url = coalesce(kept.source_poster_url, merged.source_poster_url)
  from (
    select merged_movie.kept_id,
      (array_agg(movie.year order by movie.id) filter (where movie.year is not null))[1] as year,
      (array_agg(movie.runtime_minutes order by movie.id)
        filter (where movie.runtime_minutes is not null))[1] as runtime_minutes,
      (array_agg(movie.source_poster_url order by movie.id)
        filter (where movie.source_poster_url is not null))[1] as source_poster_url
    from private.movies_without_tmdb_to_merge() as merged_movie
    join public.movies as movie on movie.id = merged_movie.merged_id
    group by merged_movie.kept_id
  ) as merged
  where kept.id = merged.kept_id;

  -- Each source keeps, for each value, the one it informed last.
  insert into public.source_values as existing (
    movie_id, source_id, data, value, trailer_version, reading_id, informed_at
  )
  select distinct on (merged_movie.kept_id, informed.source_id, informed.data)
    merged_movie.kept_id,
    informed.source_id,
    informed.data,
    informed.value,
    informed.trailer_version,
    informed.reading_id,
    informed.informed_at
  from public.source_values as informed
  join private.movies_without_tmdb_to_merge() as merged_movie on merged_movie.merged_id = informed.movie_id
  order by merged_movie.kept_id, informed.source_id, informed.data, informed.informed_at desc
  on conflict (movie_id, source_id, data) do update
  set value = excluded.value,
    trailer_version = excluded.trailer_version,
    reading_id = excluded.reading_id,
    informed_at = excluded.informed_at
  where excluded.informed_at > existing.informed_at;

  -- The first appearance in each cinema is the earliest of the merged movies,
  -- so that the alert does not repeat.
  insert into public.movie_without_tmdb_appearances as existing (movie_id, cinema_id, first_seen_at)
  select merged_movie.kept_id, appearance.cinema_id, min(appearance.first_seen_at)
  from public.movie_without_tmdb_appearances as appearance
  join private.movies_without_tmdb_to_merge() as merged_movie on merged_movie.merged_id = appearance.movie_id
  group by merged_movie.kept_id, appearance.cinema_id
  on conflict (movie_id, cinema_id) do update
  set first_seen_at = least(existing.first_seen_at, excluded.first_seen_at);

  delete from public.movie_without_tmdb_appearances as appearance
  using private.movies_without_tmdb_to_merge() as merged_movie
  where appearance.movie_id = merged_movie.merged_id;

  -- A session of a merged movie that repeats one already in the cinema, with
  -- the same start, room, audio and format, is the same session and goes.
  delete from public.sessions as session
  using (
    select listed.id,
      row_number() over (
        partition by grouped.kept_id, listed.cinema_id, listed.starts_at, listed.room,
          listed.audio, listed.format
        order by listed.movie_id, listed.id
      ) as position
    from public.sessions as listed
    join (
      select merged_movie.merged_id as movie_id, merged_movie.kept_id
      from private.movies_without_tmdb_to_merge() as merged_movie
      union
      select merged_movie.kept_id, merged_movie.kept_id
      from private.movies_without_tmdb_to_merge() as merged_movie
    ) as grouped on grouped.movie_id = listed.movie_id
  ) as ranked
  where session.id = ranked.id
    and ranked.position > 1;

  update public.sessions as session
  set movie_id = merged_movie.kept_id
  from private.movies_without_tmdb_to_merge() as merged_movie
  where session.movie_id = merged_movie.merged_id;

  delete from public.movies as movie
  using private.movies_without_tmdb_to_merge() as merged_movie
  where movie.id = merged_movie.merged_id;

  update public.movies
  set normalized_source_title = private.normalized_source_title(normalized_source_title)
  where normalized_source_title <> private.normalized_source_title(normalized_source_title);

  perform private.choose_movie_values(kept.id)
  from unnest(kept_ids) as kept (id);

  -- Of the source titles resolved in a cinema that now coincide, the most
  -- recent resolution stays.
  delete from public.resolved_source_titles as resolved
  using (
    select listed.cinema_id,
      listed.normalized_source_title,
      row_number() over (
        partition by listed.cinema_id,
          private.normalized_source_title(listed.normalized_source_title)
        order by listed.resolved_at desc, listed.normalized_source_title
      ) as position
    from public.resolved_source_titles as listed
  ) as ranked
  where resolved.cinema_id = ranked.cinema_id
    and resolved.normalized_source_title = ranked.normalized_source_title
    and ranked.position > 1;

  update public.resolved_source_titles
  set normalized_source_title = private.normalized_source_title(normalized_source_title)
  where normalized_source_title <> private.normalized_source_title(normalized_source_title);

  -- Of the pending identifications of a cinema that now coincide, the one
  -- seen last stays, first seen when the earliest of them was.
  with ranked as (
    select listed.id,
      row_number() over (
        partition by listed.cinema_id,
          private.normalized_source_title(listed.normalized_source_title)
        order by listed.last_seen_at desc, listed.id
      ) as position,
      min(listed.first_seen_at) over (
        partition by listed.cinema_id,
          private.normalized_source_title(listed.normalized_source_title)
      ) as first_seen_at
    from public.pending_identifications as listed
    where listed.status = 'pending'
  ),
  removed as (
    delete from public.pending_identifications as pending
    using ranked
    where pending.id = ranked.id
      and ranked.position > 1
  )
  update public.pending_identifications as pending
  set first_seen_at = ranked.first_seen_at
  from ranked
  where pending.id = ranked.id
    and ranked.position = 1
    and pending.first_seen_at > ranked.first_seen_at;

  update public.pending_identifications
  set normalized_source_title = private.normalized_source_title(normalized_source_title)
  where normalized_source_title <> private.normalized_source_title(normalized_source_title);
end;
$$;

revoke all on function private.movies_without_tmdb_to_merge()
  from anon, authenticated, public;
revoke all on function private.recalculate_normalized_source_titles()
  from anon, authenticated, public;

-- The titles recorded with the earlier normalization.
select private.recalculate_normalized_source_titles();
