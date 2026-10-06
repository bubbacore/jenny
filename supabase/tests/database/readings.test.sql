begin;

select plan(7);

-- Dias da janela

-- No v1 cinema is closed on every day, so the test closes one for the length
-- of this transaction, on a date between the fixed dates of the ingestion
-- tests and the weeks they draw at random.
update public.cinemas set closed_weekdays = '{1,2,3,4,5,6,7}' where slug = 'cine-alquimia';

create temporary table recorded as
select public.record_reading(
  (
    public.start_reading(
      public.start_collection('manual', array['cine-alquimia'], true, '2026-12-07T12:00:00-03:00'),
      'cine-alquimia',
      '2026-12-07T12:00:00-03:00'
    ) ->> 'reading_id'
  )::uuid,
  'v0.1.0',
  '{"cinema": "cine-alquimia", "source": "ingresso_com", "status": "ok", "movies": [], "sessions": []}',
  '2026-12-07T12:00:00-03:00'
) as result;

select is(
  (select result ->> 'result' from recorded),
  'success',
  'um cinema com todos os dias da janela sem funcionamento lê sem sessões, sem falha'
);

select is(
  (
    select array_agg(distinct state)
    from public.site_cinema_days('2026-12-07T12:00:00-03:00')
    where cinema = 'cine-alquimia'
  ),
  array['closed'],
  'todos os dias desse cinema aparecem como dia sem funcionamento'
);

-- Post sem período

-- A post read before the post period existed was recorded without it, as an
-- earlier release of the ingestion did. The test records it straight in the
-- database, on dates between the fixed dates of the ingestion tests and the
-- weeks they draw at random. Its days follow the rules of the other sources.
create temporary table legacy_post as
select public.record_reading(
  (
    public.start_reading(
      public.start_collection('manual', array['cinema-do-centro'], true, '2026-12-14T12:00:00-03:00'),
      'cinema-do-centro',
      '2026-12-14T12:00:00-03:00'
    ) ->> 'reading_id'
  )::uuid,
  'v0.1.0',
  '{
    "cinema": "cinema-do-centro",
    "source": "official_site",
    "status": "ok",
    "post": {
      "url": "https://cinemadocentro.com.br/programacao-sem-periodo/",
      "published_at": "2026-12-09T10:00:00-03:00"
    },
    "movies": [{
      "key": "a",
      "source_title": "Filme sem período",
      "tmdb_id": 9800001,
      "tmdb_search_top_id": 9800001,
      "tmdb": {"title": "Filme 9800001", "original_title": "Movie 9800001"}
    }],
    "sessions": [
      {"movie_key": "a", "starts_at": "2026-12-17T19:00", "tags": [], "prices": []},
      {"movie_key": "a", "starts_at": "2026-12-18T19:00", "tags": [], "prices": []}
    ]
  }',
  '2026-12-14T12:00:00-03:00'
) as result;

select is(
  (
    select array_agg(state order by date)
    from public.site_cinema_days('2026-12-14T12:00:00-03:00')
    where cinema = 'cinema-do-centro'
  ),
  array['not_announced', 'not_announced', 'closed', 'with_sessions', 'with_sessions',
    'not_announced', 'not_announced'],
  'num post guardado sem período, nenhum dia é dia sem sessões'
);

create temporary table legacy_reuse as
select public.record_reading(
  (
    public.start_reading(
      public.start_collection('manual', array['cinema-do-centro'], true, '2026-12-17T12:00:00-03:00'),
      'cinema-do-centro',
      '2026-12-17T12:00:00-03:00'
    ) ->> 'reading_id'
  )::uuid,
  'v0.1.0',
  '{"cinema": "cinema-do-centro", "source": "official_site", "status": "ok", "no_new_post": true, "movies": [], "sessions": []}',
  '2026-12-17T12:00:00-03:00'
) as result;

select is(
  (select result ->> 'result' from legacy_reuse),
  'success',
  'sem post novo, a programação de um post sem período tem sucesso enquanto há sessões de hoje em diante'
);

