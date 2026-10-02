-- Collections, the decision to end one with a site publication, the
-- suspension of the automatic publication and the collection summaries.

create type public.collection_type as enum ('daily', 'recollection', 'manual');

-- A collection is born with its plan. site_publication_requested is false
-- only for a manual collection the owner asked not to publish;
-- site_publication is the decision taken at its end.
create table public.collections (
  id uuid primary key default gen_random_uuid(),
  type public.collection_type not null,
  site_publication_requested boolean not null default true,
  started_at timestamptz not null,
  finished_at timestamptz,
  site_publication boolean,
  constraint collections_only_manual_skips_publication
    check (type = 'manual' or site_publication_requested),
  constraint collections_finished_with_decision
    check ((finished_at is null) = (site_publication is null))
);

create index collections_type_finished_at_idx on public.collections (type, finished_at)
  where finished_at is not null;

create table public.collection_cinemas (
  collection_id uuid not null references public.collections on delete cascade,
  cinema_id bigint not null references public.cinemas,
  primary key (collection_id, cinema_id)
);

create index collection_cinemas_cinema_id_idx on public.collection_cinemas (cinema_id);

-- Every reading belongs to a collection. Production had no reading when this
-- column arrived.
alter table public.readings
  add column collection_id uuid not null references public.collections;

create index readings_collection_id_idx on public.readings (collection_id);

-- The reversions of the site publication and the site publications asked by
-- the owner, as the Hermes records them.
create table public.site_reversions (
  id bigint generated always as identity primary key,
  recorded_at timestamptz not null
);

create table public.owner_site_publications (
  id bigint generated always as identity primary key,
  recorded_at timestamptz not null
);

-- A reversion suspends the automatic publication. The suspension ends with a
-- site publication asked by the owner, alone or at the end of a manual
-- collection. At most one is open, and the history is kept.
create table public.automatic_publication_suspensions (
  id bigint generated always as identity primary key,
  reversion_id bigint not null unique references public.site_reversions,
  started_at timestamptz not null,
  ended_at timestamptz,
  ended_by_owner_site_publication_id bigint unique references public.owner_site_publications,
  ended_by_collection_id uuid unique references public.collections,
  constraint suspensions_end_has_one_request check (
    (ended_at is null) = (num_nonnulls(ended_by_owner_site_publication_id, ended_by_collection_id) = 0)
    and num_nonnulls(ended_by_owner_site_publication_id, ended_by_collection_id) <= 1
  )
);

create unique index automatic_publication_suspensions_one_open
  on public.automatic_publication_suspensions ((true)) where ended_at is null;

alter table public.collections enable row level security;
alter table public.collection_cinemas enable row level security;
alter table public.site_reversions enable row level security;
alter table public.owner_site_publications enable row level security;
alter table public.automatic_publication_suspensions enable row level security;
revoke all on public.collections, public.collection_cinemas, public.site_reversions,
  public.owner_site_publications, public.automatic_publication_suspensions
  from anon, authenticated;

create function private.failure_type_name(type public.reading_failure_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case type
    when 'error' then 'erro'
    when 'incomplete' then 'leitura incompleta'
    when 'outdated' then 'leitura desatualizada'
  end;
$$;

-- Starts a collection of the active cinemas, or of the chosen ones among them.
-- The ingestion has already checked the chosen cinemas against the plan.
create function public.start_collection(
  collection_type public.collection_type,
  cinema_slugs text[] default null,
  site_publication_requested boolean default true,
  reference_time timestamptz default now()
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  new_collection_id uuid;
begin
  insert into public.collections (type, site_publication_requested, started_at)
  values (collection_type, site_publication_requested, reference_time)
  returning id into new_collection_id;

  insert into public.collection_cinemas (collection_id, cinema_id)
  select new_collection_id, cinema.id
  from public.cinemas as cinema
  where cinema.active
    and (cinema_slugs is null or cinema.slug = any (cinema_slugs));

  return new_collection_id;
end;
$$;

-- A reading now starts inside a collection that covers the cinema.
drop function public.start_reading(text, timestamptz);

create function public.start_reading(
  collection_id uuid,
  cinema_slug text,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  collection record;
  chosen record;
  reading record;
begin
  select id, finished_at into collection
  from public.collections
  where id = start_reading.collection_id;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_collection'));
  end if;
  if collection.finished_at is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'collection_finished'));
  end if;

  select cinema.id as cinema_id, source.id as source_id
  into chosen
  from public.cinemas as cinema
  join public.sources as source on source.cinema_id = cinema.id and source.active
  where cinema.slug = cinema_slug and cinema.active;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_cinema'));
  end if;
  if not exists (
    select 1
    from public.collection_cinemas as covered
    where covered.collection_id = collection.id and covered.cinema_id = chosen.cinema_id
  ) then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'cinema_not_in_collection'));
  end if;

  update public.readings
  set status = 'abandoned'
  where cinema_id = chosen.cinema_id
    and status = 'in_progress'
    and private.reservation_expires_at(started_at) <= reference_time;

  begin
    insert into public.readings (collection_id, cinema_id, source_id, started_at)
    values (collection.id, chosen.cinema_id, chosen.source_id, reference_time)
    returning id, started_at into reading;
  exception when unique_violation then
    return jsonb_build_object('refusal', jsonb_build_object(
      'code', 'reading_in_progress',
      'expires_at', (
        select private.reservation_expires_at(started_at)
        from public.readings
        where cinema_id = chosen.cinema_id and status = 'in_progress'
      )
    ));
  end;

  return jsonb_build_object(
    'reading_id', reading.id,
    'cinema', cinema_slug,
    'expires_at', private.reservation_expires_at(reading.started_at)
  );
