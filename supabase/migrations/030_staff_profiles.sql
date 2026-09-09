-- Phase: Staff profiles with photo and extended details.

-- Add photo and profile columns to staff.
ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS photo_url text,
  ADD COLUMN IF NOT EXISTS profile jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Storage bucket for staff photos.
INSERT INTO storage.buckets (id, name, public)
VALUES ('staff-photos', 'staff-photos', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for authenticated users.
CREATE POLICY IF NOT EXISTS "Allow authenticated select on staff-photos"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'staff-photos');

CREATE POLICY IF NOT EXISTS "Allow authenticated insert on staff-photos"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'staff-photos');

CREATE POLICY IF NOT EXISTS "Allow authenticated delete on staff-photos"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'staff-photos');

-- Update staff profile (admin use).
CREATE OR REPLACE FUNCTION public.update_staff_profile(
  p_staff_id uuid,
  p_full_name text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_photo_url text DEFAULT NULL,
  p_site_id uuid DEFAULT NULL,
  p_profile jsonb DEFAULT NULL
)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.staff%rowtype;
  v_profile jsonb;
begin
  select profile into v_profile from public.staff where id = p_staff_id;
  if not found then raise exception 'Staff not found.'; end if;

  update public.staff set
    full_name = coalesce(p_full_name, full_name),
    phone = coalesce(p_phone, phone),
    photo_url = coalesce(p_photo_url, photo_url),
    site_id = coalesce(p_site_id, site_id),
    department = coalesce((p_profile->>'department'), department),
    role = coalesce((p_profile->>'role'), role),
    staff_code = coalesce((p_profile->>'staff_code'), staff_code),
    status = coalesce((p_profile->>'status'), status),
    profile = case when p_profile is not null then v_profile || p_profile else v_profile end
  where id = p_staff_id
  returning * into v_row;
  return v_row;
end;
$$;

GRANT EXECUTE ON FUNCTION public.update_staff_profile(uuid, text, text, text, uuid, jsonb) TO authenticated;

-- Create a staff with profile/photo support.
CREATE OR REPLACE FUNCTION public.create_staff(p_staff jsonb)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.staff%rowtype;
  v_company_id uuid := (p_staff->>'company_id')::uuid;
  v_site_id uuid := (p_staff->>'site_id')::uuid;
begin
  insert into public.staff (
    company_id, site_id, full_name, phone, staff_type, pay_type,
    weekday_rate, weekend_rate, monthly_salary, currency, pin_hash,
    department, role, staff_code, photo_url, profile, status
  ) values (
    v_company_id, v_site_id, p_staff->>'full_name', p_staff->>'phone', p_staff->>'staff_type', p_staff->>'pay_type',
    (p_staff->>'weekday_rate')::numeric, (p_staff->>'weekend_rate')::numeric, (p_staff->>'monthly_salary')::numeric,
    p_staff->>'currency', p_staff->>'pin_hash', p_staff->>'department', p_staff->>'role', p_staff->>'staff_code',
    p_staff->>'photo_url', coalesce((p_staff->'profile')::jsonb, '{}'::jsonb), coalesce(p_staff->>'status', 'active')
  )
  returning * into v_row;
  return v_row;
end;
$$;

GRANT EXECUTE ON FUNCTION public.create_staff(jsonb) TO authenticated;
