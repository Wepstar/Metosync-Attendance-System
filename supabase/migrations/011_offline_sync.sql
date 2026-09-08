-- Offline / low-connectivity support for attendance records.
-- Captures the original device timestamp and flags records that were delayed by poor connectivity.

ALTER TABLE public.attendance_records
ADD COLUMN IF NOT EXISTS device_timestamp timestamptz,
ADD COLUMN IF NOT EXISTS server_timestamp timestamptz DEFAULT now(),
ADD COLUMN IF NOT EXISTS is_offline_sync boolean DEFAULT false;

-- Backfill existing records so device_timestamp matches check_in_at / check_out_at.
UPDATE public.attendance_records
SET device_timestamp = COALESCE(check_in_at, check_out_at, created_at)
WHERE device_timestamp IS NULL;

-- Index for admin review of offline-synced records.
CREATE INDEX IF NOT EXISTS idx_attendance_offline_sync
ON public.attendance_records (company_id, is_offline_sync, device_timestamp)
WHERE is_offline_sync = true;

-- NOTE: Update your existing staff_check_in / staff_check_out RPCs to accept:
--   p_device_timestamp timestamptz DEFAULT NULL
--   p_is_offline_sync boolean DEFAULT false
-- and to store them in the attendance record. Server-side should still enforce
-- geofencing and session validity, but use device_timestamp as the official event
-- time for delayed-sync entries.
