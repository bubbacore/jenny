-- A cinema has one or more popular names and may have an official name.
-- name is the main popular name, the one the site shows; other_popular_names
-- holds the others, in order. The search finds the cinema by every name.

create function private.cinema_names_are_valid(name text, other_popular_names text[], official_name text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  with names as (
    select lower(btrim(value)) as value
    from unnest(array[name] || other_popular_names || array[official_name]) as value
    where value is not null
  )
  select not exists (select 1 from names where value = '')
    and (select count(*) from names) = (select count(distinct value) from names);
$$;

grant execute on function private.cinema_names_are_valid(text, text[], text) to service_role;

alter table public.cinemas
  add column other_popular_names text[] not null default '{}',
  add column official_name text,
  add constraint cinemas_names_are_distinct
    check (private.cinema_names_are_valid(name, other_popular_names, official_name));

comment on column public.cinemas.name is 'The main popular name, shown by the site.';
comment on column public.cinemas.other_popular_names is 'Other popular names, in order, used only by the search.';
comment on column public.cinemas.official_name is 'The official name, when it differs from the popular names.';

update public.cinemas
set official_name = 'Cine Walmir Almeida'
where slug = 'cinema-do-centro';
