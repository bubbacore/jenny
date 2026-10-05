-- Pending ticket type and its resolution. A source ticket the source does not
-- type in a structured way, and whose ticket type the owner has not assigned,
-- is in pending ticket type: its value is kept without a ticket type, out of
-- the site, until the owner assigns the type or says it is not a box office
-- price. The assignment holds for every cinema of the same source type.

-- Case, accents and repeated spaces do not tell two source tickets apart.
create function private.normalized_source_ticket(ticket text)
returns text
language sql
stable
set search_path = ''
as $$
  select lower(extensions.unaccent(
    'extensions.unaccent'::regdictionary,
    regexp_replace(btrim(ticket), '\s+', ' ', 'g')
  ));
$$;

create type public.source_ticket_status as enum ('pending', 'resolved');

-- source_ticket is the name of the last appearance. A resolved source ticket
-- has the ticket type the owner assigned, or not_box_office when it is not a
-- box office price, like a combo with popcorn. disputed_ticket_type is the
-- last structured ticket type the source informed against the assignment,
-- already alerted.
create table public.source_tickets (
  id bigint generated always as identity primary key,
  source_type public.source_type not null,
  source_ticket text not null check (btrim(source_ticket) <> ''),
  normalized_source_ticket text not null check (normalized_source_ticket <> ''),
  status public.source_ticket_status not null default 'pending',
  ticket_type public.ticket_type,
  not_box_office boolean not null default false,
  disputed_ticket_type public.ticket_type,
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  resolved_at timestamptz,
  constraint source_tickets_one_per_source_type unique (source_type, normalized_source_ticket),
  constraint source_tickets_seen_in_order check (first_seen_at <= last_seen_at),
  constraint source_tickets_resolution_is_complete check (
    (status = 'resolved') = (ticket_type is not null or not_box_office)
    and not (ticket_type is not null and not_box_office)
    and (status = 'resolved') = (resolved_at is not null)
    and (status = 'resolved' or disputed_ticket_type is null)
  )
);

alter table public.source_tickets enable row level security;
revoke all on public.source_tickets from anon, authenticated;

-- A value without a ticket type belongs to a source ticket in pending ticket
-- type. It is not a box office price yet, and it stays out of the site.
alter table public.box_office_prices alter column ticket_type drop not null;

