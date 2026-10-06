-- The Google rating of each cinema, updated every week by the Hermes, and the
-- coordinates and the Google reviews link it proposes, which hold only after
-- the owner approves them.

alter table public.cinemas
  add column latitude numeric(8, 6) check (latitude between -90 and 90),
  add column longitude numeric(9, 6) check (longitude between -180 and 180),
  add column google_reviews_url text check (google_reviews_url ~ '^https://[^[:space:]]+$'),
  add column google_rating numeric(2, 1) check (google_rating between 1 and 5),
  add column google_reviews_count integer check (google_reviews_count > 0),
  add column google_rating_updated_at timestamptz,
  add constraint cinemas_coordinates_are_complete check ((latitude is null) = (longitude is null)),
  add constraint cinemas_google_rating_is_complete check (
    (google_rating is null) = (google_reviews_count is null)
    and (google_rating is null) = (google_rating_updated_at is null)
  );

comment on column public.cinemas.latitude is 'The approved latitude. A proposal waits in cinema_proposals.';
comment on column public.cinemas.google_reviews_url is 'The approved link of the Google reviews.';

create type public.proposal_decision as enum ('approved', 'rejected');

-- Every proposal of the Hermes, with the owner's decision. A cinema has at
-- most one pending proposal, and a rejected one is kept so that the same
-- proposal sent again does not reach the owner a second time.
create table public.cinema_proposals (
  id bigint generated always as identity primary key,
  cinema_id bigint not null references public.cinemas,
  latitude numeric(8, 6) not null check (latitude between -90 and 90),
  longitude numeric(9, 6) not null check (longitude between -180 and 180),
  google_reviews_url text not null check (google_reviews_url ~ '^https://[^[:space:]]+$'),
  proposed_at timestamptz not null,
  decision public.proposal_decision,
  decided_at timestamptz,
  constraint cinema_proposals_decision_has_date check ((decision is null) = (decided_at is null))
);

create unique index cinema_proposals_one_pending_per_cinema
  on public.cinema_proposals (cinema_id) where decision is null;
create index cinema_proposals_cinema_id_idx on public.cinema_proposals (cinema_id);

alter table public.cinema_proposals enable row level security;
revoke all on public.cinema_proposals from anon, authenticated;

