-- Device binding and PIN security upgrade support.

-- Guards: create base tables if missing.
CREATE TABLE IF NOT EXISTS public.admin_users (
  id uuid PRIMARY KEY,
  company_id uuid,
  system_role text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.staff (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid,
  site_id uuid,
  full_name text NOT NULL,
  phone text,
  status text DEFAULT 'active',
  staff_type text,
  pay_type text,
  currency text,
  weekday_rate numeric,
  weekend_rate numeric,
  monthly_salary numeric,
  pin_hash text,
  device_fingerprint text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.staff_sessions (
  session_token text PRIMARY KEY,
  staff_id uuid NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Existing device_fingerprint was added by 012_spoof_detection.sql.
-- Add pending approval tracking and approval timestamp for admin workflow.
ALTER TABLE public.staff
ADD COLUMN IF NOT EXISTS pending_device_fingerprint text,
ADD COLUMN IF NOT EXISTS device_approved_at timestamptz;

-- Track trusted device fingerprints explicitly (supports multiple devices per staff in future).
CREATE TABLE IF NOT EXISTS public.trusted_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  fingerprint text NOT NULL,
  approved_at timestamptz DEFAULT now(),
  approved_by uuid REFERENCES public.admin_users(id) ON DELETE SET NULL,
  UNIQUE (staff_id, fingerprint)
);

ALTER TABLE public.trusted_devices ENABLE ROW LEVEL SECURITY;

-- Example RPC for admin to approve a device fingerprint.
-- Replace existing add_staff / staff_verify_pin integrations with your actual business logic.
CREATE OR REPLACE FUNCTION public.admin_approve_device(
  p_staff_id uuid,
  p_device_fingerprint text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.staff
  SET device_fingerprint = p_device_fingerprint,
      pending_device_fingerprint = NULL,
      device_approved_at = now()
  WHERE id = p_staff_id;

  INSERT INTO public.trusted_devices (staff_id, fingerprint)
  VALUES (p_staff_id, p_device_fingerprint)
  ON CONFLICT (staff_id, fingerprint) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_request_device_approval(
  p_session_token text,
  p_device_fingerprint text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  -- Resolve staff from session token. Replace with your actual session lookup.
  SELECT staff_id INTO v_staff_id
  FROM public.staff_sessions
  WHERE session_token = p_session_token
    AND expires_at > now();

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Session expired or invalid.';
  END IF;

  UPDATE public.staff
  SET pending_device_fingerprint = p_device_fingerprint
  WHERE id = v_staff_id;
END;
$$;

-- Update staff_verify_pin to accept device fingerprint and return device_status.
-- Expected return type additions:
--   device_status text  -- 'trusted' | 'unrecognized' | 'pending'
-- Logic:
--   IF staff.device_fingerprint IS NULL THEN
--     UPDATE staff SET device_fingerprint = p_device_fingerprint RETURNING 'trusted';
--   ELSEIF staff.device_fingerprint = p_device_fingerprint THEN
--     RETURN 'trusted';
--   ELSEIF staff.pending_device_fingerprint = p_device_fingerprint THEN
--     RETURN 'pending';
--   ELSE
--     UPDATE staff SET pending_device_fingerprint = p_device_fingerprint RETURNING 'unrecognized';
--   END IF;
