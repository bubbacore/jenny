-- Keep the previous main popular name available to the search.
update public.cinemas
set name = 'Cinemark Jardins',
    other_popular_names = array(
      select popular_name
      from unnest(other_popular_names) with ordinality as names(popular_name, position)
      where lower(btrim(popular_name)) not in ('cinemark jardins', 'cinemark shopping jardins')
      order by position
    ) || array['Cinemark Shopping Jardins']
where slug = 'cinemark-shopping-jardins';
