SET client_min_messages TO WARNING;

BEGIN;

INSERT INTO public.personnel_review_subjects (
  full_name,
  active,
  role_title,
  supervisor_name,
  hire_date,
  notes
)
VALUES
  (
    'Employee Name',
    true,
    'Technician',
    'Owner Name',
    DATE '2025-09-01',
    'Initial seed subject for personnel review testing.'
  )
ON CONFLICT DO NOTHING;

COMMIT;