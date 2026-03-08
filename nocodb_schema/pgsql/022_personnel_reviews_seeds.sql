INSERT INTO public.personnel_review_subjects
  (subject_code, full_name, active, role_title, supervisor_name, hire_date)
VALUES
  ('EMP-001', 'Employee Name', true, 'Owner', 'Owner Name', '2025-09-01')
ON CONFLICT (subject_code) DO NOTHING;