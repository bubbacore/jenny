-- A cinema whose reading was reserved and never recorded, or that the daily
-- collection never reserved, has no finished reading on the day and would go
-- the whole day unread. The recollection takes it too. Only a success or a
-- failure finishes a reading: a reservation in progress or abandoned does
-- not. A cinema still under a valid reservation may be listed, because the
-- start of the reading refuses the parallel reservation.
create or replace function public.recollection_cinemas(reference_time timestamptz default now())
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('cinemas', coalesce(jsonb_agg(cinema.slug order by cinema.slug), '[]'))
  from public.cinemas as cinema
  join public.cities as city on city.id = cinema.city_id
  left join lateral private.last_finished_reading(cinema.id, reference_time) as last_reading on true
  where cinema.active
    and (reference_time at time zone city.timezone)::time < time '22:00'
    and (
      last_reading.status is null
      or last_reading.status = 'failure'
      or (last_reading.finished_at at time zone city.timezone)::date
        <> (reference_time at time zone city.timezone)::date
    );
$$;
