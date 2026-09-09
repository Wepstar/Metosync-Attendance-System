-- Fix admin_users role check constraint violation.
-- Backfill invalid/null roles before re-adding the constraint.

UPDATE public.admin_users
SET role = CASE
  WHEN system_role = 'view_only' THEN 'viewer'
  WHEN system_role = 'payroll_manager' THEN 'payroll_officer'
  WHEN system_role = 'hr' THEN 'admin'
  WHEN system_role = 'super_admin' THEN 'owner'
  ELSE 'owner'
END
WHERE role IS NULL OR role NOT IN ('owner', 'admin', 'manager', 'payroll_officer', 'viewer');

ALTER TABLE public.admin_users
  DROP CONSTRAINT IF EXISTS admin_users_role_check,
  ADD CONSTRAINT admin_users_role_check
  CHECK (role IN ('owner', 'admin', 'manager', 'payroll_officer', 'viewer'));
