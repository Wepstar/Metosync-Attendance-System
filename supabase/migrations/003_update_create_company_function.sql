-- =============================================================================
-- UPDATE CREATE_COMPANY_AND_OWNER FUNCTION
-- Adds new parameters for comprehensive onboarding data
-- =============================================================================

-- Drop existing versions of the function to avoid ambiguity
DROP FUNCTION IF EXISTS public.create_company_and_owner(
  text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, boolean
);

DROP FUNCTION IF EXISTS public.create_company_and_owner(
  text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, boolean,
  text, text, text, text, text, integer, text, integer, numeric,
  boolean, boolean, boolean, boolean, boolean, boolean
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
  p_mobile1 text,
  p_mobile2 text,
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
  p_direct_debit_authorized boolean DEFAULT false
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
  -- Validate invite code (skip validation if table doesn't exist yet)
  BEGIN
    SELECT * INTO v_invite_record
    FROM public.onboarding_invites
    WHERE code = trim(p_invite_code)
      AND status = 'active'
      AND used_at IS NULL
      AND expires_at > now()
    FOR UPDATE;

    IF v_invite_record.id IS NULL THEN
      RAISE EXCEPTION 'Invalid or expired invite code';
    END IF;
  EXCEPTION WHEN undefined_table THEN
    -- If onboarding_invites table doesn't exist, skip validation
    -- This allows the function to work during migration
    NULL;
  END;

  -- Generate organization code
  v_org_code := 'METO-' || to_char(now(), 'YYYY') || '-' || upper(substring(encode(gen_random_bytes(4), 'hex'), 1, 8));

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
    currency,
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
    position,
    mobile,
    email,
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
    p_position,
    p_mobile1,
    (SELECT email FROM auth.users WHERE id = v_user_id),
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