-- The cities, chains, cinemas and sources of Bubba v1, with the source
-- configs checked against the sources on 2026-10-01.

insert into public.cities (slug, name, state, timezone) values
  ('aracaju', 'Aracaju', 'SE', 'America/Maceio'),
  ('nossa-senhora-do-socorro', 'Nossa Senhora do Socorro', 'SE', 'America/Maceio');

insert into public.chains (slug, name, website_url) values
  ('cinemark', 'Cinemark', 'https://www.cinemark.com.br/'),
  ('centerplex', 'Centerplex', 'https://centerplex.com.br/'),
  ('cinesercla', 'Cinesercla', 'https://cinesercla.com.br/');

insert into public.cinemas (slug, name, city_id, chain_id, website_url, closed_weekdays)
select cinema.slug, cinema.name, city.id, chain.id, cinema.website_url, cinema.closed_weekdays
from (values
  ('cinemark-shopping-jardins', 'Cinemark Shopping Jardins', 'aracaju', 'cinemark', null, '{}'::smallint[]),
  ('cinemark-riomar', 'Cinemark RioMar', 'aracaju', 'cinemark', null, '{}'),
  ('centerplex-parque-shopping', 'Centerplex Parque Shopping', 'aracaju', 'centerplex', null, '{}'),
  ('cinesercla-praia-sul', 'Cinesercla Praia Sul', 'aracaju', 'cinesercla', null, '{}'),
  ('cinesercla-premio', 'Cinesercla Prêmio', 'nossa-senhora-do-socorro', 'cinesercla', null, '{}'),
  ('cinema-do-centro', 'Cinema do Centro', 'aracaju', null, 'https://cinemadocentro.com.br/', '{2,3}'),
  ('cine-alquimia', 'Cine Alquimia', 'aracaju', null, null, '{}')
) as cinema (slug, name, city_slug, chain_slug, website_url, closed_weekdays)
join public.cities as city on city.slug = cinema.city_slug
left join public.chains as chain on chain.slug = cinema.chain_slug;

insert into public.sources (cinema_id, type, config)
select cinema.id, source.type::public.source_type, source.config::jsonb
from (values
  ('cinemark-shopping-jardins', 'ingresso_com', '{"theater_id": 313, "city_id": 4}'),
  ('cinemark-riomar', 'ingresso_com', '{"theater_id": 762, "city_id": 4}'),
  ('centerplex-parque-shopping', 'veloxtickets',
    '{"url": "https://www.veloxtickets.com/Parceiro/P-centerplex/Local/Cinema/Aracaju/Centerplex-Parque-Shopping-Aracaju/ARC"}'),
  ('cinesercla-praia-sul', 'cinesercla_site', '{"unit_slug": "praia-sul", "ingresso_plus_group": "PRAIASUL"}'),
  ('cinesercla-premio', 'cinesercla_site',
    '{"unit_slug": "nossa-senhora-do-socorro", "ingresso_plus_group": "CINESERCLAPREMI"}'),
  ('cinema-do-centro', 'official_site',
    '{"url": "https://cinemadocentro.com.br/", "wordpress_category_id": 3, "post_title_prefix": "Confira a programação"}'),
  ('cine-alquimia', 'ingresso_com', '{"theater_id": 1602, "city_id": 4}')
) as source (cinema_slug, type, config)
join public.cinemas as cinema on cinema.slug = source.cinema_slug;
