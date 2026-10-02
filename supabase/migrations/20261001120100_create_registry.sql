-- Cities, chains, cinemas and sources. New cities and cinemas enter as data
-- migrations, without code changes.

create table public.cities (
  id bigint generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null check (btrim(name) <> ''),
  state char(2) not null check (state ~ '^[A-Z]{2}$'),
  timezone text not null check (now() at time zone timezone is not null)
);

create table public.chains (
  id bigint generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null check (btrim(name) <> ''),
  website_url text check (website_url ~ '^https://')
);

-- closed_weekdays holds ISO weekdays, 1 for Monday to 7 for Sunday.
create table public.cinemas (
  id bigint generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null check (btrim(name) <> ''),
  city_id bigint not null references public.cities,
  chain_id bigint references public.chains,
  address text check (btrim(address) <> ''),
  website_url text check (website_url ~ '^https://'),
  instagram_handle text check (instagram_handle ~ '^[a-z0-9._]{1,30}$'),
  closed_weekdays smallint[] not null default '{}'
    check (closed_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]),
  active boolean not null default true
);

create index cinemas_city_id_idx on public.cinemas (city_id);
create index cinemas_chain_id_idx on public.cinemas (chain_id);

create type public.source_type as enum (
  'ingresso_com',
  'veloxtickets',
  'cinesercla_site',
  'official_site'
);

create function private.is_positive_integer(value jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(value) = 'number' and value::text ~ '^[1-9][0-9]*$';
$$;

create function private.is_https_url(value jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(value) = 'string' and value #>> '{}' ~ '^https://[^[:space:]]+$';
$$;

-- Each source type keeps the stable identifiers its collection tool uses,
-- and nothing else.
create function private.source_config_is_valid(type public.source_type, config jsonb)
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
  end, false);
end;
$$;

create table public.sources (
  id bigint generated always as identity primary key,
  cinema_id bigint not null references public.cinemas,
  type public.source_type not null,
  config jsonb not null,
  active boolean not null default true,
  constraint sources_config_matches_type check (private.source_config_is_valid(type, config))
);

-- At most one active source per cinema. The trigger below makes it exactly
-- one for every active cinema.
create unique index sources_one_active_per_cinema on public.sources (cinema_id) where active;

create function private.assert_cinema_has_one_active_source(checked_cinema_id bigint)
returns void
language plpgsql
set search_path = ''
as $$
declare
  cinema_slug text;
  active_sources integer;
begin
  select slug into cinema_slug from public.cinemas where id = checked_cinema_id and active;
  if cinema_slug is null then
    return;
  end if;

  select count(*) into active_sources
  from public.sources
  where cinema_id = checked_cinema_id and active;

  if active_sources <> 1 then
    raise exception 'o cinema % está ativo e tem % fontes ativas, mas precisa de exatamente uma',
      cinema_slug, active_sources;
  end if;
end;
$$;

create function private.check_cinema_sources()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform private.assert_cinema_has_one_active_source(new.id);
  return null;
end;
$$;

create function private.check_source_cinemas()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform private.assert_cinema_has_one_active_source(old.cinema_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform private.assert_cinema_has_one_active_source(new.cinema_id);
  end if;
  return null;
end;
$$;

create constraint trigger cinemas_need_one_active_source
  after insert or update of active on public.cinemas
  deferrable initially deferred
  for each row execute function private.check_cinema_sources();

create constraint trigger sources_keep_one_active_source
  after insert or update or delete on public.sources
  deferrable initially deferred
  for each row execute function private.check_source_cinemas();

alter table public.cities enable row level security;
alter table public.chains enable row level security;
alter table public.cinemas enable row level security;
alter table public.sources enable row level security;

revoke all on public.cities, public.chains, public.cinemas, public.sources from anon, authenticated;
grant execute on all functions in schema private to service_role;
