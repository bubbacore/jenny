-- Previous slugs let the site keep old URLs and saved selections working.
create function private.cinema_slugs_are_valid(slug text, previous_slugs text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select not exists (
    select 1 from unnest(array[slug] || previous_slugs) as value
    where value is null or value !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
  ) and cardinality(array[slug] || previous_slugs) = (
    select count(distinct value) from unnest(array[slug] || previous_slugs) as value
  );
$$;

revoke all on function private.cinema_slugs_are_valid(text, text[]) from public, anon, authenticated;
grant execute on function private.cinema_slugs_are_valid(text, text[]) to service_role;

alter table public.cinemas
  add column previous_slugs text[] not null default '{}',
  add constraint cinemas_slugs_are_valid
    check (private.cinema_slugs_are_valid(slug, previous_slugs));

comment on column public.cinemas.previous_slugs is
  'Previous slugs kept for redirects, shared links and saved selections.';

create or replace view public.site_cinemas
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
  private.weekday_names(cinema.closed_weekdays) as closed_weekdays,
  cinema.latitude,
  cinema.longitude,
  cinema.google_reviews_url,
  cinema.google_rating,
  cinema.google_reviews_count,
  cinema.previous_slugs
from public.cinemas as cinema
join public.cities as city on city.id = cinema.city_id
left join public.chains as chain on chain.id = cinema.chain_id
where cinema.active;

revoke all on public.site_cinemas from anon, authenticated;
