-- =============================================================================
-- CREATE SECONDARY ADMIN FUNCTION
-- RPC function to create secondary admin users (Finance Officer, Administrator, etc.)
-- =============================================================================

-- Drop existing function if it exists
DROP FUNCTION IF EXISTS public.create_secondary_admin(
  uuid, text, text, text, text, text, text, text, text, boolean
);

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
    position,
    mobile,
    email,
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
    p_position,
    p_mobile,
    p_email,
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
    position = EXCLUDED.position,
    mobile = EXCLUDED.mobile,
    email = EXCLUDED.email,
    system_role = EXCLUDED.system_role,
    is_primary_contact = EXCLUDED.is_primary_contact;
  
  RETURN v_user_id;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.create_secondary_admin TO authenticated;