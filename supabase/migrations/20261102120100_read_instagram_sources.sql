-- Instagram enters as a source type of its own (ADR 0020). Its reading is a
-- reading of a post, with the same contract as the official site's.

-- Each source type keeps the stable identifiers its collection tool uses,
-- and nothing else. Instagram keeps the username, which builds the address
-- of the public profile page.
create or replace function private.source_config_is_valid(type public.source_type, config jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  required_keys text[];
begin
  if jsonb_typeof(config) is distinct from 'object' then
    return false;
  end if;

  required_keys := case type
    when 'ingresso_com' then array['city_id', 'theater_id']
    when 'veloxtickets' then array['url']
    when 'cinesercla_site' then array['ingresso_plus_group', 'unit_slug']
    when 'official_site' then array['post_title_prefix', 'url', 'wordpress_category_id']
    when 'instagram' then array['username']
  end;

  if (select coalesce(array_agg(key order by key), '{}') from jsonb_object_keys(config) as key)
    is distinct from required_keys then
    return false;
  end if;

  return coalesce(case type
    when 'ingresso_com' then
      private.is_positive_integer(config -> 'theater_id')
      and private.is_positive_integer(config -> 'city_id')
    when 'veloxtickets' then
      private.is_https_url(config -> 'url')
    when 'cinesercla_site' then
      jsonb_typeof(config -> 'unit_slug') = 'string'
      and config ->> 'unit_slug' ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
      and jsonb_typeof(config -> 'ingresso_plus_group') = 'string'
      and config ->> 'ingresso_plus_group' ~ '^[A-Z0-9]+$'
    when 'official_site' then
      private.is_https_url(config -> 'url')
      and private.is_positive_integer(config -> 'wordpress_category_id')
      and jsonb_typeof(config -> 'post_title_prefix') = 'string'
      and btrim(config ->> 'post_title_prefix') <> ''
    when 'instagram' then
      jsonb_typeof(config -> 'username') = 'string'
      and config ->> 'username' ~ '^[a-z0-9._]{1,30}$'
  end, false);
end;
$$;

-- The structured sources come first, and the official site and Instagram,
-- read from images, come last. Instagram is the newest source type, without
-- history, and comes after the official site. The initial ranking breaks
-- ties and holds the place of the source types without enough comparisons.
create or replace function private.initial_source_ranking()
returns public.source_type[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'ingresso_com', 'veloxtickets', 'cinesercla_site', 'official_site', 'instagram'
  ]::public.source_type[];
$$;

create or replace function private.source_type_name(type public.source_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case type
    when 'ingresso_com' then 'ingresso.com'
    when 'veloxtickets' then 'Veloxtickets'
    when 'cinesercla_site' then 'site da Cinesercla'
    when 'official_site' then 'site oficial'
    when 'instagram' then 'Instagram'
  end;
$$;

-- The ranking of the last calculation, or the initial ranking before the
-- first one. A source type added to the initial ranking after the last
-- calculation, like Instagram, comes after the calculated ones, in the order
-- of the initial ranking. So its source values count from the start, and the
-- next calculation does not take its arrival for a change in the ranking.
create or replace function private.source_ranking()
returns table (source_type public.source_type, place integer)
language sql
stable
set search_path = ''
as $$
  with last_calculation as (
    select id from public.source_reliability_calculations order by id desc limit 1
  ),
  calculated as (
    select reliability.source_type, reliability.position::integer as place
    from public.source_reliabilities as reliability
    where reliability.calculation_id = (select id from last_calculation)
  )
  select calculated.source_type, calculated.place
  from calculated
  union all
  select missing.source_type,
    ((select count(*) from calculated) + row_number() over (order by missing.position))::integer
  from unnest(private.initial_source_ranking()) with ordinality as missing (source_type, position)
  where not exists (
    select 1 from calculated where calculated.source_type = missing.source_type
  );
$$;
