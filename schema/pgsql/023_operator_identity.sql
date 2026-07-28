-- 023_operator_identity.sql
-- Operator identity normalization + auto-provisioning into personnel_review_subjects.
--
-- Goals:
--   * keep using existing text operator columns in base tables
--   * normalize operator values consistently
--   * auto-create personnel_review_subjects rows for authenticated Appsmith users
--   * require no changes to 001-004 base schema files
--   * work automatically for inserts/updates to events, lots, products, sterilization_runs

SET client_min_messages TO WARNING;

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE IF EXISTS public.personnel_review_subjects
  ADD COLUMN IF NOT EXISTS appsmith_email text,
  ADD COLUMN IF NOT EXISTS appsmith_name text,
  ADD COLUMN IF NOT EXISTS can_login boolean DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'ux_personnel_review_subjects_appsmith_email'
  ) THEN
    CREATE UNIQUE INDEX ux_personnel_review_subjects_appsmith_email
      ON public.personnel_review_subjects (lower(appsmith_email))
      WHERE appsmith_email IS NOT NULL AND btrim(appsmith_email) <> '';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_personnel_review_subjects_can_login'
  ) THEN
    CREATE INDEX idx_personnel_review_subjects_can_login
      ON public.personnel_review_subjects (can_login);
  END IF;
END $$;

