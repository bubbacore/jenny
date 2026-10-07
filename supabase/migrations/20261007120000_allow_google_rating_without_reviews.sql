-- The Hermes reads the Google rating in the place page opened without login,
-- which hides the number of reviews. The rating may now come without it. The
-- rating and the date of the update still come or lack together, and the
-- number of reviews exists only with the rating. update_cinema already writes
-- the number that comes with the rating, so a rating without it clears the
-- stored one, and the site never shows the number of one reading with the
-- rating of another.

alter table public.cinemas
  drop constraint cinemas_google_rating_is_complete,
  add constraint cinemas_google_rating_is_complete check (
    (google_rating is null) = (google_rating_updated_at is null)
    and (google_reviews_count is null or google_rating is not null)
  );

comment on column public.cinemas.google_reviews_count is
  'The number of Google reviews read with the rating, or null when the place page hid it.';
