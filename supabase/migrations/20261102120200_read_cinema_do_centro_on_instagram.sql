-- The Cinema do Centro publishes its weekly showtimes on Instagram first, and
-- the post does not always reach the official site, as in occurrence 93.
-- Instagram becomes its main source, and the official site stays registered,
-- inactive, until secondary sources exist (ADR 0020). The old source goes
-- inactive first, so the cinema never has two active sources.
update public.sources
set active = false
where type = 'official_site'
  and cinema_id = (select id from public.cinemas where slug = 'cinema-do-centro');

insert into public.sources (cinema_id, type, config)
select id, 'instagram', '{"username": "cinemadocentro"}'
from public.cinemas
where slug = 'cinema-do-centro';
