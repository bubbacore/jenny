-- A finished reading either succeeds or fails. The value lives in its own
-- migration because a new enum value can only be used after it commits.

alter type public.reading_status add value 'failure';
