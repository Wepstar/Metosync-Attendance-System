-- ==============================================================================
-- METOSYNC DATABASE PERFORMANCE INDEXES SCRIPT
-- ==============================================================================
-- Run this in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/lqgdyjvfirdhstcmepyr/sql/new
-- ==============================================================================
-- These indexes accelerate multi-tenant filters, relational joins, and dashboard queries,
-- reducing execution times from hundreds of milliseconds to < 5ms.
-- ==============================================================================

-- 1. Admin users & Companies lookups
CREATE INDEX IF NOT EXISTS idx_admin_users_company_id ON public.admin_users(company_id);

-- 2. Staff multi-tenant lookups & searches
CREATE INDEX IF NOT EXISTS idx_staff_company_id ON public.staff(company_id);
CREATE INDEX IF NOT EXISTS idx_staff_created_at ON public.staff(created_at DESC);

-- 3. Sites lookups
CREATE INDEX IF NOT EXISTS idx_sites_company_id ON public.sites(company_id);

-- 4. Attendance date & staff lookups (Crucial for Daily Dashboard & 7-Day Trends)
CREATE INDEX IF NOT EXISTS idx_attendance_work_date ON public.attendance(work_date);
CREATE INDEX IF NOT EXISTS idx_attendance_staff_date ON public.attendance(staff_id, work_date);
CREATE INDEX IF NOT EXISTS idx_attendance_status_date ON public.attendance(status, work_date);

-- 5. Payroll Periods & Entries lookups
CREATE INDEX IF NOT EXISTS idx_payroll_periods_company_status ON public.payroll_periods(company_id, status);
CREATE INDEX IF NOT EXISTS idx_payroll_entries_period_id ON public.payroll_entries(payroll_period_id);
CREATE INDEX IF NOT EXISTS idx_payroll_entries_staff_id ON public.payroll_entries(staff_id);

-- 6. Deduction Types lookups
CREATE INDEX IF NOT EXISTS idx_deduction_types_company_id ON public.deduction_types(company_id);