create function private.ticket_type_name(type public.ticket_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case type
    when 'full' then 'inteira'
    when 'half' then 'meia'
    when 'promo' then 'promoção'
  end;
$$;

create function private.brl(cents integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'R$ ' || cents / 100 || ',' || lpad((cents % 100)::text, 2, '0');
$$;

-- The subject is the type with the source type and the normalized source
-- ticket, so each source ticket has its own occurrence, shared by every
-- cinema of the source type.
create function private.unknown_ticket_type_alert(
  source_type public.source_type,
  normalized_source_ticket text,
  effect text,
  text text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'type', 'unknown-ticket-type',
    'subject', 'unknown-ticket-type:' || source_type || ':' || normalized_source_ticket,
    'effect', effect,
    'text', text
  );
$$;

-- Records the source tickets of the accepted sessions of a successful
-- reading, before their prices. A source ticket sent without a ticket type
-- and never seen in the source type enters pending ticket type, and only that
-- first appearance raises the alert. A resolved source ticket whose source
-- informs a structured ticket type different from the assignment raises the
-- alert once for that ticket type, and the assignment still holds. Returns
-- the alerts to send.
create function private.record_source_tickets(
  reading jsonb,
  today date,
  closed_weekdays smallint[],
  chosen_source_type public.source_type,
  cinema_name text,
  reference_time timestamptz
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  seen record;
  known record;
  disagreeing public.ticket_type;
  new_id bigint;
  raised_alerts jsonb := '[]';
begin
  for seen in
    select listed.normalized,
      (array_agg(listed.source_ticket order by listed.session_position, listed.price_position))[1]
        as source_ticket,
      (array_agg(listed.kind order by listed.session_position, listed.price_position)
        filter (where listed.kind is not null)) as kinds,
      bool_or(listed.kind is null) as without_kind,
      min(listed.price_cents) as lowest,
      max(listed.price_cents) as highest,
      count(distinct listed.session_position)::integer as sessions
    from (
      select private.normalized_source_ticket(price.value ->> 'source_ticket') as normalized,
        price.value ->> 'source_ticket' as source_ticket,
        (price.value ->> 'kind')::public.ticket_type as kind,
        (price.value ->> 'price_cents')::integer as price_cents,
        accepted.session_position,
        price.price_position
      from private.reading_sessions(reading, today, closed_weekdays)
        with ordinality as accepted (session, tmdb_id, starts_at, outcome, session_position)
      cross join lateral jsonb_array_elements(accepted.session -> 'prices')
        with ordinality as price (value, price_position)
      where accepted.outcome = 'accepted'
    ) as listed
    group by listed.normalized
    order by listed.normalized
  loop
    select ticket.id, ticket.status, ticket.ticket_type, ticket.not_box_office,
      ticket.disputed_ticket_type
    into known
    from public.source_tickets as ticket
    where ticket.source_type = chosen_source_type
      and ticket.normalized_source_ticket = seen.normalized
    for update;

    if found then
      update public.source_tickets
      set source_ticket = seen.source_ticket,
        last_seen_at = greatest(last_seen_at, record_source_tickets.reference_time)
      where id = known.id;

      if known.status = 'resolved' then
        select kind into disagreeing
        from unnest(seen.kinds) as kind
        where kind is distinct from known.ticket_type
        limit 1;

        if disagreeing is not null and disagreeing is distinct from known.disputed_ticket_type then
          update public.source_tickets set disputed_ticket_type = disagreeing where id = known.id;

          raised_alerts := raised_alerts || private.unknown_ticket_type_alert(
            chosen_source_type,
            seen.normalized,
            'open',
            format(
              '%s: %s informou o ingresso na fonte "%s" como %s, mas ele está atribuído como %s. '
                || 'Vale a atribuição até você revê-la.',
              private.source_type_name(chosen_source_type),
              cinema_name,
              seen.source_ticket,
              private.ticket_type_name(disagreeing),
              coalesce(private.ticket_type_name(known.ticket_type), 'não sendo preço de bilheteria')
            )
          );
        end if;
      end if;
    elsif seen.without_kind then
      new_id := null;

      insert into public.source_tickets (
        source_type, source_ticket, normalized_source_ticket, first_seen_at, last_seen_at
      )
      values (
        chosen_source_type,
        seen.source_ticket,
        seen.normalized,
        record_source_tickets.reference_time,
        record_source_tickets.reference_time
      )
      on conflict on constraint source_tickets_one_per_source_type do nothing
      returning id into new_id;

      if new_id is not null then
        raised_alerts := raised_alerts || private.unknown_ticket_type_alert(
          chosen_source_type,
          seen.normalized,
          'open',
          format(
            '%s: o ingresso na fonte "%s" ficou em tipo de ingresso pendente. %s o informou em %s, '
              || 'com %s. Atribua o tipo de ingresso ou indique que ele não é preço de bilheteria; '
              || 'até lá, o valor fica fora do site.',
            private.source_type_name(chosen_source_type),
            seen.source_ticket,
            cinema_name,
            private.counted(seen.sessions, 'sessão', 'sessões'),
            case
              when seen.lowest = seen.highest then private.brl(seen.lowest)
              else 'valores de ' || private.brl(seen.lowest) || ' a ' || private.brl(seen.highest)
            end
          )
        );
      end if;
    end if;
  end loop;

  return raised_alerts;
end;
$$;

-- Records the values of a session. The ticket type assigned to the source
-- ticket comes first, then the one the source informs, and without either the
-- value waits in pending ticket type. A source ticket that is not a box
-- office price is never recorded.
create function private.record_session_prices(
  chosen_session_id bigint,
  prices jsonb,
  chosen_source_type public.source_type
)
returns void
language sql
set search_path = ''
as $$
  insert into public.box_office_prices (session_id, ticket_type, source_ticket, price_cents)
  select chosen_session_id,
    case
      when known.status = 'resolved' then known.ticket_type
      else (price.value ->> 'kind')::public.ticket_type
    end,
    price.value ->> 'source_ticket',
    (price.value ->> 'price_cents')::integer
  from jsonb_array_elements(prices) as price (value)
  left join public.source_tickets as known
    on known.source_type = chosen_source_type
    and known.normalized_source_ticket = private.normalized_source_ticket(price.value ->> 'source_ticket')
  where known.not_box_office is not true;
$$;

-- Records a reading of the reserved cinema. The reading follows the contract,
-- already checked by the ingestion. A successful reading replaces the
-- cinema's whole showtimes, and a failed one erases them. The movies it
-- accepts enter the catalog, with the source values, and the source tickets
-- of its accepted sessions are recorded before their prices. Returns the
-- result with the alerts to send, or a refusal when the reservation does not
-- allow it or the reading does not fit the database.
create or replace function public.record_reading(
  reading_id uuid,
  collection_release text,
  reading jsonb,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  target record;
  effective jsonb;
  issues jsonb;
  today date;
  last_status public.reading_status;
  last_finished_at timestamptz;
  previous integer;
  movie jsonb;
  entry record;
  pending record;
  pending_reason text;
  new_session_id bigint;
  reported text := record_reading.reading ->> 'status';
  received integer := jsonb_array_length(record_reading.reading -> 'sessions');
  discarded integer := 0;
  closed_day integer := 0;
  closed_dates text;
  retained integer := 0;
  accepted integer := 0;
  failure public.reading_failure_type;
  failure_reason text;
  raised_alerts jsonb := '[]';
  identification_alerts jsonb := '[]';
  ticket_alerts jsonb := '[]';
begin
  select recorded.id, recorded.status, recorded.started_at, recorded.cinema_id, recorded.source_id,
    cinema.slug as cinema_slug, cinema.name as cinema_name, cinema.closed_weekdays,
    source.type::text as source_type, city.timezone
  into target
  from public.readings as recorded
  join public.cinemas as cinema on cinema.id = recorded.cinema_id
  join public.cities as city on city.id = cinema.city_id
  join public.sources as source on source.id = recorded.source_id
  where recorded.id = record_reading.reading_id
  for update of recorded;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_reading'));
  end if;
  if target.status <> 'in_progress' then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'reading_closed'));
  end if;
  if private.reservation_expires_at(target.started_at) <= record_reading.reference_time then
    update public.readings set status = 'abandoned' where id = target.id;
    return jsonb_build_object('refusal', jsonb_build_object('code', 'reservation_expired'));
  end if;

  effective := private.with_resolved_source_titles(record_reading.reading, target.cinema_id);

  -- An accepted movie the database does not know yet needs its titles from
  -- at least one of the reading's entries for it, and every image the reading
  -- cites must have been recorded. A failure reported by the Hermes accepts
  -- no movie.
  select coalesce(jsonb_agg(issue order by position), '[]')
  into issues
  from (
    select 0 as position, jsonb_build_object(
      'path', '/reading/cinema',
      'message', format('A reserva é do cinema %s.', target.cinema_slug)
    ) as issue
    where effective ->> 'cinema' is distinct from target.cinema_slug
    union all
    select 1, jsonb_build_object(
      'path', '/reading/source',
      'message', format('A fonte principal do cinema na reserva é %s.', target.source_type)
    )
    where effective ->> 'source' is distinct from target.source_type
    union all
    select 1 + listed.position, jsonb_build_object(
      'path', format('/reading/movies/%s/tmdb', listed.position - 1),
      'message', 'Um filme novo precisa do title e do original_title do TMDB.'
    )
    from jsonb_array_elements(effective -> 'movies') with ordinality as listed (value, position)
    where reported = 'ok'
      and listed.value -> 'tmdb_id' = listed.value -> 'tmdb_search_top_id'
      and not exists (
        select 1 from public.movies where tmdb_id = (listed.value ->> 'tmdb_id')::integer
      )
      and not exists (
        select 1
        from jsonb_array_elements(effective -> 'movies') as other (value)
        where other.value -> 'tmdb_id' = listed.value -> 'tmdb_id'
          and other.value #>> '{tmdb,title}' is not null
          and other.value #>> '{tmdb,original_title}' is not null
      )
  ) as found;

  if reported = 'ok' then
    issues := issues || private.unrecorded_images(effective);
  end if;

  if jsonb_array_length(issues) > 0 then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'invalid_reading', 'issues', issues));
  end if;

  today := (record_reading.reference_time at time zone target.timezone)::date;

  select last_reading.status, last_reading.finished_at
  into last_status, last_finished_at
  from private.last_finished_reading(target.cinema_id, target.started_at) as last_reading;

  -- The previous reading is the last successful one that finished before this
  -- one started.
  select sessions_accepted + sessions_retained
  into previous
  from public.readings
  where cinema_id = target.cinema_id
    and status = 'success'
    and finished_at <= target.started_at
  order by finished_at desc
  limit 1;

  if reported in ('error', 'incomplete') then
    failure := reported::public.reading_failure_type;
    failure_reason := effective ->> 'reason';
  else
    select count(*) filter (where outcome in ('outside_window', 'closed_day')),
      count(*) filter (where outcome = 'closed_day'),
      count(*) filter (where outcome = 'retained'),
      count(*) filter (where outcome = 'accepted')
    into discarded, closed_day, retained, accepted
    from private.reading_sessions(effective, today, target.closed_weekdays);

    select string_agg(to_char(day, 'DD/MM'), ', ' order by day)
    into closed_dates
    from (
      select distinct starts_at::date as day
      from private.reading_sessions(effective, today, target.closed_weekdays)
      where outcome = 'closed_day'
    ) as closed;

    if accepted + retained = 0 and exists (
      select 1
      from generate_series(0, 6) as day
      where extract(isodow from today + day)::smallint <> all (target.closed_weekdays)
    ) then
      failure := 'outdated';
      failure_reason := 'A leitura não trouxe nenhuma sessão de hoje em diante, '
        || 'e o cinema funciona em algum dia da janela.';
    elsif accepted = 0 and retained > 0 then
      failure := 'retained';
      failure_reason := format(
        'Todas as sessões da leitura ficaram retidas por identificação pendente (%s)',
        private.counted(retained, 'sessão', 'sessões')
      );
    end if;

    -- Each source title with retained sessions is a pending identification.
    -- Only a new one raises the alert; a later appearance updates it.
    for pending in
      select distinct on (titles.normalized) titles.normalized, titles.movie, titles.retained
      from (
        select private.normalized_source_title(listed.value ->> 'source_title') as normalized,
          listed.value as movie,
          (
            select count(*)
            from private.reading_sessions(effective, today, target.closed_weekdays) as listed_session
            where listed_session.outcome = 'retained'
              and listed_session.session ->> 'movie_key' = listed.value ->> 'key'
          )::integer as retained
        from jsonb_array_elements(effective -> 'movies') as listed (value)
      ) as titles
      where titles.retained > 0
      order by titles.normalized, titles.retained desc
    loop
      pending_reason := case
        when pending.movie -> 'tmdb_search_top_id' = 'null'::jsonb then format(
          'A busca no TMDB não trouxe resultado, e o filme proposto foi o TMDB %s.',
          pending.movie ->> 'tmdb_id'
        )
        else format(
          'O filme proposto, o TMDB %s, difere do primeiro resultado da busca no TMDB, o %s.',
          pending.movie ->> 'tmdb_id',
          pending.movie ->> 'tmdb_search_top_id'
        )
      end;

      update public.pending_identifications
      set source_title = pending.movie ->> 'source_title',
        proposed_tmdb_id = (pending.movie ->> 'tmdb_id')::integer,
        search_top_tmdb_id = (pending.movie ->> 'tmdb_search_top_id')::integer,
        reason = pending_reason,
        last_seen_at = greatest(last_seen_at, record_reading.reference_time)
      where cinema_id = target.cinema_id
        and normalized_source_title = pending.normalized
        and status = 'pending';

      if not found then
        insert into public.pending_identifications (
          cinema_id, source_title, normalized_source_title, proposed_tmdb_id,
          search_top_tmdb_id, reason, first_seen_at, last_seen_at
        )
        values (
          target.cinema_id,
          pending.movie ->> 'source_title',
          pending.normalized,
          (pending.movie ->> 'tmdb_id')::integer,
          (pending.movie ->> 'tmdb_search_top_id')::integer,
          pending_reason,
          record_reading.reference_time,
          record_reading.reference_time
        );

        identification_alerts := identification_alerts || private.pending_identification_alert(
          target.cinema_slug,
          pending.normalized,
          'open',
          format(
            '%s: o título na fonte "%s" ficou em identificação pendente, com %s. %s Escolha o filme para liberar as sessões.',
            target.cinema_name,
            pending.movie ->> 'source_title',
            private.counted(pending.retained, 'sessão retida', 'sessões retidas'),
            pending_reason
          )
        );
      end if;
    end loop;
  end if;

  delete from public.sessions where cinema_id = target.cinema_id;

  -- The accepted movies enter the catalog with what the source informed about
  -- them, before their sessions.
  if failure is null then
    perform private.record_reading_movies(
      effective,
      target.id,
      target.source_id,
      record_reading.reference_time
    );

    ticket_alerts := private.record_source_tickets(
      effective,
      today,
      target.closed_weekdays,
      target.source_type::public.source_type,
      target.cinema_name,
      record_reading.reference_time
    );

    for entry in
      select listed.session, listed.starts_at, accepted_movie.id as movie_id
      from private.reading_sessions(effective, today, target.closed_weekdays) as listed
      join public.movies as accepted_movie on accepted_movie.tmdb_id = listed.tmdb_id
      where listed.outcome = 'accepted'
    loop
      insert into public.sessions (cinema_id, movie_id, reading_id, starts_at, room, audio, format, tags, external_id)
      values (
        target.cinema_id,
        entry.movie_id,
        target.id,
        entry.starts_at,
        entry.session ->> 'room',
        (entry.session ->> 'audio')::public.session_audio,
        (entry.session ->> 'format')::public.session_format,
        array(select jsonb_array_elements_text(entry.session -> 'tags')),
        entry.session ->> 'external_id'
      )
      returning id into new_session_id;

      perform private.record_session_prices(
        new_session_id,
        entry.session -> 'prices',
        target.source_type::public.source_type
      );
    end loop;
  end if;

  -- The first failure of the day opens the occurrence, and the next success
  -- of the cinema resolves it. A failure after another of the same day adds
  -- nothing.
  if failure is not null then
    if last_status is distinct from 'failure'
      or (last_finished_at at time zone target.timezone)::date < today then
      raised_alerts := raised_alerts || private.cinema_alert(
        'collection-failure',
        target.cinema_slug,
        'open',
        format(
          '%s: leitura com falha (%s). Motivo: %s. A programação do cinema foi apagada, e o site mostra "atualizando".',
          target.cinema_name,
          private.failure_type_name(failure),
          rtrim(btrim(failure_reason), '.')
        )
      );
    end if;
  elsif last_status = 'failure' then
    raised_alerts := raised_alerts || private.cinema_alert(
      'collection-failure',
      target.cinema_slug,
      'resolve',
      format(
        '%s: a leitura voltou a ter sucesso, com %s.',
        target.cinema_name,
        private.counted(accepted, 'sessão aceita', 'sessões aceitas')
      )
    );
  end if;

  raised_alerts := raised_alerts || identification_alerts || ticket_alerts;

  -- More than half of the sessions gone is accepted, but alerted.
  if failure is null and previous > 0 and 2 * (accepted + retained) < previous then
    raised_alerts := raised_alerts || private.cinema_alert(
      'session-drop',
      target.cinema_slug,
      'open',
      format(
        '%s: queda brusca de sessões, de %s na última leitura com sucesso para %s nesta. As sessões foram aceitas.',
        target.cinema_name,
        previous,
        accepted + retained
      )
    );
  end if;

  if closed_day > 0 then
    raised_alerts := raised_alerts || private.cinema_alert(
      'closed-day-session',
      target.cinema_slug,
      'open',
      format(
        '%s: %s em dia sem funcionamento (%s). Confira se os dias de funcionamento do cinema mudaram.',
        target.cinema_name,
        case when closed_day = 1
          then '1 sessão foi descartada'
          else closed_day || ' sessões foram descartadas'
        end,
        closed_dates
      )
    );
  end if;

  update public.readings
  set status = case when failure is null then 'success' else 'failure' end::public.reading_status,
    failure_type = failure,
    reason = failure_reason,
    collection_release = record_reading.collection_release,
    finished_at = record_reading.reference_time,
    sessions_received = received,
    sessions_discarded = discarded,
    sessions_accepted = accepted,
    sessions_retained = retained,
    previous_sessions = previous,
    alerts = raised_alerts
  where id = target.id;

  return jsonb_build_object(
    'reading_id', target.id,
    'result', case when failure is null then 'success' else 'failure' end,
    'sessions', jsonb_build_object(
      'received', received,
      'discarded', discarded,
      'accepted', accepted,
      'retained', retained
    ),
    'alerts', raised_alerts
  ) || case
    when failure is null then '{}'::jsonb
    else jsonb_build_object('failure_type', failure, 'reason', failure_reason)
  end;
