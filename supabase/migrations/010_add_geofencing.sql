-- Geofencing support for staff check-in/out
-- Adds geofence radius to sites and geofence metadata to attendance records.

-- Allow site-level geofence radius (meters). Default 100 m.
ALTER TABLE public.sites
ADD COLUMN IF NOT EXISTS geofence_radius_meters integer NOT NULL DEFAULT 100
CHECK (geofence_radius_meters > 0 AND geofence_radius_meters <= 5000);

-- Capture GPS accuracy and geofence outcome on attendance records.
ALTER TABLE public.attendance_records
ADD COLUMN IF NOT EXISTS accuracy_meters numeric,
ADD COLUMN IF NOT EXISTS geofence_distance_meters numeric,
ADD COLUMN IF NOT EXISTS geofence_status text CHECK (geofence_status IN ('inside', 'outside', 'unknown'));

-- Helper: return distance between a GPS point and a site, plus inside/outside status.
CREATE OR REPLACE FUNCTION public.check_staff_geofence(
  p_site_id uuid,
  p_latitude numeric,
  p_longitude numeric
)
RETURNS TABLE(distance_meters numeric, status text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ROUND(
      6371000 * 2 * ASIN(
        SQRT(
          POWER(SIN(RADIANS((p_latitude - s.latitude) / 2)), 2)
          + COS(RADIANS(s.latitude)) * COS(RADIANS(p_latitude))
          * POWER(SIN(RADIANS((p_longitude - s.longitude) / 2)), 2)
        )
      )::numeric,
      2
    ) AS distance_meters,
    CASE
      WHEN s.latitude IS NULL OR s.longitude IS NULL THEN 'unknown'
      WHEN 6371000 * 2 * ASIN(
        SQRT(
          POWER(SIN(RADIANS((p_latitude - s.latitude) / 2)), 2)
          + COS(RADIANS(s.latitude)) * COS(RADIANS(p_latitude))
          * POWER(SIN(RADIANS((p_longitude - s.longitude) / 2)), 2)
        )
      ) <= s.geofence_radius_meters THEN 'inside'
      ELSE 'outside'
    END AS status
  FROM public.sites s
  WHERE s.id = p_site_id;
$$;

GRANT EXECUTE ON FUNCTION public.check_staff_geofence TO authenticated;

-- NOTE: Update your existing staff_check_in RPC to call check_staff_geofence(site_id, lat, lon)
-- and reject the check-in when status = 'outside' unless the site has no GPS set (status = 'unknown').
-- Example condition inside staff_check_in:
--   IF site_id IS NOT NULL THEN
--     SELECT status INTO v_geo_status FROM check_staff_geofence(site_id, p_latitude, p_longitude);
--     IF v_geo_status = 'outside' THEN
--       RAISE EXCEPTION 'You are outside the allowed check-in area.';
--     END IF;
--   END IF;
