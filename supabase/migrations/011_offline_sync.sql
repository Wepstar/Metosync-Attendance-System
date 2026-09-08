-- Offline / low-connectivity support for attendance records.
-- Captures the original device timestamp and flags records that were delayed by poor connectivity.

-- Guard: create attendance table if it does not exist (uses same shape as admin.html expects).
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

ALTER TABLE public.attendance
ADD COLUMN IF NOT EXISTS device_timestamp timestamptz,
ADD COLUMN IF NOT EXISTS server_timestamp timestamptz DEFAULT now(),
ADD COLUMN IF NOT EXISTS is_offline_sync boolean DEFAULT false;

-- Backfill existing records so device_timestamp matches check_in / check_out.
UPDATE public.attendance
SET device_timestamp = COALESCE(check_in, check_out, created_at)
WHERE device_timestamp IS NULL;

-- Index for admin review of offline-synced records.
CREATE INDEX IF NOT EXISTS idx_attendance_offline_sync
ON public.attendance (company_id, is_offline_sync, device_timestamp)
WHERE is_offline_sync = true;

-- NOTE: Update your existing staff_check_in / staff_check_out RPCs to accept:
--   p_device_timestamp timestamptz DEFAULT NULL
--   p_is_offline_sync boolean DEFAULT false
-- and to store them in the attendance record. Server-side should still enforce
-- geofencing and session validity, but use device_timestamp as the official event
-- time for delayed-sync entries.
