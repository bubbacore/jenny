begin;

select plan(5);

-- Ranking inicial

select is(
  private.initial_source_ranking(),
  array['ingresso_com', 'veloxtickets', 'cinesercla_site', 'official_site', 'instagram']
    ::public.source_type[],
  'o ranking inicial é ingresso.com, Veloxtickets, site da Cinesercla, site oficial e Instagram'
);

select is(
  private.source_type_name('instagram'),
  'Instagram',
  'o Instagram tem nome nos motivos e nos alertas'
);

-- Tipo de fonte novo depois do último cálculo

-- A calculation made before Instagram existed ranks only the other four
-- source types. The test records one in the initial order, inside the
-- transaction of the test.
with calculation as (
  insert into public.source_reliability_calculations (calculated_at, changed)
  values ('2026-11-01T12:00:00-03:00', true)
  returning id
)
insert into public.source_reliabilities (calculation_id, source_type, position, compared, divergences, reason)
select calculation.id, ranked.source_type::public.source_type, ranked.position, 0, 0, 'cálculo de teste'
from calculation
cross join (values
  ('ingresso_com', 1),
  ('veloxtickets', 2),
  ('cinesercla_site', 3),
  ('official_site', 4)
) as ranked (source_type, position);

select results_eq(
  $$ select source_type::text, place from private.source_ranking() order by place $$,
  $$ values ('ingresso_com', 1), ('veloxtickets', 2), ('cinesercla_site', 3),
       ('official_site', 4), ('instagram', 5) $$,
  'um tipo de fonte ausente do último cálculo entra depois dos calculados, na ordem do ranking inicial'
);

create temporary table next_calculation as
select public.update_source_reliability('2028-06-01T12:00:00-03:00') as result;

select is(
  (select result -> 'ranking' -> 4 ->> 'source_type' from next_calculation),
  'instagram',
  'o cálculo seguinte põe o Instagram em último, sem comparações suficientes'
);

select is(
  (select result -> 'changed' from next_calculation),
  'false'::jsonb,
  'a chegada do Instagram ao ranking não conta como mudança nem gera alerta'
);

select * from finish();

rollback;
