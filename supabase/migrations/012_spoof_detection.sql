-- Spoof detection and device fingerprint support.
-- Captures client-side spoof score, flags, and a stable device fingerprint for review.

-- Guards: create base tables if missing.
CREATE TABLE IF NOT EXISTS public.attendance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid,
  staff_id uuid,
  site_id uuid,
  work_date date,
  status text,
  check_in timestamptz,
  check_out timestamptz,
  total_hours numeric,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.location_verifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid,
  latitude numeric,
  longitude numeric,
  verified_at timestamptz NOT NULL DEFAULT now(),
  result text,
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
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Attendance events
ALTER TABLE public.attendance
ADD COLUMN IF NOT EXISTS spoof_score integer CHECK (spoof_score BETWEEN 0 AND 100),
ADD COLUMN IF NOT EXISTS spoof_flags text[],
ADD COLUMN IF NOT EXISTS device_fingerprint text;

-- Location verification pings
ALTER TABLE public.location_verifications
ADD COLUMN IF NOT EXISTS spoof_score integer CHECK (spoof_score BETWEEN 0 AND 100),
ADD COLUMN IF NOT EXISTS spoof_flags text[],
ADD COLUMN IF NOT EXISTS device_fingerprint text,
ADD COLUMN IF NOT EXISTS accuracy_meters numeric;

-- Per-staff known/trusted device fingerprints (future device-binding)
ALTER TABLE public.staff
ADD COLUMN IF NOT EXISTS device_fingerprint text;

-- Index for admin review of suspicious attendance
CREATE INDEX IF NOT EXISTS idx_attendance_spoof
ON public.attendance (company_id, spoof_score, check_in)
WHERE spoof_score >= 30;

-- NOTE: Update your existing RPCs to accept these parameters:
--   staff_check_in / staff_check_out:
--     p_device_fingerprint text
--     p_spoof_score integer
--     p_spoof_flags text[]
--   staff_location_check:
--     p_device_fingerprint text
--     p_spoof_score integer
--     p_spoof_flags text[]
--     p_accuracy_meters numeric
--
-- Server-side recommendation:
--   - Reject check-in when spoof_score >= 80.
--   - Flag records with 30 <= spoof_score < 80 for admin review.
--   - Compare p_device_fingerprint against staff.device_fingerprint for binding.
