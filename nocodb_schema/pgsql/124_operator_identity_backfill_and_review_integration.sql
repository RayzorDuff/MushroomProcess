-- 024_operator_identity_backfill_and_review_integration.sql
--
-- Backfills personnel_review_subjects from existing operator data and
-- updates personnel review insert logic to use the shared operator helper.

SET client_min_messages TO WARNING;

BEGIN;

DO $$
DECLARE
  v_operator text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'events'
  ) THEN
    FOR v_operator IN
      SELECT DISTINCT operator
      FROM public.events
      WHERE operator IS NOT NULL AND btrim(operator) <> ''
    LOOP
      PERFORM public.mp_personnel_review_subject_ensure(v_operator, true, 'Operator', NULL);
    END LOOP;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'lots'
  ) THEN
    FOR v_operator IN
      SELECT DISTINCT operator
      FROM public.lots
      WHERE operator IS NOT NULL AND btrim(operator) <> ''
    LOOP
      PERFORM public.mp_personnel_review_subject_ensure(v_operator, true, 'Operator', NULL);
    END LOOP;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'sterilization_runs'
  ) THEN
    FOR v_operator IN
      SELECT DISTINCT operator
      FROM public.sterilization_runs
      WHERE operator IS NOT NULL AND btrim(operator) <> ''
    LOOP
      PERFORM public.mp_personnel_review_subject_ensure(v_operator, true, 'Operator', NULL);
    END LOOP;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.mp_personnel_review_entry_insert(
  p_subject_id bigint,
  p_entered_by text,
  p_entry_source text DEFAULT 'manager',
  p_note_type text DEFAULT 'neutral',
  p_category text DEFAULT 'other',
  p_visibility text DEFAULT 'shared_at_review',
  p_summary text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_observed_on date DEFAULT NULL,
  p_entry_ts timestamp without time zone DEFAULT NULL,
  p_follow_up_needed boolean DEFAULT false,
  p_follow_up_by date DEFAULT NULL,
  p_related_review_period_start date DEFAULT NULL,
  p_related_review_period_end date DEFAULT NULL,
  p_tags text[] DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_id bigint;
  v_entered_by text;
  v_entered_by_subject_id bigint;
BEGIN
  IF p_subject_id IS NULL THEN
    RAISE EXCEPTION 'subject_id is required';
  END IF;

  v_entered_by := public.mp_operator_normalize(p_entered_by);

  IF v_entered_by IS NULL OR btrim(v_entered_by) = '' OR v_entered_by = 'system' THEN
    RAISE EXCEPTION 'entered_by is required';
  END IF;

  IF p_summary IS NULL OR btrim(p_summary) = '' THEN
    RAISE EXCEPTION 'summary is required';
  END IF;

  v_entered_by_subject_id := public.mp_personnel_review_subject_ensure(
    v_entered_by,
    true,
    CASE WHEN p_entry_source = 'self' THEN 'Employee' ELSE 'Operator' END,
    NULL
  );

  INSERT INTO public.personnel_review_entries (
    subject_id,
    entered_by_subject_id,
    entry_ts,
    observed_on,
    entered_by,
    entry_source,
    note_type,
    category,
    visibility,
    summary,
    details,
    follow_up_needed,
    follow_up_by,
    related_review_period_start,
    related_review_period_end,
    tags
  )
  VALUES (
    p_subject_id,
    v_entered_by_subject_id,
    COALESCE(p_entry_ts, now()),
    COALESCE(p_observed_on, CURRENT_DATE),
    v_entered_by,
    p_entry_source,
    p_note_type,
    p_category,
    p_visibility,
    btrim(p_summary),
    p_details,
    COALESCE(p_follow_up_needed, false),
    p_follow_up_by,
    p_related_review_period_start,
    p_related_review_period_end,
    p_tags
  )
  RETURNING nocopk INTO v_id;

  RETURN v_id;
END;
$$;

COMMIT;
