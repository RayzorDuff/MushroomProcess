-- 023_operator_identity.sql
-- Operator identity normalization + auto-provisioning into personnel_review_subjects.
--
-- Goals:
--   * keep using existing text operator columns in base tables
--   * normalize operator values consistently
--   * auto-create personnel_review_subjects rows for authenticated Appsmith users
--   * require no changes to 001-004 base schema files
--   * work automatically for inserts/updates to events, lots, sterilization_runs

SET client_min_messages TO WARNING;

BEGIN;

CREATE OR REPLACE FUNCTION public.mp_operator_normalize(
  p_operator text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v text;
BEGIN
  v := NULLIF(btrim(COALESCE(p_operator, '')), '');
  IF v IS NULL THEN
    RETURN 'system';
  END IF;

  -- Treat email-style identifiers as canonical and lowercase them.
  IF position('@' IN v) > 0 THEN
    RETURN lower(v);
  END IF;

  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_operator_display_name_from_identifier(
  p_operator text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v text;
  v_local text;
BEGIN
  v := NULLIF(btrim(COALESCE(p_operator, '')), '');
  IF v IS NULL THEN
    RETURN 'System';
  END IF;

  IF position('@' IN v) > 0 THEN
    v_local := split_part(v, '@', 1);
    v_local := regexp_replace(v_local, '[._-]+', ' ', 'g');
    v_local := regexp_replace(v_local, '\s+', ' ', 'g');
    v_local := btrim(v_local);
    IF v_local IS NULL OR v_local = '' THEN
      RETURN v;
    END IF;
    RETURN initcap(v_local);
  END IF;

  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_personnel_review_subject_ensure(
  p_operator text,
  p_can_login boolean DEFAULT true,
  p_role_title text DEFAULT 'Operator',
  p_supervisor_name text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_operator text;
  v_email text;
  v_name text;
  v_id bigint;
BEGIN
  v_operator := public.mp_operator_normalize(p_operator);

  IF v_operator = 'system' THEN
    RETURN NULL;
  END IF;

  IF position('@' IN v_operator) > 0 THEN
    v_email := lower(v_operator);
    v_name := public.mp_operator_display_name_from_identifier(v_operator);
  ELSE
    v_email := NULL;
    v_name := v_operator;
  END IF;

  SELECT s.nocopk
    INTO v_id
  FROM public.personnel_review_subjects s
  WHERE s.active = true
    AND (
      (v_email IS NOT NULL AND s.appsmith_email IS NOT NULL AND lower(s.appsmith_email) = v_email)
      OR (v_name IS NOT NULL AND s.appsmith_name = v_name)
      OR (v_name IS NOT NULL AND s.full_name = v_name)
    )
  ORDER BY
    CASE
      WHEN v_email IS NOT NULL AND s.appsmith_email IS NOT NULL AND lower(s.appsmith_email) = v_email THEN 1
      WHEN v_name IS NOT NULL AND s.appsmith_name = v_name THEN 2
      WHEN v_name IS NOT NULL AND s.full_name = v_name THEN 3
      ELSE 99
    END,
    s.nocopk
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    UPDATE public.personnel_review_subjects s
    SET
      appsmith_email = COALESCE(s.appsmith_email, v_email),
      appsmith_name  = COALESCE(s.appsmith_name, v_name),
      can_login      = COALESCE(s.can_login, false) OR COALESCE(p_can_login, false),
      nc_updated_at  = now()
    WHERE s.nocopk = v_id;

    RETURN v_id;
  END IF;

  INSERT INTO public.personnel_review_subjects (
    full_name,
    active,
    role_title,
    supervisor_name,
    notes,
    appsmith_email,
    appsmith_name,
    can_login
  )
  VALUES (
    COALESCE(v_name, v_email, 'Unknown Operator'),
    true,
    COALESCE(NULLIF(btrim(p_role_title), ''), 'Operator'),
    NULLIF(btrim(p_supervisor_name), ''),
    'Auto-created from Appsmith authenticated operator.',
    v_email,
    v_name,
    COALESCE(p_can_login, true)
  )
  RETURNING nocopk INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    SELECT s.nocopk
      INTO v_id
    FROM public.personnel_review_subjects s
    WHERE (v_email IS NOT NULL AND s.appsmith_email IS NOT NULL AND lower(s.appsmith_email) = v_email)
       OR (v_name IS NOT NULL AND s.appsmith_name = v_name)
       OR (v_name IS NOT NULL AND s.full_name = v_name)
    ORDER BY s.nocopk
    LIMIT 1;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_sync_operator_identity_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.operator IS NULL OR btrim(NEW.operator) = '' THEN
    NEW.operator := public.mp_operator_normalize(NEW.operator);
    RETURN NEW;
  END IF;

  NEW.operator := public.mp_operator_normalize(NEW.operator);
  PERFORM public.mp_personnel_review_subject_ensure(NEW.operator, true, 'Operator', NULL);
  RETURN NEW;
EXCEPTION
  WHEN undefined_table OR undefined_function THEN
    RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'events'
  ) THEN
    DROP TRIGGER IF EXISTS trg_sync_operator_identity_events ON public.events;
    CREATE TRIGGER trg_sync_operator_identity_events
    BEFORE INSERT OR UPDATE OF operator ON public.events
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_sync_operator_identity_trigger();
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'lots'
  ) THEN
    DROP TRIGGER IF EXISTS trg_sync_operator_identity_lots ON public.lots;
    CREATE TRIGGER trg_sync_operator_identity_lots
    BEFORE INSERT OR UPDATE OF operator ON public.lots
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_sync_operator_identity_trigger();
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'sterilization_runs'
  ) THEN
    DROP TRIGGER IF EXISTS trg_sync_operator_identity_sterilization_runs ON public.sterilization_runs;
    CREATE TRIGGER trg_sync_operator_identity_sterilization_runs
    BEFORE INSERT OR UPDATE OF operator ON public.sterilization_runs
    FOR EACH ROW
    EXECUTE FUNCTION public.mp_sync_operator_identity_trigger();
  END IF;
END $$;

COMMIT;