end;
$$;

-- Ends the collection and decides whether it ends with a site publication.
-- The daily collection publishes; a recollection publishes only when some of
-- its readings changed result; both stay quiet while the automatic
-- publication is suspended. A manual collection publishes unless the owner
-- asked otherwise, and when it publishes it ends the suspension.
create function public.finish_collection(collection_id uuid, reference_time timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  collection record;
  suspended boolean;
  publishes boolean;
begin
  select id, type, site_publication_requested, finished_at into collection
  from public.collections
  where id = finish_collection.collection_id
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_collection'));
  end if;
  if collection.finished_at is not null then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'collection_finished'));
  end if;

  suspended := exists (
    select 1 from public.automatic_publication_suspensions where ended_at is null
  );

  publishes := case collection.type
    when 'daily' then not suspended
    when 'recollection' then not suspended and exists (
      select 1
      from public.readings as reading
      where reading.collection_id = collection.id
        and reading.status in ('success', 'failure')
        and reading.status is distinct from (
          select earlier.status
          from public.readings as earlier
          where earlier.cinema_id = reading.cinema_id
            and earlier.id <> reading.id
            and earlier.status in ('success', 'failure')
            and earlier.finished_at <= reading.started_at
          order by earlier.finished_at desc
          limit 1
        )
    )
    when 'manual' then collection.site_publication_requested
  end;

  if collection.type = 'manual' and publishes and suspended then
    update public.automatic_publication_suspensions
    set ended_at = reference_time, ended_by_collection_id = collection.id
    where ended_at is null;
    suspended := false;
  end if;

  update public.collections
  set finished_at = reference_time, site_publication = publishes
  where id = collection.id;

  return jsonb_build_object(
    'collection_id', collection.id,
    'site_publication', publishes,
    'automatic_publication_suspended', suspended
  );
end;
$$;

