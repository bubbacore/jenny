-- The collection plan: for each active cinema, the window in its city's time
-- zone, the closed weekdays and the active source with its config.
-- With cinema_slugs, only those cinemas; unknown or inactive slugs are left
-- out, and the ingestion reports them.

create function public.collection_plan(cinema_slugs text[] default null, reference_time timestamptz default now())
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'cinemas',
    coalesce(jsonb_agg(
      jsonb_build_object(
        'slug', cinema.slug,
        'name', cinema.name,
        'city', city.slug,
        'timezone', city.timezone,
        'window', (
          select jsonb_agg(to_char((reference_time at time zone city.timezone)::date + day, 'YYYY-MM-DD') order by day)
          from generate_series(0, 6) as day
        ),
        'closed_weekdays', (
          select coalesce(jsonb_agg(
            (array['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'])[weekday]
            order by weekday
          ), '[]')
          from unnest(cinema.closed_weekdays) as weekday
        ),
        'source', jsonb_build_object('type', source.type, 'config', source.config)
      )
      order by cinema.slug
    ), '[]')
  )
  from public.cinemas as cinema
  join public.cities as city on city.id = cinema.city_id
  join public.sources as source on source.cinema_id = cinema.id and source.active
  where cinema.active
    and (cinema_slugs is null or cinema.slug = any (cinema_slugs));
$$;

revoke all on function public.collection_plan(text[], timestamptz) from anon, authenticated, public;
grant execute on function public.collection_plan(text[], timestamptz) to service_role;
