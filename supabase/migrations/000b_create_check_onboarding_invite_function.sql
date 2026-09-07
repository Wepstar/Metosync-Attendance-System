-- =============================================================================
-- CREATE CHECK ONBOARDING INVITE FUNCTION
-- RPC function to validate invite codes for onboarding
-- =============================================================================

-- Drop existing function if it exists
DROP FUNCTION IF EXISTS public.check_onboarding_invite(text);

CREATE OR REPLACE FUNCTION public.check_onboarding_invite(p_code text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.onboarding_invites
    WHERE code = trim(p_code)
      AND status = 'active'
      AND used_at IS NULL
      AND expires_at > now()
  );
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.check_onboarding_invite TO anon, authenticated;