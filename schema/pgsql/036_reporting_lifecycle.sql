-- 036_reporting_lifecycle.sql
-- Issue #87 Phase 2: canonical read-only lot lifecycle reporting layer.

SET search_path = public, pg_catalog;

BEGIN;

/*
 * Historical Airtable-migrated rows and PostgreSQL-native rows do not populate
 * every lifecycle fact in the same place.  This view intentionally combines
 * direct lot columns with dated Events according to the precedence documented
 * in doc/Reporting-Data-Contract.md.
 *
 * These helpers are defensive readers only.  They never mutate source data.
 */
CREATE OR REPLACE FUNCTION public.mp_reporting_try_jsonb(p_text text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN NULL;
  END IF;

  RETURN p_text::jsonb;
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_reporting_try_numeric(p_text text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN NULL;
  END IF;

  RETURN p_text::numeric;
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE VIEW public.v_reporting_lot_lifecycle AS
WITH event_normalized AS (
  SELECT
    e.nocopk,
    e.event_id,
    e.lot_id,
    e.type,
    e."timestamp",
    e.operator,
    e.station,
    public.mp_reporting_try_jsonb(e.fields_json) AS fields
  FROM public.events e
  WHERE e.lot_id IS NOT NULL
),
event_rollup AS (
  SELECT
    e.lot_id,
    count(*)::bigint AS event_count,
    count(*) FILTER (WHERE e."timestamp" IS NOT NULL)::bigint AS dated_event_count,
    count(*) FILTER (WHERE e."timestamp" IS NULL)::bigint AS undated_event_count,
    min(e."timestamp") AS first_event_at,
    max(e."timestamp") AS last_event_at,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) = 'received') AS received_event_at,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) IN ('sterilized', 'pasteurized')) AS processed_event_at,
    (array_agg(e.type ORDER BY e."timestamp", e.nocopk) FILTER (
      WHERE e."timestamp" IS NOT NULL
        AND lower(COALESCE(e.type, '')) IN ('sterilized', 'pasteurized')
    ))[1] AS processed_event_type,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) = 'inoculated') AS inoculated_event_at,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) = 'fullycolonized') AS fully_colonized_event_at,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) = 'spawnedtobulk') AS spawned_event_at,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) IN ('fruitingstart', 'startfruiting')) AS fruiting_start_event_at,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) = 'harvest') AS first_harvest_event_at,
    max(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) = 'harvest') AS last_harvest_event_at,
    min(e."timestamp") FILTER (WHERE lower(COALESCE(e.type, '')) = 'contaminated') AS contaminated_event_at,
    max(e."timestamp") FILTER (
      WHERE lower(COALESCE(e.type, '')) IN (
        'contaminated', 'inviable', 'composted', 'consumed', 'destroyed', 'expired', 'retired'
      )
    ) AS terminal_event_at
  FROM event_normalized e
  GROUP BY e.lot_id
),
first_event AS (
  SELECT DISTINCT ON (e.lot_id)
    e.lot_id,
    e.type AS first_event_type
  FROM event_normalized e
  WHERE e."timestamp" IS NOT NULL
  ORDER BY e.lot_id, e."timestamp", e.nocopk
),
latest_dated_terminal_event AS (
  SELECT DISTINCT ON (e.lot_id)
    e.lot_id,
    e.type AS terminal_event_type,
    e."timestamp" AS terminal_event_at,
    COALESCE(
      NULLIF(e.fields ->> 'reason', ''),
      NULLIF(e.fields ->> 'terminal_status', ''),
      NULLIF(e.fields ->> 'note', '')
    ) AS terminal_event_detail
  FROM event_normalized e
  WHERE e."timestamp" IS NOT NULL
    AND lower(COALESCE(e.type, '')) IN (
      'contaminated', 'inviable', 'composted', 'consumed', 'destroyed', 'expired', 'retired'
    )
  ORDER BY e.lot_id, e."timestamp" DESC, e.nocopk DESC
),
latest_terminal_event_any AS (
  SELECT DISTINCT ON (e.lot_id)
    e.lot_id,
    e.type AS terminal_event_type_any,
    e."timestamp" AS terminal_event_at_any,
    COALESCE(
      NULLIF(e.fields ->> 'reason', ''),
      NULLIF(e.fields ->> 'terminal_status', ''),
      NULLIF(e.fields ->> 'note', '')
    ) AS terminal_event_detail_any
  FROM event_normalized e
  WHERE lower(COALESCE(e.type, '')) IN (
    'contaminated', 'inviable', 'composted', 'consumed', 'destroyed', 'expired', 'retired'
  )
  ORDER BY
    e.lot_id,
    (e."timestamp" IS NOT NULL) DESC,
    e."timestamp" DESC NULLS LAST,
    e.nocopk DESC
),
harvest_event_rows AS (
  SELECT
    e.nocopk AS event_nocopk,
    e.lot_id,
    e."timestamp",
    public.mp_reporting_try_numeric(e.fields ->> 'flush_no') AS flush_no,
    public.mp_reporting_try_numeric(e.fields ->> 'harvest_weight_g') AS harvest_weight_g
  FROM event_normalized e
  WHERE lower(COALESCE(e.type, '')) = 'harvest'
),
harvest_rollup AS (
  SELECT
    h.lot_id,
    count(*)::bigint AS harvest_event_count,
    count(*) FILTER (WHERE h."timestamp" IS NULL)::bigint AS undated_harvest_event_count,
    count(*) FILTER (WHERE h.harvest_weight_g IS NULL)::bigint AS harvest_event_missing_weight_count,
    count(*) FILTER (WHERE h.flush_no IS NULL)::bigint AS harvest_event_missing_flush_count,
    count(DISTINCT h.flush_no) FILTER (
      WHERE h.flush_no IS NOT NULL
        AND h.flush_no > 0
        AND h.flush_no = trunc(h.flush_no)
    )::bigint AS flush_count,
    max(h.flush_no) FILTER (
      WHERE h.flush_no IS NOT NULL
        AND h.flush_no > 0
        AND h.flush_no = trunc(h.flush_no)
    ) AS max_flush_no,
    sum(h.harvest_weight_g) FILTER (
      WHERE h.flush_no = 1
    ) AS first_flush_g,
    sum(h.harvest_weight_g) AS total_harvest_g,
    EXISTS (
      SELECT 1
      FROM harvest_event_rows hd
      WHERE hd.lot_id = h.lot_id
        AND hd.flush_no IS NOT NULL
      GROUP BY hd.flush_no
      HAVING count(*) > 1
    ) AS has_duplicate_flush_events
  FROM harvest_event_rows h
  GROUP BY h.lot_id
),
harvest_quality AS (
  SELECT
    hr.*,
    CASE
      WHEN COALESCE(hr.flush_count, 0) = 0 THEN false
      WHEN COALESCE(hr.max_flush_no, 0) <> hr.flush_count::numeric THEN true
      ELSE false
    END AS has_noncontiguous_flush_numbers
  FROM harvest_rollup hr
),
grain_inputs AS (
  SELECT
    j.lots_id,
    count(*)::bigint AS grain_input_count,
    array_agg(gl.nocopk ORDER BY gl.nocopk) AS grain_input_nocopks,
    array_agg(gl.lot_id ORDER BY gl.nocopk) AS grain_input_lot_ids,
    array_agg(gl.item_name_mat ORDER BY gl.nocopk) AS grain_input_item_names,
    array_agg(COALESCE(gl.inoculated_at, ger.inoculated_event_at) ORDER BY gl.nocopk) AS grain_input_inoculated_ats
  FROM public._m2m_lots_lots_grain_inputs j
  JOIN public.lots gl ON gl.nocopk = j.lots1_id
  LEFT JOIN event_rollup ger ON ger.lot_id = gl.nocopk
  GROUP BY j.lots_id
),
substrate_inputs AS (
  SELECT
    j.lots_id,
    count(*)::bigint AS substrate_input_count,
    array_agg(sl.nocopk ORDER BY sl.nocopk) AS substrate_input_nocopks,
    array_agg(sl.lot_id ORDER BY sl.nocopk) AS substrate_input_lot_ids,
    array_agg(sl.item_name_mat ORDER BY sl.nocopk) AS substrate_input_item_names,
    array_agg(COALESCE(sl.sterilized_at, ser.processed_event_at) ORDER BY sl.nocopk) AS substrate_input_processed_ats
  FROM public._m2m_lots_lots_substrate_inputs j
  JOIN public.lots sl ON sl.nocopk = j.lots1_id
  LEFT JOIN event_rollup ser ON ser.lot_id = sl.nocopk
  GROUP BY j.lots_id
),
base AS (
  SELECT
    l.nocopk AS lot_nocopk,
    l.lot_id,
    l.airtable_id,
    l.item_id AS item_nocopk,
    COALESCE(i.item_id, NULL) AS item_id,
    COALESCE(NULLIF(l.item_name_mat, ''), i.name) AS item_name,
    COALESCE(NULLIF(l.item_category_mat, ''), i.category) AS item_category,
    l.recipe_id AS recipe_nocopk,
    r.recipe_id,
    r.name AS recipe_name,
    l.strain_id AS strain_nocopk,
    s.strain_id,
    COALESCE(NULLIF(l.strain_species_strain_mat, ''), s.species_strain) AS species_strain,
    s.regulated AS strain_regulated,
    l.location_id AS location_nocopk,
    loc.name AS location_name,
    l.source_lot_id AS source_lot_nocopk,
    source_lot.lot_id AS source_lot_id,
    l.parent_lot_id AS parent_lot_nocopk,
    parent_lot.lot_id AS parent_lot_id,
    l.status,
    l.process_type_mat,
    l.qty,
    l.unit_size,
    l.use_by,
    l.created_at AS record_created_at,
    l.received_date::timestamp without time zone AS received_direct_at,
    er.received_event_at,
    l.sterilized_at AS processed_direct_at,
    er.processed_event_at,
    er.processed_event_type,
    l.inoculated_at AS inoculated_direct_at,
    er.inoculated_event_at,
    er.fully_colonized_event_at,
    l.spawned_at AS spawned_direct_at,
    er.spawned_event_at,
    l.beganfruiting_at AS fruiting_start_direct_at,
    er.fruiting_start_event_at,
    l.firstharvested_at AS first_harvest_direct_at,
    er.first_harvest_event_at,
    l.lastharvested_at AS last_harvest_direct_at,
    er.last_harvest_event_at,
    er.contaminated_event_at,
    l.retired_at AS terminal_direct_at,
    er.terminal_event_at,
    er.first_event_at,
    er.last_event_at,
    fe.first_event_type,
    ldte.terminal_event_type,
    ldte.terminal_event_detail,
    ltea.terminal_event_type_any,
    ltea.terminal_event_at_any,
    ltea.terminal_event_detail_any,
    COALESCE(er.event_count, 0) AS event_count,
    COALESCE(er.dated_event_count, 0) AS dated_event_count,
    COALESCE(er.undated_event_count, 0) AS undated_event_count,
    COALESCE(hq.harvest_event_count, 0) AS harvest_event_count,
    COALESCE(hq.undated_harvest_event_count, 0) AS undated_harvest_event_count,
    COALESCE(hq.harvest_event_missing_weight_count, 0) AS harvest_event_missing_weight_count,
    COALESCE(hq.harvest_event_missing_flush_count, 0) AS harvest_event_missing_flush_count,
    COALESCE(hq.flush_count, 0) AS flush_count,
    hq.max_flush_no,
    hq.first_flush_g,
    hq.total_harvest_g,
    COALESCE(hq.has_duplicate_flush_events, false) AS has_duplicate_flush_events,
    COALESCE(hq.has_noncontiguous_flush_numbers, false) AS has_noncontiguous_flush_numbers,
    COALESCE(gi.grain_input_count, 0) AS grain_input_count,
    COALESCE(gi.grain_input_nocopks, ARRAY[]::bigint[]) AS grain_input_nocopks,
    COALESCE(gi.grain_input_lot_ids, ARRAY[]::text[]) AS grain_input_lot_ids,
    COALESCE(gi.grain_input_item_names, ARRAY[]::text[]) AS grain_input_item_names,
    COALESCE(gi.grain_input_inoculated_ats, ARRAY[]::timestamp without time zone[]) AS grain_input_inoculated_ats,
    COALESCE(si.substrate_input_count, 0) AS substrate_input_count,
    COALESCE(si.substrate_input_nocopks, ARRAY[]::bigint[]) AS substrate_input_nocopks,
    COALESCE(si.substrate_input_lot_ids, ARRAY[]::text[]) AS substrate_input_lot_ids,
    COALESCE(si.substrate_input_item_names, ARRAY[]::text[]) AS substrate_input_item_names,
    COALESCE(si.substrate_input_processed_ats, ARRAY[]::timestamp without time zone[]) AS substrate_input_processed_ats
  FROM public.lots l
  LEFT JOIN public.items i ON i.nocopk = l.item_id
  LEFT JOIN public.recipes r ON r.nocopk = l.recipe_id
  LEFT JOIN public.strains s ON s.nocopk = l.strain_id
  LEFT JOIN public.locations loc ON loc.nocopk = l.location_id
  LEFT JOIN public.lots source_lot ON source_lot.nocopk = l.source_lot_id
  LEFT JOIN public.lots parent_lot ON parent_lot.nocopk = l.parent_lot_id
  LEFT JOIN event_rollup er ON er.lot_id = l.nocopk
  LEFT JOIN first_event fe ON fe.lot_id = l.nocopk
  LEFT JOIN latest_dated_terminal_event ldte ON ldte.lot_id = l.nocopk
  LEFT JOIN latest_terminal_event_any ltea ON ltea.lot_id = l.nocopk
  LEFT JOIN harvest_quality hq ON hq.lot_id = l.nocopk
  LEFT JOIN grain_inputs gi ON gi.lots_id = l.nocopk
  LEFT JOIN substrate_inputs si ON si.lots_id = l.nocopk
),
normalized AS (
  SELECT
    b.*,
    COALESCE(b.received_direct_at, b.received_event_at) AS received_at,
    CASE
      WHEN b.received_direct_at IS NOT NULL THEN 'lots.received_date'
      WHEN b.received_event_at IS NOT NULL THEN 'event:Received'
      ELSE NULL
    END AS received_at_source,
    COALESCE(b.processed_direct_at, b.processed_event_at) AS processed_at,
    CASE
      WHEN b.processed_direct_at IS NOT NULL THEN 'lots.sterilized_at'
      WHEN b.processed_event_at IS NOT NULL THEN 'event:Sterilized/Pasteurized'
      ELSE NULL
    END AS processed_at_source,
    CASE
      WHEN lower(COALESCE(b.process_type_mat, '')) = 'pasteurize' THEN 'Pasteurized'
      WHEN lower(COALESCE(b.process_type_mat, '')) = 'sterilize' THEN 'Sterilized'
      WHEN lower(COALESCE(b.processed_event_type, '')) = 'pasteurized' THEN 'Pasteurized'
      WHEN lower(COALESCE(b.processed_event_type, '')) = 'sterilized' THEN 'Sterilized'
      ELSE NULL
    END AS processed_type,
    CASE
      WHEN NULLIF(b.process_type_mat, '') IS NOT NULL THEN 'lots.process_type_mat'
      WHEN b.processed_event_type IS NOT NULL THEN 'event:' || b.processed_event_type
      ELSE NULL
    END AS processed_type_source,
    COALESCE(b.inoculated_direct_at, b.inoculated_event_at) AS inoculated_at,
    CASE
      WHEN b.inoculated_direct_at IS NOT NULL THEN 'lots.inoculated_at'
      WHEN b.inoculated_event_at IS NOT NULL THEN 'event:Inoculated'
      ELSE NULL
    END AS inoculated_at_source,
    b.fully_colonized_event_at AS fully_colonized_at,
    CASE WHEN b.fully_colonized_event_at IS NOT NULL THEN 'event:FullyColonized' ELSE NULL END AS fully_colonized_at_source,
    COALESCE(b.spawned_direct_at, b.spawned_event_at) AS spawned_at,
    CASE
      WHEN b.spawned_direct_at IS NOT NULL THEN 'lots.spawned_at'
      WHEN b.spawned_event_at IS NOT NULL THEN 'event:SpawnedToBulk'
      ELSE NULL
    END AS spawned_at_source,
    COALESCE(b.fruiting_start_direct_at, b.fruiting_start_event_at) AS fruiting_start_at,
    CASE
      WHEN b.fruiting_start_direct_at IS NOT NULL THEN 'lots.beganfruiting_at'
      WHEN b.fruiting_start_event_at IS NOT NULL THEN 'event:FruitingStart'
      ELSE NULL
    END AS fruiting_start_at_source,
    COALESCE(b.first_harvest_direct_at, b.first_harvest_event_at) AS first_harvest_at,
    CASE
      WHEN b.first_harvest_direct_at IS NOT NULL THEN 'lots.firstharvested_at'
      WHEN b.first_harvest_event_at IS NOT NULL THEN 'event:Harvest'
      ELSE NULL
    END AS first_harvest_at_source,
    COALESCE(b.last_harvest_direct_at, b.last_harvest_event_at) AS last_harvest_at,
    CASE
      WHEN b.last_harvest_direct_at IS NOT NULL THEN 'lots.lastharvested_at'
      WHEN b.last_harvest_event_at IS NOT NULL THEN 'event:Harvest'
      ELSE NULL
    END AS last_harvest_at_source,
    b.contaminated_event_at AS contaminated_at,
    CASE WHEN b.contaminated_event_at IS NOT NULL THEN 'event:Contaminated' ELSE NULL END AS contaminated_at_source,
    COALESCE(b.terminal_direct_at, b.terminal_event_at) AS terminal_at,
    CASE
      WHEN b.terminal_direct_at IS NOT NULL THEN 'lots.retired_at'
      WHEN b.terminal_event_at IS NOT NULL THEN 'event:terminal'
      ELSE NULL
    END AS terminal_at_source,
    CASE
      WHEN b.terminal_event_type_any IS NOT NULL THEN b.terminal_event_type_any
      WHEN lower(COALESCE(b.status, '')) IN ('retired', 'consumed', 'contaminated', 'composted', 'inviable', 'destroyed', 'expired') THEN b.status
      ELSE NULL
    END AS terminal_reason,
    CASE
      WHEN b.terminal_event_type_any IS NOT NULL THEN 'event:' || b.terminal_event_type_any
      WHEN lower(COALESCE(b.status, '')) IN ('retired', 'consumed', 'contaminated', 'composted', 'inviable', 'destroyed', 'expired') THEN 'lots.status'
      ELSE NULL
    END AS terminal_reason_source,
    CASE
      WHEN b.airtable_id IS NOT NULL THEN 'airtable_migrated'
      ELSE 'postgres_native'
    END AS data_origin
  FROM base b
),
with_start AS (
  SELECT
    n.*,
    start_choice.lifecycle_start_at,
    start_choice.lifecycle_start_source,
    COALESCE(start_choice.lifecycle_start_source = 'lots.created_at:fallback', false) AS lifecycle_start_is_record_created_fallback
  FROM normalized n
  LEFT JOIN LATERAL (
    SELECT candidate_at AS lifecycle_start_at, candidate_source AS lifecycle_start_source
    FROM (VALUES
      (n.received_at, 'received_at', 10),
      (n.processed_at, 'processed_at', 20),
      (n.inoculated_at, 'inoculated_at', 30),
      (n.fully_colonized_at, 'fully_colonized_at', 40),
      (n.spawned_at, 'spawned_at', 50),
      (n.fruiting_start_at, 'fruiting_start_at', 60),
      (n.first_harvest_at, 'first_harvest_at', 70),
      (n.contaminated_at, 'contaminated_at', 80),
      (n.terminal_at, 'terminal_at', 90),
      (n.first_event_at, 'event:' || COALESCE(n.first_event_type, 'unknown'), 100),
      (n.record_created_at, 'lots.created_at:fallback', 110)
    ) AS candidates(candidate_at, candidate_source, candidate_priority)
    WHERE candidate_at IS NOT NULL
    ORDER BY candidate_at, candidate_priority
    LIMIT 1
  ) start_choice ON true
),
with_durations AS (
  SELECT
    s.*,
    CASE
      WHEN s.processed_at IS NOT NULL AND s.inoculated_at IS NOT NULL
        THEN round((extract(epoch FROM (s.inoculated_at - s.processed_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS days_processed_to_inoculation,
    CASE
      WHEN s.inoculated_at IS NOT NULL AND s.fully_colonized_at IS NOT NULL
        THEN round((extract(epoch FROM (s.fully_colonized_at - s.inoculated_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS days_inoculation_to_fully_colonized,
    CASE
      WHEN s.spawned_at IS NOT NULL AND s.fruiting_start_at IS NOT NULL
        THEN round((extract(epoch FROM (s.fruiting_start_at - s.spawned_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS days_spawn_to_fruiting,
    CASE
      WHEN s.fruiting_start_at IS NOT NULL AND COALESCE(s.terminal_at, s.last_harvest_at) IS NOT NULL
        THEN round((extract(epoch FROM (COALESCE(s.terminal_at, s.last_harvest_at) - s.fruiting_start_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS days_in_fruiting,
    CASE
      WHEN s.inoculated_at IS NOT NULL AND s.contaminated_at IS NOT NULL
        THEN round((extract(epoch FROM (s.contaminated_at - s.inoculated_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS days_inoculation_to_contamination,
    CASE
      WHEN s.processed_direct_at IS NOT NULL AND s.processed_event_at IS NOT NULL
        THEN abs(extract(epoch FROM (s.processed_direct_at - s.processed_event_at))) > 60
      ELSE false
    END AS processed_at_direct_event_mismatch,
    CASE
      WHEN s.inoculated_direct_at IS NOT NULL AND s.inoculated_event_at IS NOT NULL
        THEN abs(extract(epoch FROM (s.inoculated_direct_at - s.inoculated_event_at))) > 86400
      ELSE false
    END AS inoculated_at_direct_event_mismatch,
    CASE
      WHEN s.spawned_direct_at IS NOT NULL AND s.spawned_event_at IS NOT NULL
        THEN abs(extract(epoch FROM (s.spawned_direct_at - s.spawned_event_at))) > 60
      ELSE false
    END AS spawned_at_direct_event_mismatch,
    CASE
      WHEN s.fruiting_start_direct_at IS NOT NULL AND s.fruiting_start_event_at IS NOT NULL
        THEN abs(extract(epoch FROM (s.fruiting_start_direct_at - s.fruiting_start_event_at))) > 60
      ELSE false
    END AS fruiting_start_at_direct_event_mismatch,
    CASE
      WHEN s.first_harvest_direct_at IS NOT NULL AND s.first_harvest_event_at IS NOT NULL
        THEN abs(extract(epoch FROM (s.first_harvest_direct_at - s.first_harvest_event_at))) > 60
      ELSE false
    END AS first_harvest_at_direct_event_mismatch,
    CASE
      WHEN s.last_harvest_direct_at IS NOT NULL AND s.last_harvest_event_at IS NOT NULL
        THEN abs(extract(epoch FROM (s.last_harvest_direct_at - s.last_harvest_event_at))) > 60
      ELSE false
    END AS last_harvest_at_direct_event_mismatch,
    CASE
      WHEN s.terminal_direct_at IS NOT NULL AND s.terminal_event_at IS NOT NULL
        THEN abs(extract(epoch FROM (s.terminal_direct_at - s.terminal_event_at))) > 60
      ELSE false
    END AS terminal_at_direct_event_mismatch
  FROM with_start s
)
SELECT
  d.*,
  ARRAY_REMOVE(ARRAY[
    CASE WHEN d.event_count = 0 THEN 'no_events' END,
    CASE WHEN d.event_count > 0 AND d.dated_event_count = 0 THEN 'no_dated_events' END,
    CASE WHEN d.undated_event_count > 0 THEN 'has_undated_events' END,
    CASE WHEN d.lifecycle_start_is_record_created_fallback THEN 'lifecycle_start_record_created_fallback' END,
    CASE WHEN d.processed_at_direct_event_mismatch THEN 'processed_direct_event_mismatch' END,
    CASE WHEN d.inoculated_at_direct_event_mismatch THEN 'inoculated_direct_event_mismatch' END,
    CASE WHEN d.spawned_at_direct_event_mismatch THEN 'spawned_direct_event_mismatch' END,
    CASE WHEN d.fruiting_start_at_direct_event_mismatch THEN 'fruiting_start_direct_event_mismatch' END,
    CASE WHEN d.first_harvest_at_direct_event_mismatch THEN 'first_harvest_direct_event_mismatch' END,
    CASE WHEN d.last_harvest_at_direct_event_mismatch THEN 'last_harvest_direct_event_mismatch' END,
    CASE WHEN d.terminal_at_direct_event_mismatch THEN 'terminal_direct_event_mismatch' END,
    CASE WHEN d.has_duplicate_flush_events THEN 'duplicate_harvest_flush_events' END,
    CASE WHEN d.has_noncontiguous_flush_numbers THEN 'noncontiguous_flush_numbers' END,
    CASE WHEN d.harvest_event_missing_weight_count > 0 THEN 'harvest_event_missing_weight' END,
    CASE WHEN d.harvest_event_missing_flush_count > 0 THEN 'harvest_event_missing_flush_number' END,
    CASE WHEN d.days_processed_to_inoculation < 0 THEN 'negative_processed_to_inoculation_duration' END,
    CASE WHEN d.days_inoculation_to_fully_colonized < 0 THEN 'negative_inoculation_to_colonization_duration' END,
    CASE WHEN d.days_spawn_to_fruiting < 0 THEN 'negative_spawn_to_fruiting_duration' END,
    CASE WHEN d.days_in_fruiting < 0 THEN 'negative_fruiting_duration' END,
    CASE WHEN d.days_inoculation_to_contamination < 0 THEN 'negative_inoculation_to_contamination_duration' END
  ], NULL)::text[] AS quality_flags
FROM with_durations d;

COMMENT ON FUNCTION public.mp_reporting_try_jsonb(text) IS
  'Read-only defensive parser used by Reporting views; returns NULL rather than failing on blank or invalid legacy JSON.';
COMMENT ON FUNCTION public.mp_reporting_try_numeric(text) IS
  'Read-only defensive numeric parser used by Reporting views; returns NULL for blank or invalid legacy numeric values.';
COMMENT ON VIEW public.v_reporting_lot_lifecycle IS
  'Issue #87 canonical one-row-per-lot lifecycle reporting layer combining direct lot fields with dated Events and explicit provenance/quality flags for migrated and PostgreSQL-native records.';

COMMIT;
