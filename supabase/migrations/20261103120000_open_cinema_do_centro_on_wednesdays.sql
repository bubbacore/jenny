-- The Cinema do Centro has no closed day anymore, as the owner decided on
-- 2026-11-03, after its post for 02/11 to 04/11 brought Wednesday sessions.

update public.cinemas set closed_weekdays = '{}' where slug = 'cinema-do-centro';