ALTER TABLE IF EXISTS public.personnel_review_entries
  ADD COLUMN IF NOT EXISTS entered_by_subject_id bigint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_personnel_review_entries_entered_by_subject'
      AND conrelid = 'public.personnel_review_entries'::regclass
  ) THEN
    ALTER TABLE public.personnel_review_entries
      ADD CONSTRAINT fk_personnel_review_entries_entered_by_subject
      FOREIGN KEY (entered_by_subject_id)
      REFERENCES public.personnel_review_subjects(nocopk)
      ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_personnel_review_entries_entered_by_subject_id'
  ) THEN
    CREATE INDEX idx_personnel_review_entries_entered_by_subject_id
      ON public.personnel_review_entries(entered_by_subject_id);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.mp_strip_outer_quotes(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
BEGIN
  v := p_value;
  IF v IS NULL THEN
    RETURN NULL;
  END IF;

  v := btrim(v);

  WHILE length(v) >= 2 AND (
      (left(v, 1) = '''' AND right(v, 1) = '''') OR
      (left(v, 1) = '"' AND right(v, 1) = '"')
  ) LOOP
    v := substr(v, 2, length(v) - 2);
    v := btrim(v);
  END LOOP;

  IF left(v, 1) IN ('''', '"') THEN
    v := ltrim(v, '''" ');
  END IF;
  IF right(v, 1) IN ('''', '"') THEN
    v := rtrim(v, '''" ');
  END IF;

  v := regexp_replace(v, '\s+', ' ', 'g');
  v := NULLIF(btrim(v), '');
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_normalize_operator_identity(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
BEGIN
  v := public.mp_strip_outer_quotes(p_value);
  IF v IS NULL THEN
    RETURN NULL;
  END IF;

  -- Handle values like Name <email@example.com>
  IF position('<' IN v) > 0 AND position('>' IN v) > position('<' IN v) THEN
    v := split_part(split_part(v, '<', 2), '>', 1);
    v := public.mp_strip_outer_quotes(v);
  END IF;

  IF position('@' IN v) > 0 THEN
    v := lower(v);
  END IF;

  RETURN NULLIF(btrim(v), '');
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_operator_identity_email(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
BEGIN
  v := public.mp_normalize_operator_identity(p_value);
  IF v IS NULL THEN
    RETURN NULL;
  END IF;

  IF v ~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$' THEN
    RETURN lower(v);
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_operator_identity_name(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
BEGIN
  v := public.mp_normalize_operator_identity(p_value);
  IF v IS NULL THEN
    RETURN NULL;
  END IF;

  IF public.mp_operator_identity_email(v) IS NOT NULL THEN
    RETURN NULL;
  END IF;

  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_rewrite_operator_aliases_for_subject(p_subject_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_email text;
  v_aliases text[];
BEGIN
  IF pg_trigger_depth() > 0 THEN
    RETURN;
  END IF;

  SELECT
    public.mp_operator_identity_email(s.appsmith_email),
    ARRAY(
      SELECT DISTINCT public.mp_normalize_operator_identity(alias_value)
      FROM unnest(ARRAY[
        s.appsmith_name,
        s.full_name,
        split_part(s.appsmith_email, '@', 1)
      ]) AS alias_value
      WHERE public.mp_normalize_operator_identity(alias_value) IS NOT NULL
    )
    INTO v_email, v_aliases
  FROM public.personnel_review_subjects s
  WHERE s.nocopk = p_subject_id;

  IF v_email IS NULL OR v_aliases IS NULL OR array_length(v_aliases, 1) IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.events
  SET operator = v_email
  WHERE public.mp_operator_identity_email(operator) IS NULL
    AND public.mp_normalize_operator_identity(operator) = ANY(v_aliases);

  UPDATE public.lots
  SET operator = v_email
  WHERE public.mp_operator_identity_email(operator) IS NULL
    AND public.mp_normalize_operator_identity(operator) = ANY(v_aliases);

  UPDATE public.products
  SET operator = v_email
  WHERE public.mp_operator_identity_email(operator) IS NULL
    AND public.mp_normalize_operator_identity(operator) = ANY(v_aliases);

  UPDATE public.sterilization_runs
  SET operator = v_email
  WHERE public.mp_operator_identity_email(operator) IS NULL
    AND public.mp_normalize_operator_identity(operator) = ANY(v_aliases);

  UPDATE public.personnel_review_entries
  SET entered_by = v_email
  WHERE public.mp_operator_identity_email(entered_by) IS NULL
    AND public.mp_normalize_operator_identity(entered_by) = ANY(v_aliases);
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_ensure_personnel_subject(
  p_operator text,
  p_role_title text DEFAULT 'Operator',
  p_notes text DEFAULT 'Auto-created from Appsmith authenticated operator.'
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_raw text;
  v_email text;
  v_name text;
  v_id bigint;
BEGIN
  v_raw := public.mp_normalize_operator_identity(p_operator);
  v_email := public.mp_operator_identity_email(v_raw);
  v_name := public.mp_operator_identity_name(v_raw);

  IF v_raw IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_email IS NOT NULL THEN
    SELECT s.nocopk
      INTO v_id
    FROM public.personnel_review_subjects s
    WHERE lower(s.appsmith_email) = v_email
    ORDER BY s.nocopk
    LIMIT 1;

    IF v_id IS NOT NULL THEN
      UPDATE public.personnel_review_subjects s
      SET
        appsmith_email = v_email,
        appsmith_name = COALESCE(NULLIF(s.appsmith_name, ''), s.full_name, split_part(v_email, '@', 1)),
        full_name = COALESCE(NULLIF(s.full_name, ''), s.appsmith_name, split_part(v_email, '@', 1)),
        can_login = true,
        nc_updated_at = now()
      WHERE s.nocopk = v_id;

      PERFORM public.mp_rewrite_operator_aliases_for_subject(v_id);
      RETURN v_id;
    END IF;

    SELECT s.nocopk
      INTO v_id
    FROM public.personnel_review_subjects s
    WHERE s.can_login = true
      AND (
        lower(COALESCE(s.appsmith_name, '')) = lower(split_part(v_email, '@', 1))
        OR lower(COALESCE(s.full_name, '')) = lower(split_part(v_email, '@', 1))
      )
    ORDER BY s.nocopk
    LIMIT 1;

    IF v_id IS NOT NULL THEN
      UPDATE public.personnel_review_subjects s
      SET
        appsmith_email = COALESCE(NULLIF(s.appsmith_email, ''), v_email),
        appsmith_name = COALESCE(NULLIF(s.appsmith_name, ''), split_part(v_email, '@', 1)),
        full_name = COALESCE(NULLIF(s.full_name, ''), split_part(v_email, '@', 1)),
        can_login = true,
        nc_updated_at = now()
      WHERE s.nocopk = v_id;

      PERFORM public.mp_rewrite_operator_aliases_for_subject(v_id);
      RETURN v_id;
    END IF;

    INSERT INTO public.personnel_review_subjects (
      full_name,
      active,
      role_title,
      notes,
      appsmith_email,
      appsmith_name,
      can_login
    )
    VALUES (
      split_part(v_email, '@', 1),
      true,
      COALESCE(NULLIF(p_role_title, ''), 'Operator'),
      COALESCE(NULLIF(p_notes, ''), 'Auto-created from Appsmith authenticated operator.'),
      v_email,
      split_part(v_email, '@', 1),
      true
    )
    RETURNING nocopk INTO v_id;

    RETURN v_id;
  END IF;

  IF v_name IS NOT NULL THEN
    SELECT s.nocopk
      INTO v_id
    FROM public.personnel_review_subjects s
    WHERE lower(COALESCE(s.appsmith_name, '')) = lower(v_name)
       OR lower(COALESCE(s.full_name, '')) = lower(v_name)
    ORDER BY
      CASE WHEN lower(COALESCE(s.appsmith_name, '')) = lower(v_name) THEN 1 ELSE 2 END,
      s.nocopk
    LIMIT 1;

    IF v_id IS NOT NULL THEN
      UPDATE public.personnel_review_subjects s
      SET
        appsmith_name = COALESCE(NULLIF(s.appsmith_name, ''), v_name),
        full_name = COALESCE(NULLIF(s.full_name, ''), v_name),
        can_login = true,
        nc_updated_at = now()
      WHERE s.nocopk = v_id;
      RETURN v_id;
    END IF;

    INSERT INTO public.personnel_review_subjects (
      full_name,
      active,
      role_title,
      notes,
      appsmith_name,
      can_login
    )
    VALUES (
      v_name,
      true,
      COALESCE(NULLIF(p_role_title, ''), 'Operator'),
      COALESCE(NULLIF(p_notes, ''), 'Auto-created from Appsmith authenticated operator.'),
      v_name,
      true
    )
    RETURNING nocopk INTO v_id;

    RETURN v_id;
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_current_operator_subject(p_operator text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN public.mp_ensure_personnel_subject(p_operator);
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_touch_operator_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_subject_id bigint;
BEGIN
  IF to_jsonb(NEW) ? 'operator' THEN
    NEW.operator := public.mp_normalize_operator_identity(NEW.operator);

    IF NEW.operator IS NOT NULL THEN
      v_subject_id := public.mp_current_operator_subject(NEW.operator);
    END IF;
  END IF;

  IF to_jsonb(NEW) ? 'entered_by' THEN
    NEW.entered_by := public.mp_normalize_operator_identity(NEW.entered_by);
    IF NEW.entered_by IS NOT NULL AND (to_jsonb(NEW) ? 'entered_by_subject_id') THEN
      NEW.entered_by_subject_id := public.mp_current_operator_subject(NEW.entered_by);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'events' AND column_name = 'operator'
  ) THEN
    DROP TRIGGER IF EXISTS trg_touch_operator_identity_events ON public.events;
    CREATE TRIGGER trg_touch_operator_identity_events
    BEFORE INSERT OR UPDATE OF operator ON public.events
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_touch_operator_identity();
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'lots' AND column_name = 'operator'
  ) THEN
    DROP TRIGGER IF EXISTS trg_touch_operator_identity_lots ON public.lots;
    CREATE TRIGGER trg_touch_operator_identity_lots
    BEFORE INSERT OR UPDATE OF operator ON public.lots
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_touch_operator_identity();
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'operator'
  ) THEN
    DROP TRIGGER IF EXISTS trg_touch_operator_identity_products ON public.products;
    CREATE TRIGGER trg_touch_operator_identity_products
    BEFORE INSERT OR UPDATE OF operator ON public.products
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_touch_operator_identity();
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'sterilization_runs' AND column_name = 'operator'
  ) THEN
    DROP TRIGGER IF EXISTS trg_touch_operator_identity_sterilization_runs ON public.sterilization_runs;
    CREATE TRIGGER trg_touch_operator_identity_sterilization_runs
    BEFORE INSERT OR UPDATE OF operator ON public.sterilization_runs
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_touch_operator_identity();
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'personnel_review_entries' AND column_name = 'entered_by'
  ) THEN
    DROP TRIGGER IF EXISTS trg_touch_operator_identity_personnel_review_entries ON public.personnel_review_entries;
    CREATE TRIGGER trg_touch_operator_identity_personnel_review_entries
    BEFORE INSERT OR UPDATE OF entered_by ON public.personnel_review_entries
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_touch_operator_identity();
  END IF;
END $$;

COMMIT;
