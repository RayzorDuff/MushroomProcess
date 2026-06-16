-- 124_operator_identity_backfill_and_review_integration.sql
--
-- Backfills personnel_review_subjects from existing operator data and
-- updates personnel review insert logic to use the shared operator helper.

SET client_min_messages TO WARNING;

BEGIN;

-- Normalize and backfill authenticated operator identities from existing operational tables.
INSERT INTO public.personnel_review_subjects (
  full_name,
  active,
  role_title,
  notes,
  appsmith_email,
  appsmith_name,
  can_login
)
SELECT DISTINCT
  COALESCE(
    public.mp_operator_identity_name(src.operator_value),
    split_part(public.mp_operator_identity_email(src.operator_value), '@', 1)
  ) AS full_name,
  true,
  'Operator',
  'Auto-created from existing operator data during backfill.',
  public.mp_operator_identity_email(src.operator_value) AS appsmith_email,
  COALESCE(
    public.mp_operator_identity_name(src.operator_value),
    split_part(public.mp_operator_identity_email(src.operator_value), '@', 1)
  ) AS appsmith_name,
  true
FROM (
  SELECT operator AS operator_value FROM public.events WHERE operator IS NOT NULL
  UNION
  SELECT operator AS operator_value FROM public.lots WHERE operator IS NOT NULL
  UNION
  SELECT operator AS operator_value FROM public.products WHERE operator IS NOT NULL
  UNION
  SELECT operator AS operator_value FROM public.sterilization_runs WHERE operator IS NOT NULL
) src
WHERE public.mp_normalize_operator_identity(src.operator_value) IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.personnel_review_subjects s
    WHERE (
      public.mp_operator_identity_email(src.operator_value) IS NOT NULL
      AND lower(s.appsmith_email) = public.mp_operator_identity_email(src.operator_value)
    )
    OR (
      public.mp_operator_identity_email(src.operator_value) IS NULL
      AND (
        lower(COALESCE(s.appsmith_name, '')) = lower(COALESCE(public.mp_operator_identity_name(src.operator_value), ''))
        OR lower(COALESCE(s.full_name, '')) = lower(COALESCE(public.mp_operator_identity_name(src.operator_value), ''))
      )
    )
  );

-- Normalize stored operator values in-place to avoid quoted / split identities.
UPDATE public.events
SET operator = public.mp_normalize_operator_identity(operator)
WHERE operator IS DISTINCT FROM public.mp_normalize_operator_identity(operator);

UPDATE public.lots
SET operator = public.mp_normalize_operator_identity(operator)
WHERE operator IS DISTINCT FROM public.mp_normalize_operator_identity(operator);

UPDATE public.products
SET operator = public.mp_normalize_operator_identity(operator)
WHERE operator IS DISTINCT FROM public.mp_normalize_operator_identity(operator);

UPDATE public.sterilization_runs
SET operator = public.mp_normalize_operator_identity(operator)
WHERE operator IS DISTINCT FROM public.mp_normalize_operator_identity(operator);

UPDATE public.personnel_review_entries e
SET
  entered_by = public.mp_normalize_operator_identity(e.entered_by),
  entered_by_subject_id = public.mp_current_operator_subject(public.mp_normalize_operator_identity(e.entered_by))
WHERE e.entered_by IS NOT NULL;

DO $$
DECLARE
  v_subject_id bigint;
BEGIN
  FOR v_subject_id IN
    SELECT s.nocopk
    FROM public.personnel_review_subjects s
    WHERE public.mp_operator_identity_email(s.appsmith_email) IS NOT NULL
  LOOP
    PERFORM public.mp_rewrite_operator_aliases_for_subject(v_subject_id);
  END LOOP;
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

  v_entered_by := public.mp_normalize_operator_identity(p_entered_by);

  IF v_entered_by IS NULL THEN
    RAISE EXCEPTION 'entered_by is required';
  END IF;

  IF p_summary IS NULL OR btrim(p_summary) = '' THEN
    RAISE EXCEPTION 'summary is required';
  END IF;

  v_entered_by_subject_id := public.mp_current_operator_subject(v_entered_by);

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
