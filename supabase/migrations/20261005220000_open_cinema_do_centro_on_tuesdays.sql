-- The Cinema do Centro opens on Tuesdays, as the owner checked on 2026-10-05,
-- and Wednesday is its only closed day.

update public.cinemas set closed_weekdays = '{3}' where slug = 'cinema-do-centro';
