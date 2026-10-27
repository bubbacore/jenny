-- Do not change an identifier while a collection still uses its saved plan
-- or an unresolved decision still refers to it in an alert.
do $$
begin
  lock table public.collections, public.readings,
    public.pending_identifications, public.cinema_proposals in share mode;

  if exists (
    select 1
    from public.collection_cinemas as collected
    join public.collections as collection on collection.id = collected.collection_id
    join public.cinemas as cinema on cinema.id = collected.cinema_id
    where cinema.slug = 'cinemark-shopping-jardins' and collection.finished_at is null
  ) or exists (
    select 1
    from public.readings as reading
    join public.cinemas as cinema on cinema.id = reading.cinema_id
    where cinema.slug = 'cinemark-shopping-jardins' and reading.status = 'in_progress'
  ) then
    raise exception 'Cannot change the cinema slug during an unfinished collection or reading';
  end if;

  if exists (
    select 1
    from public.pending_identifications as identification
    join public.cinemas as cinema on cinema.id = identification.cinema_id
    where cinema.slug = 'cinemark-shopping-jardins' and identification.status = 'pending'
  ) or exists (
    select 1
    from public.cinema_proposals as proposal
    join public.cinemas as cinema on cinema.id = proposal.cinema_id
    where cinema.slug = 'cinemark-shopping-jardins' and proposal.decision is null
  ) then
    raise exception 'Cannot change the cinema slug while an identification or proposal is pending';
  end if;
  -- Keep the same cinema id and every existing source, session and reading.
  update public.cinemas
  set slug = 'cinemark-jardins',
      previous_slugs = previous_slugs || array['cinemark-shopping-jardins']
  where slug = 'cinemark-shopping-jardins';
end;
$$;
