-- ==============================================================================
-- METOSYNC COMPLETE ROW LEVEL SECURITY (RLS) & MULTI-TENANCY HARDENING SCRIPT
-- ==============================================================================
-- Run this in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/lqgdyjvfirdhstcmepyr/sql/new
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. HELPER FUNCTIONS (Optimized & Cached with SECURITY DEFINER)
-- ------------------------------------------------------------------------------

-- Returns the company_id of the currently authenticated admin user
CREATE OR REPLACE FUNCTION public.auth_company_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT company_id 
  FROM public.admin_users 
  WHERE id = auth.uid()
  LIMIT 1;
$$;

-- ------------------------------------------------------------------------------
-- 2. ENABLE RLS ON ALL CORE TABLES
-- ------------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.sites ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.payroll_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.payroll_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.deduction_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.staff_custom_fields ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------------
-- 3. COMPANIES TABLE POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "companies_tenant_select" ON public.companies;
CREATE POLICY "companies_tenant_select" ON public.companies
  FOR SELECT
  TO authenticated
  USING (
    id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

DROP POLICY IF EXISTS "companies_tenant_update" ON public.companies;
CREATE POLICY "companies_tenant_update" ON public.companies
  FOR UPDATE
  TO authenticated
  USING (
    id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 4. ADMIN_USERS TABLE POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "admin_users_select" ON public.admin_users;
CREATE POLICY "admin_users_select" ON public.admin_users
  FOR SELECT
  TO authenticated
  USING (
    id = auth.uid()
    OR company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

DROP POLICY IF EXISTS "admin_users_update" ON public.admin_users;
CREATE POLICY "admin_users_update" ON public.admin_users
  FOR UPDATE
  TO authenticated
  USING (
    id = auth.uid()
    OR company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 5. SITES TABLE POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "sites_tenant_all" ON public.sites;
CREATE POLICY "sites_tenant_all" ON public.sites
  FOR ALL
  TO authenticated
  USING (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 6. STAFF TABLE POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "staff_tenant_all" ON public.staff;
CREATE POLICY "staff_tenant_all" ON public.staff
  FOR ALL
  TO authenticated
  USING (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 7. ATTENDANCE TABLE POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "attendance_tenant_all" ON public.attendance;
CREATE POLICY "attendance_tenant_all" ON public.attendance
  FOR ALL
  TO authenticated
  USING (
    staff_id IN (SELECT id FROM public.staff WHERE company_id = public.auth_company_id())
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    staff_id IN (SELECT id FROM public.staff WHERE company_id = public.auth_company_id())
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 8. PAYROLL PERIODS POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "payroll_periods_tenant_all" ON public.payroll_periods;
CREATE POLICY "payroll_periods_tenant_all" ON public.payroll_periods
  FOR ALL
  TO authenticated
  USING (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 9. PAYROLL ENTRIES POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "payroll_entries_tenant_all" ON public.payroll_entries;
CREATE POLICY "payroll_entries_tenant_all" ON public.payroll_entries
  FOR ALL
  TO authenticated
  USING (
    payroll_period_id IN (SELECT id FROM public.payroll_periods WHERE company_id = public.auth_company_id())
    OR staff_id IN (SELECT id FROM public.staff WHERE company_id = public.auth_company_id())
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    payroll_period_id IN (SELECT id FROM public.payroll_periods WHERE company_id = public.auth_company_id())
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 10. DEDUCTION TYPES POLICIES (Tenant custom deductions + Global defaults)
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "deduction_types_select" ON public.deduction_types;
CREATE POLICY "deduction_types_select" ON public.deduction_types
  FOR SELECT
  TO authenticated
  USING (
    company_id = public.auth_company_id()
    OR company_id IS NULL
    OR (SELECT public.is_platform_admin())
  );

DROP POLICY IF EXISTS "deduction_types_modify" ON public.deduction_types;
CREATE POLICY "deduction_types_modify" ON public.deduction_types
  FOR ALL
  TO authenticated
  USING (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    company_id = public.auth_company_id()
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 11. STAFF CUSTOM FIELDS POLICIES
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "staff_custom_fields_tenant_all" ON public.staff_custom_fields;
CREATE POLICY "staff_custom_fields_tenant_all" ON public.staff_custom_fields
  FOR ALL
  TO authenticated
  USING (
    staff_id IN (SELECT id FROM public.staff WHERE company_id = public.auth_company_id())
    OR (SELECT public.is_platform_admin())
  )
  WITH CHECK (
    staff_id IN (SELECT id FROM public.staff WHERE company_id = public.auth_company_id())
    OR (SELECT public.is_platform_admin())
  );

-- ------------------------------------------------------------------------------
-- 12. STORAGE BUCKET (org-logo) POLICIES
-- ------------------------------------------------------------------------------
-- Create bucket if not exists and ensure public = true
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'org-logo',
  'org-logo',
  true,
  5242880, -- 5 MB limit
  ARRAY['image/png', 'image/jpeg', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET 
  public = true,
  file_size_limit = 5242880,
  allowed_mime_types = ARRAY['image/png', 'image/jpeg', 'image/webp'];

-- Enable RLS on storage objects
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- 12a. Public read access for logos (allows getPublicUrl to work for all visitors)
DROP POLICY IF EXISTS "org_logo_public_read" ON storage.objects;
CREATE POLICY "org_logo_public_read" ON storage.objects
  FOR SELECT
  TO public
  USING (bucket_id = 'org-logo');

-- 12b. Tenant upload policy (restricted to company folder: /{company_id}/*)
DROP POLICY IF EXISTS "org_logo_tenant_upload" ON storage.objects;
CREATE POLICY "org_logo_tenant_upload" ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'org-logo'
    AND (
      (storage.foldername(name))[1] = (public.auth_company_id())::text
      OR (SELECT public.is_platform_admin())
    )
  );

-- 12c. Tenant update policy
DROP POLICY IF EXISTS "org_logo_tenant_update" ON storage.objects;
CREATE POLICY "org_logo_tenant_update" ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'org-logo'
    AND (
      (storage.foldername(name))[1] = (public.auth_company_id())::text
      OR (SELECT public.is_platform_admin())
    )
  );

-- 12d. Tenant delete policy
DROP POLICY IF EXISTS "org_logo_tenant_delete" ON storage.objects;
CREATE POLICY "org_logo_tenant_delete" ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'org-logo'
    AND (
      (storage.foldername(name))[1] = (public.auth_company_id())::text
      OR (SELECT public.is_platform_admin())
    )
  );
