begin;

select plan(7);

-- Identificador para o endereço

select is(
  private.new_movie_slug('Avengers: Endgame', 'Vingadores: Ultimato', 2019::smallint, 299534),
  'avengers-endgame',
  'o identificador vem do título original, e não do título no Brasil'
);

select is(
  private.new_movie_slug('Se Eu Fosse Você 3', 'Se Eu Fosse Você 3', 2026::smallint, 1000001),
  'se-eu-fosse-voce-3',
  'um filme brasileiro fica com o título em português, sem acentos'
);

select is(
  private.new_movie_slug('千と千尋の神隠し', 'A Viagem de Chihiro', 2001::smallint, 129),
  'a-viagem-de-chihiro',
  'um título original sem nenhuma letra nem algarismo latino dá lugar ao título no Brasil'
);

insert into public.movies (tmdb_id, slug, title, original_title, year)
values (1576, 'resident-evil', 'Resident Evil: O Hóspede Maldito', 'Resident Evil', 2002);

select is(
  private.new_movie_slug('Resident Evil', 'Resident Evil', 2026::smallint, 1000002),
  'resident-evil-2026',
  'quando outro filme já tem o identificador, o filme ganha o ano'
);

select is(
  private.new_movie_slug('Resident Evil', 'Resident Evil', 2002::smallint, 1000003),
  'resident-evil-1000003',
  'quando o outro filme é do mesmo ano, o filme ganha o identificador do TMDB'
);

insert into public.movies (tmdb_id, slug, title, original_title, year)
values (1000002, 'resident-evil-2026', 'Resident Evil', 'Resident Evil', 2026);

select is(
  private.new_movie_slug('Resident Evil', 'Resident Evil', 2026::smallint, 1000004),
  'resident-evil-1000004',
  'quando o identificador com o ano também já existe, o filme ganha o identificador do TMDB'
);

select is(
  private.new_movie_slug('Resident Evil', 'Resident Evil', null, 1000005),
  'resident-evil-1000005',
  'quando o ano falta, o filme ganha o identificador do TMDB'
);

select * from finish();

rollback;
