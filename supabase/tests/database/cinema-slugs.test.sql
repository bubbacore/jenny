begin;

select plan(8);

select is(
  (select previous_slugs from public.site_cinemas where slug = 'cinema-do-centro'),
  '{}'::text[],
  'um cinema sem troca de identificador tem uma lista vazia de anteriores'
);

select lives_ok(
  $$ update public.cinemas set previous_slugs = '{cine-antigo,cinema-anterior}'
     where slug = 'cinema-do-centro' $$,
  'aceita identificadores anteriores de um cinema'
);

select is(
  (select previous_slugs from public.site_cinemas where slug = 'cinema-do-centro'),
  '{cine-antigo,cinema-anterior}'::text[],
  'a visão do build traz os identificadores anteriores na ordem cadastrada'
);

select throws_ok(
  $$ update public.cinemas set previous_slugs = '{cinema-do-centro}'
     where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa um identificador anterior igual ao atual'
);

select throws_ok(
  $$ update public.cinemas set previous_slugs = '{cine-antigo,cine-antigo}'
     where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa identificadores anteriores repetidos'
);

select throws_ok(
  $$ update public.cinemas set previous_slugs = '{""}' where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa um identificador anterior vazio'
);

select throws_ok(
  $$ update public.cinemas set previous_slugs = '{Cinema Antigo}'
     where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa um identificador anterior fora do formato dos identificadores'
);

select throws_ok(
  $$ update public.cinemas set previous_slugs = array[null]::text[]
     where slug = 'cinema-do-centro' $$,
  '23514', null,
  'recusa um identificador anterior ausente na lista'
);

select * from finish();

rollback;
