begin;

select plan(22);

-- Configuração própria do tipo de fonte

create temporary table new_cinema as
with inserted as (
  insert into public.cinemas (slug, name, city_id, active)
  select 'cinema-novo-de-teste', 'Cinema Novo de Teste', id, false from public.cities where slug = 'aracaju'
  returning id
)
select id from inserted;

create function pg_temp.add_source(type text, config text, active boolean default false)
returns void
language sql
as $$
  insert into public.sources (cinema_id, type, config, active)
  select id, type::public.source_type, config::jsonb, active from new_cinema;
$$;

select lives_ok(
  $$ select pg_temp.add_source('ingresso_com', '{"theater_id": 1, "city_id": 4}') $$,
  'aceita a configuração completa do ingresso.com'
);

select throws_ok(
  $$ select pg_temp.add_source('ingresso_com', '{"theater_id": 1}') $$,
  '23514', null,
  'recusa a configuração do ingresso.com sem city_id'
);

select throws_ok(
  $$ select pg_temp.add_source('ingresso_com', '{"theater_id": "313", "city_id": 4}') $$,
  '23514', null,
  'recusa o theater_id do ingresso.com como texto'
);

select throws_ok(
  $$ select pg_temp.add_source('veloxtickets', '{"url": "https://exemplo.com/", "extra": 1}') $$,
  '23514', null,
  'recusa um campo que não é do tipo de fonte'
);

select throws_ok(
  $$ select pg_temp.add_source('veloxtickets', '{"url": "http://exemplo.com/"}') $$,
  '23514', null,
  'recusa o endereço do Veloxtickets sem https'
);

select throws_ok(
  $$ select pg_temp.add_source('cinesercla_site', '{"unit_slug": "praia-sul"}') $$,
  '23514', null,
  'recusa a configuração do site da Cinesercla sem ingresso_plus_group'
);

select throws_ok(
  $$ select pg_temp.add_source('official_site', '{"url": "https://exemplo.com/", "wordpress_category_id": 3}') $$,
  '23514', null,
  'recusa a configuração do site oficial sem post_title_prefix'
);

select throws_ok(
  $$ select pg_temp.add_source('official_site', '[]') $$,
  '23514', null,
  'recusa uma configuração que não é um objeto'
);

select lives_ok(
  $$ select pg_temp.add_source('official_site',
       '{"url": "https://exemplo.com/", "wordpress_category_id": 3, "post_title_prefix": "Confira"}') $$,
  'aceita a configuração completa do site oficial'
);

-- Exatamente uma fonte ativa por cinema ativo

select throws_ok(
  $$ insert into public.sources (cinema_id, type, config)
     select id, 'veloxtickets', '{"url": "https://exemplo.com/outra"}'
     from public.cinemas where slug = 'cinema-do-centro' $$,
  '23505', null,
  'recusa uma segunda fonte ativa num cinema'
);

savepoint without_source;
select throws_ok(
  $$ update public.sources set active = false
     where cinema_id = (select id from public.cinemas where slug = 'cinema-do-centro');
     set constraints all immediate $$,
  'P0001', null,
  'recusa um cinema ativo sem fonte ativa'
);
rollback to savepoint without_source;

savepoint activate_without_source;
select throws_ok(
  $$ update public.cinemas set active = true where id = (select id from new_cinema);
     set constraints all immediate $$,
  'P0001', null,
  'recusa ativar um cinema sem fonte ativa'
);
rollback to savepoint activate_without_source;

savepoint switch_source;
select lives_ok(
  $$ update public.sources set active = false
     where cinema_id = (select id from public.cinemas where slug = 'cinema-do-centro');
     insert into public.sources (cinema_id, type, config)
     select id, 'veloxtickets', '{"url": "https://exemplo.com/nova"}'
     from public.cinemas where slug = 'cinema-do-centro';
     set constraints all immediate $$,
  'aceita trocar a fonte ativa de um cinema na mesma migration'
);
rollback to savepoint switch_source;

savepoint deactivate_cinema;
select lives_ok(
  $$ update public.cinemas set active = false where slug = 'cinema-do-centro';
     update public.sources set active = false
     where cinema_id = (select id from public.cinemas where slug = 'cinema-do-centro');
     set constraints all immediate $$,
  'aceita desativar um cinema junto com a sua fonte'
);
rollback to savepoint deactivate_cinema;

select is(
  (select count(*)::integer from public.cinemas as cinema
   where cinema.active
     and (select count(*) from public.sources where cinema_id = cinema.id and active) <> 1),
  0,
  'todo cinema ativo dos cadastros tem exatamente uma fonte ativa'
);

-- Nomes populares e nome oficial

select is(
  (select official_name from public.cinemas where slug = 'cinema-do-centro'),
  'Cine Walmir Almeida',
  'o Cinema do Centro tem o nome oficial Cine Walmir Almeida'
);

select lives_ok(
  $$ update public.cinemas set other_popular_names = '{"Cine Walmir"}' where slug = 'cinema-do-centro' $$,
  'aceita outros nomes populares diferentes do principal e do oficial'
);

select throws_ok(
  $$ update public.cinemas set official_name = 'cinema do centro' where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa um nome oficial igual a um nome popular, sem distinguir maiúsculas'
);

select throws_ok(
  $$ update public.cinemas set other_popular_names = '{"Cine Walmir", " Cine Walmir "}' where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa nomes populares repetidos'
);

select throws_ok(
  $$ update public.cinemas set other_popular_names = '{" "}' where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa um nome popular em branco'
);

-- Visões

select throws_ok(
  $$ create view public.unsafe_cinemas as select slug from public.cinemas $$,
  'P0001', null,
  'recusa uma visão que ignora as regras de acesso por linha'
);

select lives_ok(
  $$ create view public.safe_cinemas with (security_invoker = true) as select slug from public.cinemas $$,
  'aceita uma visão com security_invoker'
);

select * from finish();

rollback;
