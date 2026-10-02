-- The views the site build reads, with its own secret key. Like every table,
-- they have no public read, and they respect row level security.

create function private.weekday_names(weekdays smallint[])
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(
    (array['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'])[weekday]
    order by weekday
  ), '{}')
  from unnest(weekdays) as weekday;
$$;

grant execute on function private.weekday_names(smallint[]) to service_role;

-- name is the main popular name. The search also finds the cinema by the other
-- popular names and the official name.
create view public.site_cinemas
with (security_invoker = true)
as
select cinema.slug,
  cinema.name,
  cinema.other_popular_names,
  cinema.official_name,
  city.slug as city,
  city.name as city_name,
  city.state,
  city.timezone,
  chain.slug as chain,
  chain.name as chain_name,
  cinema.address,
  cinema.website_url,
  cinema.instagram_handle,
  private.weekday_names(cinema.closed_weekdays) as closed_weekdays
from public.cinemas as cinema
join public.cities as city on city.id = cinema.city_id
left join public.chains as chain on chain.id = cinema.chain_id
where cinema.active;

-- The accepted sessions of the active cinemas. starts_at is local time in the
-- cinema's city, and date is the calendar date the session starts on.
create view public.site_showtimes
with (security_invoker = true)
as
select cinema.slug as cinema,
  movie.slug as movie,
  session.starts_at,
  session.date,
  session.room,
  session.audio,
  session.format,
  session.tags,
  coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'ticket_type', price.ticket_type,
        'source_ticket', price.source_ticket,
        'price_cents', price.price_cents
      )
      order by price.ticket_type, price.price_cents, price.source_ticket
    )
    from public.box_office_prices as price
    where price.session_id = session.id
  ), '[]') as prices
from public.sessions as session
join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
join public.movies as movie on movie.id = session.movie_id;

-- The movies with sessions in the programação.
create view public.site_movies
with (security_invoker = true)
as
select movie.slug,
  movie.tmdb_id,
  movie.title,
  movie.original_title
from public.movies as movie
where exists (
  select 1
  from public.sessions as session
  join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
  where session.movie_id = movie.id
);

revoke all on public.site_cinemas, public.site_showtimes, public.site_movies from anon, authenticated;
