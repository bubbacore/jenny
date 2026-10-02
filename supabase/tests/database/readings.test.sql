begin;

select plan(2);

-- Dias da janela

-- No v1 cinema is closed on every day, so the test closes one for the length
-- of this transaction, on a date between the fixed dates of the ingestion
-- tests and the weeks they draw at random.
update public.cinemas set closed_weekdays = '{1,2,3,4,5,6,7}' where slug = 'cine-alquimia';

create temporary table recorded as
select public.record_reading(
  (public.start_reading('cine-alquimia', '2026-12-07T12:00:00-03:00') ->> 'reading_id')::uuid,
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

select * from finish();

rollback;
