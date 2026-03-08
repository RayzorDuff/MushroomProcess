-- 021_personnel_reviews.sql
-- Minimal personnel review / 10-minute manager log schema
-- Purpose:
--   - capture ad hoc performance notes with low friction
--   - support manager notes now
--   - support self-review / upward feedback later
--   - enable future review-cycle reporting without redesign

CREATE EXTENSION IF NOT EXISTS pgcrypto;

BEGIN;

CREATE TABLE IF NOT EXISTS public.personnel_review_subjects (
  nocopk BIGSERIAL PRIMARY KEY,
  subject_code text,
  full_name text NOT NULL,
  active boolean DEFAULT true,
  role_title text,
  supervisor_name text,
  hire_date date,
  notes text,
  nocouuid uuid DEFAULT gen_random_uuid(),
  airtable_id text UNIQUE,
  nc_created_at timestamp without time zone DEFAULT now(),
  nc_updated_at timestamp without time zone DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conname = 'uq_personnel_review_subjects_subject_code'
      AND c.conrelid = 'public.personnel_review_subjects'::regclass
  ) THEN
    ALTER TABLE public.personnel_review_subjects
      ADD CONSTRAINT uq_personnel_review_subjects_subject_code UNIQUE (subject_code);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.personnel_review_entries (
  nocopk BIGSERIAL PRIMARY KEY,
  entry_code text,
  subject_id bigint NOT NULL,
  entry_ts timestamp without time zone NOT NULL DEFAULT now(),
  observed_on date,
  entered_by text NOT NULL,
  entry_source text NOT NULL DEFAULT 'manager',
  note_type text NOT NULL DEFAULT 'neutral',
  category text NOT NULL DEFAULT 'other',
  visibility text NOT NULL DEFAULT 'shared_at_review',
  summary text NOT NULL,
  details text,
  follow_up_needed boolean DEFAULT false,
  follow_up_by date,
  acknowledged boolean DEFAULT false,
  acknowledged_at timestamp without time zone,
  related_review_period_start date,
  related_review_period_end date,
  tags text[],
  nocouuid uuid DEFAULT gen_random_uuid(),
  airtable_id text UNIQUE,
  nc_created_at timestamp without time zone DEFAULT now(),
  nc_updated_at timestamp without time zone DEFAULT now(),

  CONSTRAINT fk_personnel_review_entries_subject
    FOREIGN KEY (subject_id) REFERENCES public.personnel_review_subjects(nocopk)
    ON DELETE RESTRICT,

  CONSTRAINT chk_personnel_review_entries_source
    CHECK (entry_source IN ('manager', 'self', 'peer', 'upward', 'system')),

  CONSTRAINT chk_personnel_review_entries_note_type
    CHECK (note_type IN ('positive', 'coaching', 'neutral', 'concern', 'accomplishment', 'goal', 'review_prep', 'upward_feedback')),

  CONSTRAINT chk_personnel_review_entries_category
    CHECK (category IN ('quality', 'productivity', 'reliability', 'communication', 'teamwork', 'initiative', 'leadership', 'attendance', 'training', 'safety', 'judgment', 'professionalism', 'other')),

  CONSTRAINT chk_personnel_review_entries_visibility
    CHECK (visibility IN ('manager_only', 'shared_at_review', 'shared_immediately')),

  CONSTRAINT chk_personnel_review_entries_summary_not_blank
    CHECK (btrim(summary) <> '')
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conname = 'uq_personnel_review_entries_entry_code'
      AND c.conrelid = 'public.personnel_review_entries'::regclass
  ) THEN
    ALTER TABLE public.personnel_review_entries
      ADD CONSTRAINT uq_personnel_review_entries_entry_code UNIQUE (entry_code);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_personnel_review_entries_subject_id
  ON public.personnel_review_entries(subject_id);

CREATE INDEX IF NOT EXISTS idx_personnel_review_entries_entry_ts
  ON public.personnel_review_entries(entry_ts DESC);

CREATE INDEX IF NOT EXISTS idx_personnel_review_entries_note_type
  ON public.personnel_review_entries(note_type);

CREATE INDEX IF NOT EXISTS idx_personnel_review_entries_category
  ON public.personnel_review_entries(category);

CREATE INDEX IF NOT EXISTS idx_personnel_review_entries_follow_up
  ON public.personnel_review_entries(follow_up_needed, follow_up_by);

-- Simple updated_at trigger helper
CREATE OR REPLACE FUNCTION public.mp_touch_nc_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.nc_updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_personnel_review_subjects_touch_updated_at
  ON public.personnel_review_subjects;
CREATE TRIGGER trg_personnel_review_subjects_touch_updated_at
BEFORE UPDATE ON public.personnel_review_subjects
FOR EACH ROW
EXECUTE FUNCTION public.mp_touch_nc_updated_at();

DROP TRIGGER IF EXISTS trg_personnel_review_entries_touch_updated_at
  ON public.personnel_review_entries;
CREATE TRIGGER trg_personnel_review_entries_touch_updated_at
BEFORE UPDATE ON public.personnel_review_entries
FOR EACH ROW
EXECUTE FUNCTION public.mp_touch_nc_updated_at();

-- Entry code generator
CREATE OR REPLACE FUNCTION public.mp_personnel_review_entry_code()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_code text;
BEGIN
  v_code := 'PRE-' || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || substr(md5(random()::text), 1, 6);
  RETURN v_code;
END;
$$;

-- Canonical insert function for Appsmith
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
BEGIN
  IF p_subject_id IS NULL THEN
    RAISE EXCEPTION 'subject_id is required';
  END IF;

  IF p_entered_by IS NULL OR btrim(p_entered_by) = '' THEN
    RAISE EXCEPTION 'entered_by is required';
  END IF;

  IF p_summary IS NULL OR btrim(p_summary) = '' THEN
    RAISE EXCEPTION 'summary is required';
  END IF;

  INSERT INTO public.personnel_review_entries (
    entry_code,
    subject_id,
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
    public.mp_personnel_review_entry_code(),
    p_subject_id,
    COALESCE(p_entry_ts, now()),
    COALESCE(p_observed_on, CURRENT_DATE),
    btrim(p_entered_by),
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

CREATE OR REPLACE VIEW public.vc_personnel_review_entries AS
SELECT
  e.nocopk,
  e.entry_code,
  e.subject_id,
  s.subject_code,
  s.full_name,
  s.role_title,
  s.supervisor_name,
  s.active AS subject_active,
  e.entry_ts,
  e.observed_on,
  e.entered_by,
  e.entry_source,
  e.note_type,
  e.category,
  e.visibility,
  e.summary,
  e.details,
  e.follow_up_needed,
  e.follow_up_by,
  e.acknowledged,
  e.acknowledged_at,
  e.related_review_period_start,
  e.related_review_period_end,
  e.tags,
  e.nc_created_at,
  e.nc_updated_at
FROM public.personnel_review_entries e
JOIN public.personnel_review_subjects s
  ON s.nocopk = e.subject_id;

CREATE OR REPLACE VIEW public.vc_personnel_review_subjects AS
SELECT
  s.nocopk,
  s.subject_code,
  s.full_name,
  s.active,
  s.role_title,
  s.supervisor_name,
  s.hire_date,
  s.notes,
  (
    SELECT max(e.entry_ts)
    FROM public.personnel_review_entries e
    WHERE e.subject_id = s.nocopk
  ) AS last_entry_ts,
  (
    SELECT count(*)
    FROM public.personnel_review_entries e
    WHERE e.subject_id = s.nocopk
  ) AS entry_count
FROM public.personnel_review_subjects s;

COMMIT;