-- Records a reversion of the site publication asked by the owner, which
-- suspends the automatic publication. A reversion during a suspension keeps
-- the one already open.
create function public.record_site_reversion(reference_time timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  reversion_id bigint;
begin
  insert into public.site_reversions (recorded_at)
  values (reference_time)
  returning id into reversion_id;

  insert into public.automatic_publication_suspensions (reversion_id, started_at)
  select reversion_id, reference_time
  where not exists (
    select 1 from public.automatic_publication_suspensions where ended_at is null
  );

  return jsonb_build_object(
    'automatic_publication_suspended', true,
    'suspended_since', (
      select started_at from public.automatic_publication_suspensions where ended_at is null
    )
  );
end;
$$;

-- Records a site publication asked by the owner, which ends the suspension
-- of the automatic publication, when there is one.
create function public.record_site_publication(reference_time timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  publication_id bigint;
  ended boolean;
begin
  insert into public.owner_site_publications (recorded_at)
  values (reference_time)
  returning id into publication_id;

  update public.automatic_publication_suspensions
  set ended_at = reference_time, ended_by_owner_site_publication_id = publication_id
  where ended_at is null;
  ended := found;

  return jsonb_build_object('automatic_publication_suspended', false, 'suspension_ended', ended);
end;
$$;

-- The collection summary at the end of the daily collection ('daily') or at
-- 22h ('evening'). Both list the active cinemas without a successful reading
-- today, in each city's time zone, and say when the automatic publication is
-- suspended. The evening summary is sent only when some cinema spent the day
-- without success.
create function public.collection_summary(summary text, reference_time timestamptz default now())
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  cinemas_read integer;
  without_success jsonb;
  missing integer;
  suspended boolean;
  lines text[];
  message text;
begin
  with today_by_cinema as (
    select cinema.id, cinema.slug, cinema.name,
      (reference_time at time zone city.timezone)::date as today,
      city.timezone
    from public.cinemas as cinema
    join public.cities as city on city.id = cinema.city_id
    where cinema.active
  ),
  cinema_day as (
    select cinema.slug, cinema.name,
      exists (
        select 1
        from public.readings as reading
        where reading.cinema_id = cinema.id
          and reading.status = 'success'
          and reading.finished_at <= reference_time
          and (reading.finished_at at time zone cinema.timezone)::date = cinema.today
      ) as succeeded,
      last_failure.failure_type,
      last_failure.reason
    from today_by_cinema as cinema
    left join lateral (
      select reading.failure_type, reading.reason
      from public.readings as reading
      where reading.cinema_id = cinema.id
        and reading.status = 'failure'
        and reading.finished_at <= reference_time
        and (reading.finished_at at time zone cinema.timezone)::date = cinema.today
      order by reading.finished_at desc
      limit 1
    ) as last_failure on true
  )
  select count(*),
    coalesce(jsonb_agg(
      jsonb_build_object(
        'cinema', slug,
        'name', name,
        'failure_type', failure_type,
        'reason', reason
      )
      order by slug
    ) filter (where not succeeded), '[]')
  into cinemas_read, without_success
  from cinema_day;

  missing := jsonb_array_length(without_success);
  suspended := exists (
    select 1 from public.automatic_publication_suspensions where ended_at is null
  );

  lines := array[
    case summary
      when 'daily' then format(
        'Resumo da coleta diária: %s de %s com sucesso.',
        cinemas_read - missing,
        private.counted(cinemas_read, 'cinema', 'cinemas')
      )
      else format(
        'Resumo de coleta das 22h: %s o dia sem sucesso.',
        case when missing = 1 then '1 cinema passou' else missing || ' cinemas passaram' end
      )
    end
  ];

  if missing > 0 then
    if summary = 'daily' then
      lines := lines || 'Sem sucesso:'::text;
    end if;
    lines := lines || array(
      select case
        when cinema ->> 'failure_type' is null then format('- %s: sem leitura hoje.', cinema ->> 'name')
        else format(
          '- %s: %s. Motivo: %s.',
          cinema ->> 'name',
          private.failure_type_name((cinema ->> 'failure_type')::public.reading_failure_type),
          rtrim(btrim(cinema ->> 'reason'), '.')
        )
      end
      from jsonb_array_elements(without_success) as cinema
    );
  end if;

  if suspended then
    lines := lines || ('A publicação automática está suspensa desde uma reversão da publicação do site. '
      || 'A coleta continua gravando no banco, mas o site só volta a ser publicado quando o dono pedir '
      || 'uma publicação do site.')::text;
  end if;

  message := array_to_string(lines, e'\n');

  return jsonb_build_object(
    'summary', summary,
    'send', summary = 'daily' or missing > 0,
    'automatic_publication_suspended', suspended,
    'cinemas_without_success', without_success,
    'text', message
  );
end;
$$;

-- Whether today's daily collection has finished, in the time zone of every
-- city with an active cinema. Only the collection watchman asks it.
create function public.daily_collection_status(reference_time timestamptz default now())
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('finished', not exists (
    select 1
    from (
      select distinct city.timezone
      from public.cinemas as cinema
      join public.cities as city on city.id = cinema.city_id
      where cinema.active
    ) as zone
    where not exists (
      select 1
      from public.collections as collection
      where collection.type = 'daily'
        and collection.finished_at <= reference_time
        and (collection.finished_at at time zone zone.timezone)::date
          = (reference_time at time zone zone.timezone)::date
    )
  ));
$$;

revoke all on function public.start_collection(public.collection_type, text[], boolean, timestamptz)
  from anon, authenticated, public;
revoke all on function public.start_reading(uuid, text, timestamptz) from anon, authenticated, public;
revoke all on function public.finish_collection(uuid, timestamptz) from anon, authenticated, public;
revoke all on function public.record_site_reversion(timestamptz) from anon, authenticated, public;
revoke all on function public.record_site_publication(timestamptz) from anon, authenticated, public;
revoke all on function public.collection_summary(text, timestamptz) from anon, authenticated, public;
revoke all on function public.daily_collection_status(timestamptz) from anon, authenticated, public;
grant execute on function public.start_collection(public.collection_type, text[], boolean, timestamptz)
  to service_role;
grant execute on function public.start_reading(uuid, text, timestamptz) to service_role;
grant execute on function public.finish_collection(uuid, timestamptz) to service_role;
grant execute on function public.record_site_reversion(timestamptz) to service_role;
grant execute on function public.record_site_publication(timestamptz) to service_role;
grant execute on function public.collection_summary(text, timestamptz) to service_role;
grant execute on function public.daily_collection_status(timestamptz) to service_role;
grant execute on function private.failure_type_name(public.reading_failure_type) to service_role;
