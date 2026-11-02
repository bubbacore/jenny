-- The cinema's Instagram is a source of posts, like the official site. The
-- new value comes alone in its migration, because the transaction that adds
-- an enum value cannot use it.
alter type public.source_type add value 'instagram';
