-- =============================================================================
-- COMPLETE METOSYNC ONBOARDING MIGRATION
-- Run this entire script in Supabase SQL Editor to set up the complete onboarding system
-- =============================================================================

-- =============================================================================
-- STEP 0: ENABLE REQUIRED EXTENSIONS
-- =============================================================================

-- Enable pgcrypto extension for random byte generation
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =============================================================================
-- STEP 1: CREATE ONBOARDING INVITES TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.onboarding_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'used', 'expired', 'revoked')),
  metadata jsonb DEFAULT '{}'::jsonb
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS onboarding_invites_code_idx ON public.onboarding_invites(code);
CREATE INDEX IF NOT EXISTS onboarding_invites_status_idx ON public.onboarding_invites(status);
CREATE INDEX IF NOT EXISTS onboarding_invites_expires_at_idx ON public.onboarding_invites(expires_at);
CREATE INDEX IF NOT EXISTS onboarding_invites_company_id_idx ON public.onboarding_invites(company_id);

-- Add RLS (Row Level Security)
ALTER TABLE public.onboarding_invites ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "Authenticated users can view invites" ON public.onboarding_invites;
DROP POLICY IF EXISTS "Service role can manage invites" ON public.onboarding_invites;
DROP POLICY IF EXISTS "Platform admins can create invites" ON public.onboarding_invites;

-- Create policy for authenticated users to view invites
CREATE POLICY "Authenticated users can view invites" 
ON public.onboarding_invites FOR SELECT 
USING (auth.role() = 'authenticated');

-- Create policy for platform admins to create invites
CREATE POLICY "Platform admins can create invites" 
ON public.onboarding_invites FOR INSERT 
WITH CHECK (
  auth.role() = 'authenticated' 
  AND EXISTS (
    SELECT 1 FROM public.admin_users 
    WHERE admin_users.id = auth.uid() 
    AND admin_users.system_role = 'super_admin'
  )
);

-- Create policy for service role to manage invites
CREATE POLICY "Service role can manage invites" 
ON public.onboarding_invites FOR ALL 
USING (auth.role() = 'service_role');

-- Add comments for documentation
COMMENT ON TABLE public.onboarding_invites IS 'Stores invite codes for company onboarding process';
COMMENT ON COLUMN public.onboarding_invites.code IS 'Unique invite code for onboarding';
COMMENT ON COLUMN public.onboarding_invites.company_id IS 'Reference to the company created using this invite';
COMMENT ON COLUMN public.onboarding_invites.created_by IS 'User who created the invite';
COMMENT ON COLUMN public.onboarding_invites.expires_at IS 'Expiration date for the invite code';
COMMENT ON COLUMN public.onboarding_invites.used_at IS 'Timestamp when the invite was used';
COMMENT ON COLUMN public.onboarding_invites.status IS 'Current status of the invite (active, used, expired, revoked)';
COMMENT ON COLUMN public.onboarding_invites.metadata IS 'Additional metadata about the invite';

-- =============================================================================
-- STEP 2: CREATE ONBOARDING INVITE FUNCTIONS
-- =============================================================================

-- Drop existing functions if they exist
DROP FUNCTION IF EXISTS public.check_onboarding_invite(text);
DROP FUNCTION IF EXISTS public.create_onboarding_invite();

-- Create function to generate new invite codes
CREATE OR REPLACE FUNCTION public.create_onboarding_invite()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text;
  v_exists boolean;
  v_attempts integer := 0;
  v_random_part text;
BEGIN
  -- Generate a unique invite code with retry logic
  LOOP
    v_attempts := v_attempts + 1;
    IF v_attempts > 10 THEN
      RAISE EXCEPTION 'Failed to generate unique invite code after 10 attempts';
    END IF;
    
    -- Generate random part using md5 hash as fallback
    BEGIN
      v_random_part := upper(substring(encode(gen_random_bytes(3), 'hex'), 1, 6));
    EXCEPTION WHEN undefined_function THEN
      -- Fallback to md5 hash if gen_random_bytes is not available
      v_random_part := upper(substring(md5(random()::text || now()::text), 1, 6));
    END;
    
    -- Generate code: METO-YYYY-XXXXXX
    v_code := 'METO-' || to_char(now(), 'YYYY') || '-' || v_random_part;
    
    -- Check if code already exists
    SELECT EXISTS (
      SELECT 1 FROM public.onboarding_invites 
      WHERE code = v_code
    ) INTO v_exists;
    
    -- If code is unique, exit the loop
    IF NOT v_exists THEN
      EXIT;
    END IF;
  END LOOP;
  
  -- Insert the new invite
  INSERT INTO public.onboarding_invites (
    code,
    status,
    expires_at,
    created_at
  ) VALUES (
    v_code,
    'active',
    now() + interval '30 days', -- Valid for 30 days
    now()
  );
  
  RETURN v_code;
