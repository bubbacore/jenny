-- The owner can link a movie without TMDB to a TMDB movie, through the
-- Hermes, as ADR 0017 of bubbacore/dan decides. The link is a resolved source
-- title in each cinema where the movie has sessions, so the recollection of
-- those cinemas accepts the sessions for the TMDB movie, as it does after the
-- resolution of a pending identification.

-- A resolved source title born from the owner's link has no pending
-- identification behind it.
alter table public.resolved_source_titles
  alter column pending_identification_id drop not null;

comment on column public.resolved_source_titles.pending_identification_id is
  'The resolved pending identification, or null when the owner linked a movie without TMDB to a TMDB movie.';

comment on column public.readings.sessions_released is
  'Accepted sessions of a source title resolved after the cinema''s last reading, which retained them or accepted them for a movie without TMDB.';

-- Links the movie without TMDB of the source title to the TMDB movie the owner
-- chose, which may be outside the catalog. Records the resolved source title
-- in each cinema where the movie has sessions and returns the active ones, for
-- the recollection. Returns a refusal when no movie without TMDB has the
-- normalized source title.
create function public.link_movie_without_tmdb(
  source_title text,
  tmdb_id integer,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  linked record;
  cinemas jsonb;
begin
  select movie.id, movie.normalized_source_title
  into linked
  from public.movies as movie
  where movie.tmdb_id is null
    and movie.normalized_source_title
      = private.normalized_source_title(link_movie_without_tmdb.source_title)
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_movie_without_tmdb'));
  end if;

  insert into public.resolved_source_titles (
    cinema_id, normalized_source_title, source_title, tmdb_id, pending_identification_id, resolved_at
  )
  select distinct session.cinema_id,
    linked.normalized_source_title,
    btrim(link_movie_without_tmdb.source_title),
    link_movie_without_tmdb.tmdb_id,
    null::uuid,
    link_movie_without_tmdb.reference_time
  from public.sessions as session
  where session.movie_id = linked.id
  on conflict (cinema_id, normalized_source_title) do update
  set source_title = excluded.source_title,
    tmdb_id = excluded.tmdb_id,
    pending_identification_id = excluded.pending_identification_id,
    resolved_at = excluded.resolved_at;

  select coalesce(jsonb_agg(cinema.slug order by cinema.slug), '[]')
  into cinemas
  from public.cinemas as cinema
  where cinema.active
    and exists (
      select 1
      from public.sessions as session
      where session.cinema_id = cinema.id
        and session.movie_id = linked.id
    );

  return jsonb_build_object('recollection_cinemas', cinemas);
end;
$$;

revoke all on function public.link_movie_without_tmdb(text, integer, timestamptz)
  from anon, authenticated, public;
grant execute on function public.link_movie_without_tmdb(text, integer, timestamptz)
  to service_role;