create function private.coordinates_text(latitude numeric, longitude numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(latitude, 'FM990.000000') || ', ' || to_char(longitude, 'FM9990.000000');
$$;

-- The coordinates and the Google reviews link, as the owner reads them in an
-- alert, or null without them. The map link lets the owner check the place.
create function private.proposal_values_text(latitude numeric, longitude numeric, google_reviews_url text)
returns text
language sql
immutable
set search_path = ''
as $$
  select format(
    'as coordenadas %s (https://www.google.com/maps?q=%s,%s) e o link das avaliações do Google %s',
    private.coordinates_text(latitude, longitude),
    latitude,
    longitude,
    google_reviews_url
  )
  where latitude is not null;
$$;

-- Records the weekly Google rating of the cinema and the coordinates and
-- Google reviews link the Hermes proposes, each one optional. A proposal is
-- new when it differs from the approved values, from the pending proposal and
-- from every proposal the owner rejected; a new proposal replaces the pending
-- one and raises the alert that opens the proposal occurrence. Returns the
-- alerts and, when a proposal came, what it was: new, pending, approved or
-- rejected.
create function public.update_cinema(
  cinema_slug text,
  google_rating jsonb default null,
  proposal jsonb default null,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  cinema record;
  proposed record;
  pending record;
  outcome text;
  alerts jsonb := '[]';
begin
  select id, slug, name, latitude, longitude, google_reviews_url
  into cinema
  from public.cinemas
  where slug = update_cinema.cinema_slug
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_cinema'));
  end if;

  if update_cinema.google_rating is not null then
    update public.cinemas
    set google_rating = (update_cinema.google_rating ->> 'rating')::numeric,
      google_reviews_count = (update_cinema.google_rating ->> 'reviews')::integer,
      google_rating_updated_at = update_cinema.reference_time
    where id = cinema.id;
  end if;

  if update_cinema.proposal is null then
    return jsonb_build_object('alerts', alerts);
  end if;

  -- Rounded as the columns keep them, so that the same place compares equal.
  select (update_cinema.proposal ->> 'latitude')::numeric(8, 6) as latitude,
    (update_cinema.proposal ->> 'longitude')::numeric(9, 6) as longitude,
    update_cinema.proposal ->> 'google_reviews_url' as google_reviews_url
  into proposed;

  select id, latitude, longitude, google_reviews_url
  into pending
  from public.cinema_proposals
  where cinema_id = cinema.id and decision is null
  for update;

  outcome := case
    when (cinema.latitude, cinema.longitude, cinema.google_reviews_url)
      is not distinct from (proposed.latitude, proposed.longitude, proposed.google_reviews_url)
      then 'approved'
    when pending.id is not null
      and (pending.latitude, pending.longitude, pending.google_reviews_url)
        = (proposed.latitude, proposed.longitude, proposed.google_reviews_url)
      then 'pending'
    when exists (
      select 1
      from public.cinema_proposals as rejected
      where rejected.cinema_id = cinema.id
        and rejected.decision = 'rejected'
        and (rejected.latitude, rejected.longitude, rejected.google_reviews_url)
          = (proposed.latitude, proposed.longitude, proposed.google_reviews_url)
    ) then 'rejected'
    else 'new'
  end;

  if outcome = 'new' then
    delete from public.cinema_proposals where id = pending.id;
    insert into public.cinema_proposals (cinema_id, latitude, longitude, google_reviews_url, proposed_at)
    values (cinema.id, proposed.latitude, proposed.longitude, proposed.google_reviews_url,
      update_cinema.reference_time);

    alerts := jsonb_build_array(private.cinema_alert(
      'proposal',
      cinema.slug,
      'open',
      format(
        '%s: o Hermes propôs %s. %s Aprove para que a proposta valha no site, ou rejeite para '
          || 'manter o que vale hoje.',
        cinema.name,
        private.proposal_values_text(proposed.latitude, proposed.longitude, proposed.google_reviews_url),
        coalesce(
          'Hoje valem '
            || private.proposal_values_text(cinema.latitude, cinema.longitude, cinema.google_reviews_url)
            || '.',
          'Hoje o cinema não tem coordenadas nem link das avaliações do Google.'
        )
      )
    ));
  end if;

  return jsonb_build_object('proposal', outcome, 'alerts', alerts);
end;
$$;

-- Approves or rejects the pending proposal of the cinema. An approval makes
-- the proposed coordinates and Google reviews link hold, and a rejection
-- keeps what held before. Both return the alert that resolves the proposal
-- occurrence.
create function public.decide_proposal(
  cinema_slug text,
  decision public.proposal_decision,
  reference_time timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  cinema record;
  pending record;
begin
  select id, slug, name, latitude, longitude, google_reviews_url
  into cinema
  from public.cinemas
  where slug = decide_proposal.cinema_slug
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'unknown_cinema'));
  end if;

  select id, latitude, longitude, google_reviews_url
  into pending
  from public.cinema_proposals
  where cinema_id = cinema.id and cinema_proposals.decision is null
  for update;

  if not found then
    return jsonb_build_object('refusal', jsonb_build_object('code', 'no_pending_proposal'));
  end if;

  update public.cinema_proposals
  set decision = decide_proposal.decision,
    decided_at = decide_proposal.reference_time
  where id = pending.id;

  if decide_proposal.decision = 'approved' then
    update public.cinemas
    set latitude = pending.latitude,
      longitude = pending.longitude,
      google_reviews_url = pending.google_reviews_url
    where id = cinema.id;
  end if;

  return jsonb_build_object('alerts', jsonb_build_array(private.cinema_alert(
    'proposal',
    cinema.slug,
    'resolve',
    case decide_proposal.decision
      when 'approved' then format(
        '%s: proposta aprovada. Passam a valer %s, a partir da próxima publicação do site.',
        cinema.name,
        private.proposal_values_text(pending.latitude, pending.longitude, pending.google_reviews_url)
      )
      else format(
        '%s: proposta rejeitada. %s Se o Hermes propuser o mesmo de novo, a proposta é ignorada.',
        cinema.name,
        coalesce(
          'Continuam valendo '
            || private.proposal_values_text(cinema.latitude, cinema.longitude, cinema.google_reviews_url)
            || '.',
          'O cinema continua sem coordenadas nem link das avaliações do Google.'
        )
      )
    end
  )));
end;
$$;

-- name is the main popular name. The search also finds the cinema by the other
-- popular names and the official name. The coordinates and the Google reviews
-- link are the approved ones; a pending proposal never reaches the site.
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
  cinema.google_reviews_count
from public.cinemas as cinema
join public.cities as city on city.id = cinema.city_id
left join public.chains as chain on chain.id = cinema.chain_id
where cinema.active;

revoke all on public.site_cinemas from anon, authenticated;

revoke all on function public.update_cinema(text, jsonb, jsonb, timestamptz)
  from anon, authenticated, public;
grant execute on function public.update_cinema(text, jsonb, jsonb, timestamptz) to service_role;
revoke all on function public.decide_proposal(text, public.proposal_decision, timestamptz)
  from anon, authenticated, public;
grant execute on function public.decide_proposal(text, public.proposal_decision, timestamptz)
  to service_role;
grant execute on function private.coordinates_text(numeric, numeric) to service_role;
grant execute on function private.proposal_values_text(numeric, numeric, text) to service_role;