end;
$$;

-- Resolves a source ticket of a source type with the ticket type the owner
-- assigned, or with not_box_office when it is not a box office price. The
-- resolution applies to the values kept in every cinema of the source type,
-- with no recollection: they take the assigned ticket type, or are discarded
-- when the source ticket is not a box office price. A resolved source ticket
-- may be resolved again, after the source informs a different ticket type.
-- Returns the alert that resolves the occurrence, or a refusal when the source
-- type never had that source ticket in pending ticket type.
create function public.resolve_pending_ticket_type(
  source_type public.source_type,
  source_ticket text,
  assignment text,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  known record;
  assigned public.ticket_type := case
    when resolve_pending_ticket_type.assignment <> 'not_box_office'
      then resolve_pending_ticket_type.assignment::public.ticket_type
  end;
  changed integer;
begin
  select ticket.id, ticket.source_ticket, ticket.normalized_source_ticket
  into known
  from public.source_tickets as ticket
  where ticket.source_type = resolve_pending_ticket_type.source_type
    and ticket.normalized_source_ticket
      = private.normalized_source_ticket(resolve_pending_ticket_type.source_ticket)
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_source_ticket'));
  end if;

  update public.source_tickets
  set status = 'resolved',
    ticket_type = assigned,
    not_box_office = assigned is null,
    resolved_at = resolve_pending_ticket_type.reference_time
  where id = known.id;

  if assigned is null then
    delete from public.box_office_prices as price
    using public.sessions as session, public.readings as reading, public.sources as source
    where session.id = price.session_id
      and reading.id = session.reading_id
      and source.id = reading.source_id
      and source.type = resolve_pending_ticket_type.source_type
      and private.normalized_source_ticket(price.source_ticket) = known.normalized_source_ticket;
  else
    update public.box_office_prices as price
    set ticket_type = assigned
    from public.sessions as session, public.readings as reading, public.sources as source
    where session.id = price.session_id
      and reading.id = session.reading_id
      and source.id = reading.source_id
      and source.type = resolve_pending_ticket_type.source_type
      and private.normalized_source_ticket(price.source_ticket) = known.normalized_source_ticket
      and price.ticket_type is distinct from assigned;
  end if;
  get diagnostics changed = row_count;

  return jsonb_build_object(
    'alerts', jsonb_build_array(private.unknown_ticket_type_alert(
      resolve_pending_ticket_type.source_type,
      known.normalized_source_ticket,
      'resolve',
      case
        when assigned is null then format(
          '%s: o ingresso na fonte "%s" não é preço de bilheteria e nunca aparece no site, '
            || 'em nenhum cinema deste tipo de fonte. Valores guardados descartados: %s.',
          private.source_type_name(resolve_pending_ticket_type.source_type),
          known.source_ticket,
          changed
        )
        else format(
          '%s: o ingresso na fonte "%s" agora é %s em todos os cinemas deste tipo de fonte. '
            || 'Valores guardados atualizados: %s. Eles aparecem na próxima publicação do site.',
          private.source_type_name(resolve_pending_ticket_type.source_type),
          known.source_ticket,
          private.ticket_type_name(assigned),
          changed
        )
      end
    ))
  );
end;
$$;

-- The accepted sessions of the active cinemas. starts_at is local time in the
-- cinema's city, and date is the calendar date the session starts on. prices
-- holds only box office prices, and other_tickets tells that the session also
-- has a value in pending ticket type.
create or replace view public.site_showtimes
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
    where price.session_id = session.id and price.ticket_type is not null
  ), '[]') as prices,
  exists (
    select 1
    from public.box_office_prices as price
    where price.session_id = session.id and price.ticket_type is null
  ) as other_tickets
from public.sessions as session
join public.cinemas as cinema on cinema.id = session.cinema_id and cinema.active
join public.movies as movie on movie.id = session.movie_id;

revoke all on public.site_showtimes from anon, authenticated;

revoke all on function public.resolve_pending_ticket_type(public.source_type, text, text, timestamptz)
  from anon, authenticated, public;
grant execute on function public.resolve_pending_ticket_type(public.source_type, text, text, timestamptz)
  to service_role;
grant execute on function private.normalized_source_ticket(text) to service_role;
grant execute on function private.ticket_type_name(public.ticket_type) to service_role;
grant execute on function private.brl(integer) to service_role;
grant execute on function private.unknown_ticket_type_alert(public.source_type, text, text, text)
  to service_role;
grant execute on function private.record_source_tickets(jsonb, date, smallint[], public.source_type, text, timestamptz)
  to service_role;
grant execute on function private.record_session_prices(bigint, jsonb, public.source_type) to service_role;
