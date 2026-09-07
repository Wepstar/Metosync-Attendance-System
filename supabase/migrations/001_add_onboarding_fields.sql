-- =============================================================================
-- METOSYNC ONBOARDING FIELDS MIGRATION
-- Adds comprehensive organizational and compliance fields for multi-step onboarding
-- =============================================================================

-- Add new company fields for organizational details
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS business_type text;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS employee_count_range text;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS zip_code text;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS registration_document_url text;

-- Add leave policy fields
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS leave_policy_annual_days integer DEFAULT 20;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS leave_policy_sick_rate numeric DEFAULT 0.5;

-- Add system preference fields
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS service_tier text DEFAULT 'attendance_and_payroll';
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS timezone text DEFAULT 'Africa/Accra';
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS date_format text DEFAULT 'DD/MM/YYYY';
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS currency_symbol_placement text DEFAULT 'before';
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS session_timeout_minutes integer DEFAULT 15;

-- Add compliance and policy acceptance fields
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS dpa_accepted boolean DEFAULT false;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS msa_accepted boolean DEFAULT false;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS privacy_policy_accepted boolean DEFAULT false;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS biometric_consent boolean DEFAULT false;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS gps_consent boolean DEFAULT false;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS direct_debit_authorized boolean DEFAULT false;

-- Add admin users fields for system roles and contact designation
ALTER TABLE public.admin_users ADD COLUMN IF NOT EXISTS system_role text DEFAULT 'super_admin';
ALTER TABLE public.admin_users ADD COLUMN IF NOT EXISTS is_primary_contact boolean DEFAULT false;

-- Add constraints for data integrity
DO $$
BEGIN
    -- Drop constraints if they exist to avoid conflicts
    IF EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'check_business_type' 
        AND conrelid = 'public.companies'::regclass
    ) THEN
        ALTER TABLE public.companies DROP CONSTRAINT check_business_type;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'check_employee_range' 
        AND conrelid = 'public.companies'::regclass
    ) THEN
        ALTER TABLE public.companies DROP CONSTRAINT check_employee_range;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'check_service_tier' 
        AND conrelid = 'public.companies'::regclass
    ) THEN
        ALTER TABLE public.companies DROP CONSTRAINT check_service_tier;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'check_system_role' 
        AND conrelid = 'public.admin_users'::regclass
    ) THEN
        ALTER TABLE public.admin_users DROP CONSTRAINT check_system_role;
    END IF;
    
    -- Add business type constraint
    ALTER TABLE public.companies 
    ADD CONSTRAINT check_business_type 
    CHECK (business_type IS NULL OR business_type IN ('School', 'Supermarket', 'Farm', 'Construction', 'Technology', 'Hospitality', 'Other'));
    
    -- Add employee count range constraint
    ALTER TABLE public.companies 
    ADD CONSTRAINT check_employee_range 
    CHECK (employee_count_range IS NULL OR employee_count_range IN ('1-50', '51-200', '201-500', '501-1000', '1000+'));
    
    -- Add service tier constraint
    ALTER TABLE public.companies 
    ADD CONSTRAINT check_service_tier 
    CHECK (service_tier IS NULL OR service_tier IN ('attendance_only', 'payroll_only', 'attendance_and_payroll', 'stores_inventory', 'administrator', 'all_inclusive'));
    
    -- Add system role constraint
    ALTER TABLE public.admin_users 
    ADD CONSTRAINT check_system_role 
    CHECK (system_role IS NULL OR system_role IN ('super_admin', 'payroll_manager', 'hr', 'view_only'));
END $$;

-- Add comments for documentation
COMMENT ON COLUMN public.companies.business_type IS 'Type of business organization (School, Supermarket, Farm, etc.)';
COMMENT ON COLUMN public.companies.employee_count_range IS 'Employee count range for company size classification';
COMMENT ON COLUMN public.companies.zip_code IS 'Postal or zip code for company address';
COMMENT ON COLUMN public.companies.registration_document_url IS 'URL to business registration document';
COMMENT ON COLUMN public.companies.leave_policy_annual_days IS 'Default annual leave days for employees';
COMMENT ON COLUMN public.companies.leave_policy_sick_rate IS 'Sick leave accrual rate (days per month worked)';
COMMENT ON COLUMN public.companies.service_tier IS 'Metosync service tier selected by company';
COMMENT ON COLUMN public.companies.timezone IS 'Company timezone for scheduling and reporting';
COMMENT ON COLUMN public.companies.date_format IS 'Preferred date format for display (DD/MM/YYYY or MM/DD/YYYY)';
COMMENT ON COLUMN public.companies.currency_symbol_placement IS 'Currency symbol placement (before or after amount)';
COMMENT ON COLUMN public.companies.session_timeout_minutes IS 'Session timeout duration in minutes';
COMMENT ON COLUMN public.companies.dpa_accepted IS 'Data Processing Agreement acceptance status';
COMMENT ON COLUMN public.companies.msa_accepted IS 'Master Service Agreement acceptance status';
COMMENT ON COLUMN public.companies.privacy_policy_accepted IS 'Privacy policy acceptance status';
COMMENT ON COLUMN public.companies.biometric_consent IS 'Consent for biometric data storage (fingerprint scanners)';
COMMENT ON COLUMN public.companies.gps_consent IS 'Consent for GPS data storage for attendance tracking';
COMMENT ON COLUMN public.companies.direct_debit_authorized IS 'Authorization for direct debit for payroll tax collection';
COMMENT ON COLUMN public.admin_users.system_role IS 'System role for access control (super_admin, payroll_manager, hr, view_only)';
COMMENT ON COLUMN public.admin_users.is_primary_contact IS 'Whether this admin is the primary contact for the company';