create temporary table legacy_outdated as
select public.record_reading(
  (
    public.start_reading(
      public.start_collection('manual', array['cinema-do-centro'], true, '2026-12-19T12:00:00-03:00'),
      'cinema-do-centro',
      '2026-12-19T12:00:00-03:00'
    ) ->> 'reading_id'
  )::uuid,
  'v0.1.0',
  '{"cinema": "cinema-do-centro", "source": "official_site", "status": "ok", "no_new_post": true, "movies": [], "sessions": []}',
  '2026-12-19T12:00:00-03:00'
) as result;

select is(
  (select result ->> 'reason' from legacy_outdated),
  'A programação do último post lido não tem mais nenhuma sessão de hoje em diante, '
    || 'e o cinema funciona em algum dia da janela.',
  'e fica desatualizada pela regra das demais fontes quando não há mais nenhuma sessão de hoje em diante'
);

-- Leitura anterior sem as datas das sessões

-- A reading recorded before the session dates were kept has none. The test
-- erases them from a reading on a Monday with 4 sessions that day, on dates
-- between the fixed dates of the ingestion tests and the weeks they draw at
-- random. On Tuesday, the session drop compares with its recorded count.
create temporary table dateless as
select public.record_reading(
  (
    public.start_reading(
      public.start_collection('manual', array['cinesercla-praia-sul'], true, '2026-12-21T08:00:00-03:00'),
      'cinesercla-praia-sul',
      '2026-12-21T08:00:00-03:00'
    ) ->> 'reading_id'
  )::uuid,
  'v0.1.0',
  '{
    "cinema": "cinesercla-praia-sul",
    "source": "cinesercla_site",
    "status": "ok",
    "movies": [{
      "key": "a",
      "source_title": "Filme sem datas",
      "tmdb_id": 9800002,
      "tmdb_search_top_id": 9800002,
      "tmdb": {"title": "Filme 9800002", "original_title": "Movie 9800002"}
    }],
    "sessions": [
      {"movie_key": "a", "starts_at": "2026-12-21T14:00", "tags": [], "prices": []},
      {"movie_key": "a", "starts_at": "2026-12-21T16:00", "tags": [], "prices": []},
      {"movie_key": "a", "starts_at": "2026-12-21T18:00", "tags": [], "prices": []},
      {"movie_key": "a", "starts_at": "2026-12-21T20:00", "tags": [], "prices": []}
    ]
  }',
  '2026-12-21T08:00:00-03:00'
) as result;

update public.readings set session_dates = null
where id = (select (result ->> 'reading_id')::uuid from dateless);

create temporary table after_dateless as
select public.record_reading(
  (
    public.start_reading(
      public.start_collection('manual', array['cinesercla-praia-sul'], true, '2026-12-22T08:00:00-03:00'),
      'cinesercla-praia-sul',
      '2026-12-22T08:00:00-03:00'
    ) ->> 'reading_id'
  )::uuid,
  'v0.1.0',
  '{
    "cinema": "cinesercla-praia-sul",
    "source": "cinesercla_site",
    "status": "ok",
    "movies": [{
      "key": "a",
      "source_title": "Filme sem datas",
      "tmdb_id": 9800002,
      "tmdb_search_top_id": 9800002
    }],
    "sessions": [{"movie_key": "a", "starts_at": "2026-12-22T20:00", "tags": [], "prices": []}]
  }',
  '2026-12-22T08:00:00-03:00'
) as result;

select is(
  (
    select alert ->> 'text'
    from after_dateless, jsonb_array_elements(result -> 'alerts') as alert
    where alert ->> 'type' = 'session-drop'
  ),
  'Cinesercla Praia Sul: queda brusca de sessões, de 4 na última leitura com sucesso para 1 nesta. '
    || 'As sessões foram aceitas.',
  'depois de uma leitura sem as datas das sessões, a queda brusca compara com a contagem registrada'
);

select is(
  (
    select previous_sessions
    from public.readings
    where id = (select (result ->> 'reading_id')::uuid from after_dateless)
  ),
  4,
  'e o histórico guarda essa contagem como as sessões da leitura anterior'
);

select * from finish();

rollback;
