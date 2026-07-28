-- 022_personnel_reviews_seeds.sql
-- Minimal seed data for personnel review testing.
-- Edit the names/emails before committing to your real environment.

SET client_min_messages TO WARNING;

BEGIN;

-- Logged-in reviewer / supervisor identity row
INSERT INTO public.personnel_review_subjects (
  full_name,
  active,
  role_title,
  supervisor_name,
  hire_date,
  notes,
  appsmith_email,
  appsmith_name,
  can_login
)
SELECT
  'Supervisor Name',
  true,
  'Supervisor',
  NULL,
  NULL,
  'Seed row for current Appsmith operator identity.',
  'test@test.com',
  'Supervisor Name',
  true
WHERE NOT EXISTS (
  SELECT 1
  FROM public.personnel_review_subjects s
  WHERE lower(s.appsmith_email) = lower('test@test.com')
     OR s.full_name = 'Supervisor Name'
);

-- Example employee under review
INSERT INTO public.personnel_review_subjects (
  full_name,
  active,
  role_title,
  supervisor_name,
  hire_date,
  notes,
  appsmith_email,
  appsmith_name,
  can_login
)
SELECT
  'Employee Name',
  true,
  'Technician',
  'Supervisor Name',
  DATE '2025-09-01',
  'Initial seed subject for personnel review testing.',
  NULL,
  NULL,
  false
WHERE NOT EXISTS (
  SELECT 1
  FROM public.personnel_review_subjects s
  WHERE s.full_name = 'Employee Name'
);

COMMIT;