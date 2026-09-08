-- Spoof detection and device fingerprint support.
-- Captures client-side spoof score, flags, and a stable device fingerprint for review.

-- Attendance events
ALTER TABLE public.attendance_records
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
ON public.attendance_records (company_id, spoof_score, check_in_at)
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
