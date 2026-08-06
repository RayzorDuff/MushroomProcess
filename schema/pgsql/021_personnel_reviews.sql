-- 021_personnel_reviews.sql
-- Personnel reviews / 10-minute manager log
-- Revised to:
--   * align with MushroomProcess visible-ID conventions
--   * suppress NOTICE chatter
--   * add Appsmith identity fields to personnel_review_subjects
--   * add optional entered_by_subject_id FK on review entries
--   * auto-resolve entered_by_subject_id from current Appsmith user identity
--   * keep entered_by as immutable text snapshot for audit/history

SET client_min_messages TO WARNING;

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DROP VIEW IF EXISTS public.vc_personnel_review_entries CASCADE;
DROP VIEW IF EXISTS public.vc_personnel_review_subjects CASCADE;

DROP TRIGGER IF EXISTS set_autogen_ids_personnel_review_entries ON public.personnel_review_entries;
DROP TRIGGER IF EXISTS set_autogen_ids_personnel_review_subjects ON public.personnel_review_subjects;

DROP FUNCTION IF EXISTS public.set_autogen_ids_personnel_review_entries() CASCADE;
DROP FUNCTION IF EXISTS public.set_autogen_ids_personnel_review_subjects() CASCADE;
DROP FUNCTION IF EXISTS public.mp_personnel_review_entry_insert(
  bigint,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  date,
  timestamp without time zone,
  boolean,
  date,
  date,
  date,
  text[]
) CASCADE;

DROP TABLE IF EXISTS public.personnel_review_entries CASCADE;
DROP TABLE IF EXISTS public.personnel_review_subjects CASCADE;

CREATE TABLE public.personnel_review_subjects (
  nocopk BIGSERIAL PRIMARY KEY,
  subject_code text,
  full_name text NOT NULL,
  active boolean DEFAULT true,
  role_title text,
  supervisor_name text,
  hire_date date,
  notes text,

  -- Appsmith identity / operator mapping
  appsmith_email text,
  appsmith_name text,
  can_login boolean DEFAULT false,

  nocouuid uuid DEFAULT gen_random_uuid(),
  airtable_id text UNIQUE,
  nc_created_at timestamp without time zone DEFAULT now(),
  nc_updated_at timestamp without time zone DEFAULT now()
);

ALTER TABLE public.personnel_review_subjects
  ADD CONSTRAINT uq_personnel_review_subjects_subject_code
  UNIQUE (subject_code);

CREATE UNIQUE INDEX ux_personnel_review_subjects_appsmith_email
  ON public.personnel_review_subjects (lower(appsmith_email))
  WHERE appsmith_email IS NOT NULL AND btrim(appsmith_email) <> '';

CREATE INDEX idx_personnel_review_subjects_can_login
  ON public.personnel_review_subjects (can_login);

CREATE TABLE public.personnel_review_entries (
  nocopk BIGSERIAL PRIMARY KEY,
  entry_code text,
  subject_id bigint NOT NULL,
  entered_by_subject_id bigint,
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
    FOREIGN KEY (subject_id)
    REFERENCES public.personnel_review_subjects(nocopk)
    ON DELETE RESTRICT,

  CONSTRAINT fk_personnel_review_entries_entered_by_subject
    FOREIGN KEY (entered_by_subject_id)
    REFERENCES public.personnel_review_subjects(nocopk)
    ON DELETE SET NULL,

  CONSTRAINT chk_personnel_review_entries_source
    CHECK (entry_source IN ('manager', 'self', 'peer', 'upward', 'system')),

  CONSTRAINT chk_personnel_review_entries_note_type
    CHECK (note_type IN (
      'positive',
      'coaching',
      'neutral',
      'concern',
      'accomplishment',
      'goal',
      'review_prep',
      'upward_feedback'
    )),

  CONSTRAINT chk_personnel_review_entries_category
    CHECK (category IN (
      'quality',
      'productivity',
      'reliability',
      'communication',
      'teamwork',
      'initiative',
      'leadership',
      'attendance',
      'training',
      'safety',
      'judgment',
      'professionalism',
      'other'
    )),

  CONSTRAINT chk_personnel_review_entries_visibility
    CHECK (visibility IN ('manager_only', 'shared_at_review', 'shared_immediately')),

  CONSTRAINT chk_personnel_review_entries_summary_not_blank
    CHECK (btrim(summary) <> '')
);

ALTER TABLE public.personnel_review_entries
  ADD CONSTRAINT uq_personnel_review_entries_entry_code
  UNIQUE (entry_code);

CREATE INDEX idx_personnel_review_entries_subject_id
  ON public.personnel_review_entries(subject_id);

CREATE INDEX idx_personnel_review_entries_entered_by_subject_id
  ON public.personnel_review_entries(entered_by_subject_id);

CREATE INDEX idx_personnel_review_entries_entry_ts
  ON public.personnel_review_entries(entry_ts DESC);

CREATE INDEX idx_personnel_review_entries_note_type
  ON public.personnel_review_entries(note_type);

CREATE INDEX idx_personnel_review_entries_category
  ON public.personnel_review_entries(category);

CREATE INDEX idx_personnel_review_entries_follow_up
  ON public.personnel_review_entries(follow_up_needed, follow_up_by);

CREATE INDEX idx_personnel_review_entries_entered_by_text
  ON public.personnel_review_entries (lower(entered_by));

