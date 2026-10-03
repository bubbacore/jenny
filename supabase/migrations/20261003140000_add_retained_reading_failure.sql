-- A reading whose sessions were all retained by pending identification is a
-- failed reading of its own type, derived by the database. The value is added
-- apart, because a new enum value can be used only after its transaction.

alter type public.reading_failure_type add value 'retained';
