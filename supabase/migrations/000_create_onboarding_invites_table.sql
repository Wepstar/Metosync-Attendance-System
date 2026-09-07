-- =============================================================================
-- CREATE ONBOARDING INVITES TABLE
-- This table stores invite codes for company onboarding
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

-- Create policy for authenticated users to view invites
CREATE POLICY "Authenticated users can view invites" 
ON public.onboarding_invites FOR SELECT 
USING (auth.role() = 'authenticated');

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