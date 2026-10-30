-- Preserve the operating-calendar contract after migration 047 replaces the wrapper.
-- Additive configuration repair only; no inventory data or function-body rewrite.
BEGIN;
ALTER FUNCTION public.mp_spawn_to_bulk_with_products(
  bigint[], bigint[], bigint[], integer, jsonb, bigint,
  timestamp without time zone, text, text, timestamp without time zone, text, text
) SET TimeZone TO 'America/Denver';
COMMIT;