CREATE OR REPLACE FUNCTION public.set_autogen_ids_personnel_review_subjects()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.nocouuid IS NULL THEN
    NEW.nocouuid := gen_random_uuid();
  END IF;

  IF NEW.nc_created_at IS NULL THEN
    NEW.nc_created_at := now();
  END IF;

  NEW.nc_updated_at := now();

  IF NEW.subject_code IS NULL OR btrim(NEW.subject_code) = '' THEN
    NEW.subject_code := (
      'SUBJ-' ||
      to_char(NEW.nc_created_at::timestamp, 'YYMMDD') ||
      '-' ||
      right(
        COALESCE(
          NULLIF(NEW.airtable_id::text, ''),
          replace(NEW.nocouuid::text, '-', ''),
          COALESCE(NEW.nocopk::text, '')
        ),
        4
      )
    );
  END IF;

  IF NEW.appsmith_email IS NOT NULL THEN
    NEW.appsmith_email := lower(btrim(NEW.appsmith_email));
  END IF;

  IF NEW.appsmith_name IS NOT NULL THEN
    NEW.appsmith_name := btrim(NEW.appsmith_name);
  END IF;

  IF NEW.full_name IS NOT NULL THEN
    NEW.full_name := btrim(NEW.full_name);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER set_autogen_ids_personnel_review_subjects
BEFORE INSERT OR UPDATE ON public.personnel_review_subjects
FOR EACH ROW
EXECUTE FUNCTION public.set_autogen_ids_personnel_review_subjects();

CREATE OR REPLACE FUNCTION public.set_autogen_ids_personnel_review_entries()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.nocouuid IS NULL THEN
    NEW.nocouuid := gen_random_uuid();
  END IF;

  IF NEW.nc_created_at IS NULL THEN
    NEW.nc_created_at := now();
  END IF;

  NEW.nc_updated_at := now();

  IF NEW.entry_ts IS NULL THEN
    NEW.entry_ts := now();
  END IF;

  IF NEW.observed_on IS NULL THEN
    NEW.observed_on := CURRENT_DATE;
  END IF;

  IF NEW.entry_code IS NULL OR btrim(NEW.entry_code) = '' THEN
    NEW.entry_code := (
      'PRE-' ||
      to_char(NEW.nc_created_at::timestamp, 'YYMMDD') ||
      '-' ||
      right(
        COALESCE(
          NULLIF(NEW.airtable_id::text, ''),
          replace(NEW.nocouuid::text, '-', ''),
          COALESCE(NEW.nocopk::text, '')
        ),
        4
      )
    );
  END IF;

  IF NEW.entered_by IS NOT NULL THEN
    NEW.entered_by := btrim(NEW.entered_by);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER set_autogen_ids_personnel_review_entries
BEFORE INSERT OR UPDATE ON public.personnel_review_entries
FOR EACH ROW
EXECUTE FUNCTION public.set_autogen_ids_personnel_review_entries();

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

  v_entered_by := NULLIF(btrim(p_entered_by), '');

  IF v_entered_by IS NULL THEN
    RAISE EXCEPTION 'entered_by is required';
  END IF;

  IF p_summary IS NULL OR btrim(p_summary) = '' THEN
    RAISE EXCEPTION 'summary is required';
  END IF;

  /*
    Resolve current Appsmith user back to personnel_review_subjects, if possible.
    Preference order:
      1. appsmith_email exact match (case-insensitive)
      2. appsmith_name exact match
      3. full_name exact match
  */
  SELECT s.nocopk
    INTO v_entered_by_subject_id
  FROM public.personnel_review_subjects s
  WHERE s.active = true
    AND (
      (s.appsmith_email IS NOT NULL AND lower(s.appsmith_email) = lower(v_entered_by))
      OR (s.appsmith_name IS NOT NULL AND s.appsmith_name = v_entered_by)
      OR (s.full_name = v_entered_by)
    )
  ORDER BY
    CASE
      WHEN s.appsmith_email IS NOT NULL AND lower(s.appsmith_email) = lower(v_entered_by) THEN 1
      WHEN s.appsmith_name IS NOT NULL AND s.appsmith_name = v_entered_by THEN 2
      WHEN s.full_name = v_entered_by THEN 3
      ELSE 99
    END,
    s.nocopk
  LIMIT 1;

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

CREATE VIEW public.vc_personnel_review_subjects AS
SELECT
  s.nocopk,
  s.subject_code,
  s.full_name,
  s.active,
  s.role_title,
  s.supervisor_name,
  s.hire_date,
  s.notes,
  s.appsmith_email,
  s.appsmith_name,
  s.can_login,
  s.nocouuid,
  s.airtable_id,
  s.nc_created_at,
  s.nc_updated_at,
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

CREATE VIEW public.vc_personnel_review_entries AS
SELECT
  e.nocopk,
  e.entry_code,
  e.subject_id,
  s.subject_code,
  s.full_name,
  s.role_title,
  s.supervisor_name,
  s.active AS subject_active,

  e.entered_by_subject_id,
  es.subject_code AS entered_by_subject_code,
  es.full_name AS entered_by_subject_name,
  es.appsmith_email AS entered_by_subject_email,

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
  e.nocouuid,
  e.airtable_id,
  e.nc_created_at,
  e.nc_updated_at
FROM public.personnel_review_entries e
JOIN public.personnel_review_subjects s
  ON s.nocopk = e.subject_id
LEFT JOIN public.personnel_review_subjects es
  ON es.nocopk = e.entered_by_subject_id;

COMMIT;