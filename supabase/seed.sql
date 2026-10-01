-- Fixed test data for the local database only. The v1 registry comes from the
-- migrations; nothing here reaches production.

-- An inactive cinema, which the collection plan must leave out.
insert into public.cinemas (slug, name, city_id, active)
select 'cinema-desativado-de-teste', 'Cinema Desativado de Teste', id, false
from public.cities
where slug = 'aracaju';

insert into public.sources (cinema_id, type, config, active)
select id, 'ingresso_com', '{"theater_id": 999999, "city_id": 4}', false
from public.cinemas
where slug = 'cinema-desativado-de-teste';
