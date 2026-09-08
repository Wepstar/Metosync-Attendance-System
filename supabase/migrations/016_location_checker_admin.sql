-- Admin Location Checker improvements: mass request and results table.

-- Ensure base table exists (defensive).
CREATE TABLE IF NOT EXISTS public.location_verifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  latitude numeric,
  longitude numeric,
  verified_at timestamptz NOT NULL DEFAULT now(),
  result text,
  accuracy_meters numeric,
  spoof_score integer,
  spoof_flags text[],
  device_fingerprint text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.staff_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  notification_type text NOT NULL,
  title text NOT NULL,
  message text NOT NULL,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Request a location check for one staff member.
CREATE OR REPLACE FUNCTION public.admin_request_location_check(
  p_staff_id uuid,
  p_company_id uuid
)
RETURNS public.location_verifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  latest public.location_verifications%rowtype;
begin
  insert into public.staff_notifications (staff_id, company_id, notification_type, title, message)
  values (p_staff_id, p_company_id, 'location_check_request', 'Location check requested', 'Your employer has asked you to verify your current location. Tap to share it now.');

  select lv.* into latest
  from public.location_verifications lv
  join public.staff s on s.id = lv.staff_id
  where lv.staff_id = p_staff_id and s.company_id = p_company_id
  order by lv.verified_at desc
  limit 1;

  return latest;
end;
$$;

-- Request a location check for every active staff member in a company.
CREATE OR REPLACE FUNCTION public.admin_request_location_for_all(
  p_company_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_count integer;
begin
  insert into public.staff_notifications (staff_id, company_id, notification_type, title, message)
  select id, p_company_id, 'location_check_request', 'Location check requested', 'Your employer has asked you to verify your current location. Tap to share it now.'
  from public.staff
  where company_id = p_company_id and status = 'active';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Return the latest location verification for every staff member in the company.
CREATE OR REPLACE FUNCTION public.admin_get_latest_locations(
  p_company_id uuid
)
RETURNS TABLE (
  staff_id uuid,
  full_name text,
  phone text,
  latitude numeric,
  longitude numeric,
  accuracy_meters numeric,
  verified_at timestamptz,
  site_name text,
  site_latitude numeric,
  site_longitude numeric,
  geofence_radius_meters integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    s.id,
    s.full_name,
    s.phone,
    lv.latitude,
    lv.longitude,
    lv.accuracy_meters,
    lv.verified_at,
    si.name,
    si.latitude,
    si.longitude,
    si.geofence_radius_meters
  from public.staff s
  left join lateral (
    select *
    from public.location_verifications l
    where l.staff_id = s.id
    order by l.verified_at desc
    limit 1
  ) lv on true
  left join public.sites si on si.id = s.site_id
  where s.company_id = p_company_id and s.status = 'active'
  order by s.full_name;
$$;

GRANT EXECUTE ON FUNCTION public.admin_request_location_check(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_request_location_for_all(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_latest_locations(uuid) TO authenticated;