END;
$$;

-- Create function to validate invite codes
CREATE OR REPLACE FUNCTION public.check_onboarding_invite(p_code text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  -- For testing: accept any code that starts with "METO-" if no invites exist
  -- Otherwise validate against the invites table
  SELECT EXISTS (
    SELECT 1 FROM public.onboarding_invites
    WHERE code = trim(p_code)
      AND status = 'active'
      AND used_at IS NULL
      AND expires_at > now()
  ) OR (
    NOT EXISTS (SELECT 1 FROM public.onboarding_invites)
    AND trim(p_code) ~ '^METO-'
  );
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.create_onboarding_invite TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_onboarding_invite TO anon, authenticated;

-- =============================================================================
-- STEP 3: ADD ONBOARDING FIELDS TO EXISTING TABLES
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

-- Add payroll configuration fields
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS payroll_frequency text DEFAULT 'monthly' CHECK (payroll_frequency IN ('monthly', 'bi-weekly', 'weekly'));
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS payroll_start_date date;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS payroll_end_date date;
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS compensation_components text[] DEFAULT ARRAY['Base salary']::text[];
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS earning_types text[] DEFAULT ARRAY['Base salary']::text[];

-- Add billing and subscription fields
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS subscription_plan text DEFAULT 'trial' CHECK (subscription_plan IN ('trial', 'starter', 'professional', 'enterprise'));
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS payment_method text CHECK (payment_method IN ('cash', 'mobile_money', 'bank_transfer'));
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS subscription_start_date date DEFAULT now();
ALTER TABLE public.companies ADD COLUMN IF NOT EXISTS subscription_status text DEFAULT 'active' CHECK (subscription_status IN ('active', 'past_due', 'cancelled', 'trial'));

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
COMMENT ON COLUMN public.companies.payroll_frequency IS 'Payroll processing frequency (monthly, bi-weekly, weekly)';
COMMENT ON COLUMN public.companies.payroll_start_date IS 'Start date for first payroll period';
COMMENT ON COLUMN public.companies.payroll_end_date IS 'End date for first payroll period';
COMMENT ON COLUMN public.companies.compensation_components IS 'Array of compensation components for payroll calculation';
COMMENT ON COLUMN public.companies.earning_types IS 'Array of earning types (base salary, hourly wage, overtime, bonuses, commissions)';
COMMENT ON COLUMN public.companies.subscription_plan IS 'Selected subscription plan (trial, starter, professional, enterprise)';
COMMENT ON COLUMN public.companies.payment_method IS 'Payment method for software subscription (cash, mobile_money, bank_transfer)';
COMMENT ON COLUMN public.companies.subscription_start_date IS 'Start date for subscription period';
COMMENT ON COLUMN public.companies.subscription_status IS 'Current subscription status (active, past_due, cancelled, trial)';
COMMENT ON COLUMN public.admin_users.system_role IS 'System role for access control (super_admin, payroll_manager, hr, view_only)';
COMMENT ON COLUMN public.admin_users.is_primary_contact IS 'Whether this admin is the primary contact for the company';

-- =============================================================================
-- STEP 4: CREATE SECONDARY ADMIN FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION public.create_secondary_admin(
  p_company_id uuid,
  p_title text,
  p_first_name text,
  p_surname text,
  p_other_names text,
  p_position text,
  p_mobile text,
  p_email text,
  p_system_role text DEFAULT 'hr',
  p_is_primary_contact boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid;
  v_user_id uuid;
BEGIN
  -- Get the user ID from the current auth session
  -- This assumes the secondary admin was just created via auth.signUp
  -- and we need to link them to the company
  
  -- First, try to get the user ID from the current session
  -- If that doesn't work, we'll need to handle this differently
  SELECT auth.uid() INTO v_user_id;
  
  IF v_user_id IS NULL THEN
    -- If no current session, we need to find the user by email
    -- This is a fallback approach
    SELECT id INTO v_user_id 
    FROM auth.users 
    WHERE email = p_email 
    LIMIT 1;
  END IF;
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User not found for email: %', p_email;
  END IF;
  
  -- Create the admin user record
  INSERT INTO public.admin_users (
    id,
    company_id,
    title,
    first_name,
    surname,
    other_names,
    full_name,
    position,
    mobile,
    system_role,
    is_primary_contact,
    created_at
  ) VALUES (
    v_user_id,
    p_company_id,
    p_title,
    p_first_name,
    p_surname,
    p_other_names,
    trim(coalesce(p_title, '') || ' ' || p_first_name || ' ' || coalesce(p_other_names, '') || ' ' || p_surname),
    p_position,
    p_mobile,
    p_system_role,
    p_is_primary_contact,
    now()
  )
  ON CONFLICT (id) DO UPDATE SET
    company_id = EXCLUDED.company_id,
    title = EXCLUDED.title,
    first_name = EXCLUDED.first_name,
    surname = EXCLUDED.surname,
    other_names = EXCLUDED.other_names,
    full_name = trim(coalesce(EXCLUDED.title, '') || ' ' || EXCLUDED.first_name || ' ' || coalesce(EXCLUDED.other_names, '') || ' ' || EXCLUDED.surname),
    position = EXCLUDED.position,
    mobile = EXCLUDED.mobile,
    system_role = EXCLUDED.system_role,
    is_primary_contact = EXCLUDED.is_primary_contact;
  
  RETURN v_user_id;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.create_secondary_admin TO authenticated;

-- =============================================================================
-- STEP 5: UPDATE CREATE_COMPANY_AND_OWNER FUNCTION
-- =============================================================================

-- Drop ALL versions of the function to avoid ambiguity
DO $$
DECLARE
    func_record RECORD;
BEGIN
    -- Drop all functions named create_company_and_owner regardless of parameters
    FOR func_record IN 
        SELECT pg_proc.oid 
        FROM pg_proc 
        JOIN pg_namespace ON pg_proc.pronamespace = pg_namespace.oid 
        WHERE pg_namespace.nspname = 'public' 
        AND pg_proc.proname = 'create_company_and_owner'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS public.create_company_and_owner(%s)', 
            pg_get_function_identity_arguments(func_record.oid));
    END LOOP;
END $$;

-- Also drop the secondary admin function to update it
DROP FUNCTION IF EXISTS public.create_secondary_admin(
  uuid, text, text, text, text, text, text, text, text, boolean
);

-- Create the new version with all parameters
CREATE OR REPLACE FUNCTION public.create_company_and_owner(
  p_company_name text,
  p_invite_code text,
  p_title text,
  p_first_name text,
  p_surname text,
  p_other_names text,
  p_admin_name text,
  p_position text,
  p_mobile text,
  p_country text,
  p_address text,
  p_city text,
  p_state text,
  p_terms_accepted boolean,
  -- New organizational parameters
  p_business_type text DEFAULT NULL,
  p_employee_count_range text DEFAULT NULL,
  p_zip_code text DEFAULT NULL,
  p_timezone text DEFAULT 'Africa/Accra',
  p_date_format text DEFAULT 'DD/MM/YYYY',
  p_session_timeout_minutes integer DEFAULT 15,
  p_service_tier text DEFAULT 'attendance_and_payroll',
  p_leave_policy_annual_days integer DEFAULT 20,
  p_leave_policy_sick_rate numeric DEFAULT 0.5,
  -- Compliance parameters
  p_dpa_accepted boolean DEFAULT false,
  p_msa_accepted boolean DEFAULT false,
  p_privacy_policy_accepted boolean DEFAULT false,
  p_biometric_consent boolean DEFAULT false,
  p_gps_consent boolean DEFAULT false,
  p_direct_debit_authorized boolean DEFAULT false,
  -- Payroll configuration parameters
  p_payroll_frequency text DEFAULT 'monthly',
  p_payroll_start_date date DEFAULT NULL,
  p_payroll_end_date date DEFAULT NULL,
  p_compensation_components text[] DEFAULT ARRAY['Base salary']::text[],
  p_earning_types text[] DEFAULT ARRAY['Base salary']::text[],
  -- Billing and subscription parameters
  p_subscription_plan text DEFAULT 'trial',
  p_payment_method text DEFAULT 'cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_invite_record public.onboarding_invites%rowtype;
  v_company_id uuid;
  v_admin_id uuid;
  v_user_id uuid;
  v_org_code text;
  v_result jsonb;
BEGIN
  -- Validate invite code (with fallback for testing)
  BEGIN
    SELECT * INTO v_invite_record
    FROM public.onboarding_invites
    WHERE code = trim(p_invite_code)
      AND status = 'active'
      AND used_at IS NULL
      AND expires_at > now()
    FOR UPDATE;

    -- If no invite found, check if we should allow it for testing
    IF v_invite_record.id IS NULL THEN
      -- Allow if no invites exist in the table (testing mode)
      IF NOT EXISTS (SELECT 1 FROM public.onboarding_invites) THEN
        -- Create a temporary invite for this code
        INSERT INTO public.onboarding_invites (
          code,
          status,
          expires_at,
          created_at
        ) VALUES (
          trim(p_invite_code),
          'active',
          now() + interval '30 days',
          now()
        ) RETURNING * INTO v_invite_record;
      ELSE
        RAISE EXCEPTION 'Invalid or expired invite code';
      END IF;
    END IF;
  EXCEPTION WHEN undefined_table THEN
    -- If onboarding_invites table doesn't exist, skip validation
    -- This allows the function to work during migration
    NULL;
  END;

  -- Generate organization code
  BEGIN
    v_org_code := 'METO-' || to_char(now(), 'YYYY') || '-' || upper(substring(encode(gen_random_bytes(4), 'hex'), 1, 8));
  EXCEPTION WHEN undefined_function THEN
    -- Fallback to md5 hash if gen_random_bytes is not available
    v_org_code := 'METO-' || to_char(now(), 'YYYY') || '-' || upper(substring(md5(random()::text || now()::text), 1, 8));
  END;

  -- Get current user ID from auth session
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No authenticated user found';
  END IF;

  -- Create company
  INSERT INTO public.companies (
    name,
    org_code,
    status,
    country,
    address,
    city,
    state,
    zip_code,
    default_currency,
    business_type,
    employee_count_range,
    timezone,
    date_format,
    currency_symbol_placement,
    session_timeout_minutes,
    service_tier,
    leave_policy_annual_days,
    leave_policy_sick_rate,
    dpa_accepted,
    msa_accepted,
    privacy_policy_accepted,
    biometric_consent,
    gps_consent,
    direct_debit_authorized,
    payroll_frequency,
    payroll_start_date,
    payroll_end_date,
    compensation_components,
    earning_types,
    subscription_plan,
    payment_method,
    subscription_start_date,
    subscription_status,
    created_at
  ) VALUES (
    p_company_name,
    v_org_code,
    'active',
    p_country,
    p_address,
    p_city,
    p_state,
    p_zip_code,
    'GHS',
    p_business_type,
    p_employee_count_range,
    p_timezone,
    p_date_format,
    'before',
    p_session_timeout_minutes,
    p_service_tier,
    p_leave_policy_annual_days,
    p_leave_policy_sick_rate,
    p_dpa_accepted,
    p_msa_accepted,
    p_privacy_policy_accepted,
    p_biometric_consent,
    p_gps_consent,
    p_direct_debit_authorized,
    p_payroll_frequency,
    p_payroll_start_date,
    p_payroll_end_date,
    p_compensation_components,
    p_earning_types,
    p_subscription_plan,
    p_payment_method,
    now(),
    'active',
    now()
  )
  RETURNING id INTO v_company_id;

  -- Create admin user
  INSERT INTO public.admin_users (
    id,
    company_id,
    title,
    first_name,
    surname,
    other_names,
    full_name,
    position,
    mobile,
    system_role,
    is_primary_contact,
    created_at
  ) VALUES (
    v_user_id,
    v_company_id,
    p_title,
    p_first_name,
    p_surname,
    p_other_names,
    trim(coalesce(p_title, '') || ' ' || p_first_name || ' ' || coalesce(p_other_names, '') || ' ' || p_surname),
    p_position,
    p_mobile,
    'super_admin',
    true,
    now()
  )
  ON CONFLICT (id) DO UPDATE SET
    company_id = EXCLUDED.company_id,
    title = EXCLUDED.title,
    first_name = EXCLUDED.first_name,
    surname = EXCLUDED.surname,
    other_names = EXCLUDED.other_names,
    full_name = trim(coalesce(EXCLUDED.title, '') || ' ' || EXCLUDED.first_name || ' ' || coalesce(EXCLUDED.other_names, '') || ' ' || EXCLUDED.surname),
    position = EXCLUDED.position,
    mobile = EXCLUDED.mobile,
    system_role = EXCLUDED.system_role,
    is_primary_contact = EXCLUDED.is_primary_contact;

  -- Mark invite as used (only if table exists and invite was found)
  IF v_invite_record.id IS NOT NULL THEN
    UPDATE public.onboarding_invites
    SET used_at = now(),
        company_id = v_company_id,
        status = 'used'
    WHERE id = v_invite_record.id;
  END IF;

  -- Return result
  v_result := jsonb_build_object(
    'success', true,
    'company_id', v_company_id,
    'admin_id', v_user_id,
    'org_code', v_org_code,
    'company_name', p_company_name
  );

  RETURN v_result;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.create_company_and_owner TO authenticated;

-- =============================================================================
-- MIGRATION COMPLETE
-- =============================================================================
-- Your Metosync onboarding system is now ready!
-- Test it by visiting: http://127.0.0.1:8000/welcome.html
-- =============================================================================