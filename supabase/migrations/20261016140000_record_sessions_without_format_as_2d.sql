-- The 2D session is the common session: a session whose source does not
-- inform the format is 2D. The ingestion records it as 2D, also in a reading
-- without a new post that reuses an older post, and the sessions recorded
-- without a format become 2D, so the site filters them as 2D.

-- A session without a format and a 2D one with the same movie, start, room and
-- audio are the same session, which the contract now refuses as a repeated
-- session. Only the 2D one stays, with its prices.
delete from public.sessions as blank
where blank.format is null
  and exists (
    select 1
    from public.sessions as twin
    where twin.format = '2d'
      and twin.cinema_id = blank.cinema_id
      and twin.movie_id = blank.movie_id
      and twin.starts_at = blank.starts_at
      and twin.room is not distinct from blank.room
      and twin.audio is not distinct from blank.audio
  );

update public.sessions set format = '2d' where format is null;

-- Every session has a format, 2D when the source does not inform one.
alter table public.sessions alter column format set not null;

-- Each session of a reading with what the ingestion does with it. Sessions
-- outside the window and on a closed day are discarded; a session whose
-- proposed TMDB id differs from the top search result is retained. A session
-- without a format comes out as 2D, the common session.
create or replace function private.reading_sessions(reading jsonb, today date, closed_weekdays smallint[])
returns table (session jsonb, tmdb_id integer, starts_at timestamp, outcome text)
language sql
immutable
set search_path = ''
as $$
  select listed_session.value
      || jsonb_build_object('format', coalesce(listed_session.value ->> 'format', '2d')),
    (listed_movie.value ->> 'tmdb_id')::integer,
    start.at,
    case
      when start.at::date not between today and today + 6 then 'outside_window'
      when extract(isodow from start.at)::smallint = any (closed_weekdays) then 'closed_day'
      when listed_movie.value -> 'tmdb_id' is distinct from listed_movie.value -> 'tmdb_search_top_id'
        then 'retained'
      else 'accepted'
    end
  from jsonb_array_elements(reading -> 'sessions') as listed_session (value)
  join jsonb_array_elements(reading -> 'movies') as listed_movie (value)
    on listed_movie.value ->> 'key' = listed_session.value ->> 'movie_key'
  cross join lateral (select (listed_session.value ->> 'starts_at')::timestamp as at) as start;
$$;
