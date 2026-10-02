-- Addresses, Instagram profiles and official sites of the v1 cinemas, given
-- by the owner on 2026-10-02.

update public.cinemas as cinema
set address = details.address,
  instagram_handle = details.instagram_handle,
  website_url = details.website_url
from (values
  ('cinemark-shopping-jardins',
    'Av. Ministro Geraldo Barreto Sobral, 215 - Loja 106 - Jardins, Aracaju - SE, 49026-010',
    'cinemarkoficial', 'https://www.cinemark.com.br'),
  ('cinemark-riomar',
    'Av. Delmiro Gouveia, 400 - Loja 268/269 - Coroa do Meio, Aracaju - SE, 49035-500',
    'cinemarkoficial', 'https://www.cinemark.com.br'),
  ('centerplex-parque-shopping',
    'Av. João Rodrigues, 42 - Industrial, Aracaju - SE, 49010-010',
    'centerplexcinemas', 'https://centerplex.com.br'),
  ('cinesercla-praia-sul',
    'Av. Melício Machado - Aruana, Aracaju - SE, 49038-445',
    'cinesercla_oficial', 'https://cinesercla.com.br'),
  ('cinesercla-premio',
    'Av. Pref. Humberto dos Santos, s/n - Loja 122 - Marcos Freire I, Nossa Sra. do Socorro - SE, 49160-000',
    'cinesercla_oficial', 'https://cinesercla.com.br'),
  ('cinema-do-centro',
    'Praça Gen. Valadão, 134 - Centro, Aracaju - SE, 49010-520',
    'cinemadocentro', 'https://cinemadocentro.com.br'),
  ('cine-alquimia',
    'R. Dep. Euclídes Paes Mendonça, n° 560 - Salgado Filho, Aracaju - SE, 49020-460',
    'cinealquimiaaju', null)
) as details (slug, address, instagram_handle, website_url)
where cinema.slug = details.slug;
