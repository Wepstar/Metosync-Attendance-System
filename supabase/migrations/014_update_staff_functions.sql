-- Update staff check-in/out/location RPCs to accept geofence, spoof, offline, and device-binding parameters.

-- Ensure required tables exist (defensive, in case 010-013 are not yet applied).
CREATE TABLE IF NOT EXISTS public.staff_login_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.staff_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

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

-- Update staff_verify_pin to accept device fingerprint and return geofence + device status.
CREATE OR REPLACE FUNCTION public.staff_verify_pin(
  p_challenge_token text,
  p_pin text,
  p_device_fingerprint text DEFAULT NULL
)
RETURNS TABLE (
  session_token text,
  session_expires_at timestamptz,
  staff_id uuid,
  full_name text,
  company_id uuid,
  site_id uuid,
  already_checked_in boolean,
  site_latitude numeric,
  site_longitude numeric,
  geofence_radius_meters integer,
  device_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
declare
  challenge public.staff_login_challenges%rowtype;
  staff_row public.staff%rowtype;
  site_row public.sites%rowtype;
  raw_session text;
  session_expiry timestamptz := now() + interval '12 hours';
  v_device_status text;
begin
  select * into challenge
  from public.staff_login_challenges
  where token_hash = encode(digest(p_challenge_token, 'sha256'), 'hex')
    and used_at is null
    and expires_at > now()
  for update;

  if challenge.id is null then
    raise exception 'Invalid or expired login attempt';
  end if;

  select * into staff_row from public.staff where id = challenge.staff_id and status = 'active';
  if staff_row.id is null or staff_row.pin_hash is null or crypt(p_pin, staff_row.pin_hash) <> staff_row.pin_hash then
    raise exception 'Invalid phone number or PIN';
  end if;

  -- device binding decision
  if p_device_fingerprint is null then
    v_device_status := 'trusted';
  elsif staff_row.device_fingerprint is null then
    update public.staff set device_fingerprint = p_device_fingerprint, device_approved_at = now()
    where id = staff_row.id;
    v_device_status := 'trusted';
  elsif staff_row.device_fingerprint = p_device_fingerprint then
    v_device_status := 'trusted';
  elsif staff_row.pending_device_fingerprint is not null and staff_row.pending_device_fingerprint = p_device_fingerprint then
    v_device_status := 'pending';
  else
    update public.staff set pending_device_fingerprint = p_device_fingerprint
    where id = staff_row.id;
    v_device_status := 'unrecognized';
  end if;

  update public.staff_login_challenges set used_at = now() where id = challenge.id;
  delete from public.staff_sessions as ss where ss.staff_id = staff_row.id and ss.expires_at <= now();
  raw_session := encode(gen_random_bytes(32), 'hex');
  insert into public.staff_sessions (staff_id, token_hash, expires_at)
  values (staff_row.id, encode(digest(raw_session, 'sha256'), 'hex'), session_expiry);

  select * into site_row from public.sites where id = staff_row.site_id;

  return query
  select raw_session, session_expiry, staff_row.id, staff_row.full_name, staff_row.company_id,
         staff_row.site_id,
         exists (
           select 1 from public.attendance a
           where a.staff_id = staff_row.id and a.work_date = current_date and a.check_in is not null and a.check_out is null
         ),
         site_row.latitude,
         site_row.longitude,
         site_row.geofence_radius_meters,
         v_device_status;
end;
$$;

-- Update staff_check_in to accept accuracy, timestamps, spoof, offline, fingerprint.
CREATE OR REPLACE FUNCTION public.staff_check_in(
  p_session_token text,
  p_latitude numeric,
  p_longitude numeric,
  p_accuracy_meters numeric DEFAULT NULL,
  p_device_timestamp timestamptz DEFAULT NULL,
  p_is_offline_sync boolean DEFAULT false,
  p_device_fingerprint text DEFAULT NULL,
  p_spoof_score integer DEFAULT NULL,
  p_spoof_flags text[] DEFAULT NULL
)
RETURNS public.attendance
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
declare
  current_staff public.staff%rowtype;
  result_row public.attendance%rowtype;
  v_check_in timestamptz;
begin
  select s.* into current_staff from public.staff s where s.id = public.staff_session_id(p_session_token) and s.status = 'active';
  if current_staff.id is null then raise exception 'Session expired'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Invalid GPS coordinates'; end if;
  if exists (select 1 from public.attendance a where a.staff_id = current_staff.id and a.work_date = current_date and a.check_in is not null and a.check_out is null) then
    raise exception 'You are already checked in';
  end if;

  v_check_in := coalesce(p_device_timestamp, now());

  insert into public.attendance (
    company_id, site_id, staff_id, work_date, status, check_in, source,
    check_in_latitude, check_in_longitude, accuracy_meters,
    device_timestamp, server_timestamp, is_offline_sync,
    device_fingerprint, spoof_score, spoof_flags
  )
  values (
    current_staff.company_id, current_staff.site_id, current_staff.id, current_date, 'present', v_check_in, 'staff',
    p_latitude, p_longitude, p_accuracy_meters,
    v_check_in, now(), p_is_offline_sync,
    p_device_fingerprint, p_spoof_score, p_spoof_flags
  )
  on conflict (staff_id, work_date) do nothing
  returning * into result_row;
  if result_row.id is null then raise exception 'Attendance already recorded for today'; end if;
  return result_row;
end;
$$;

-- Update staff_check_out similarly.
CREATE OR REPLACE FUNCTION public.staff_check_out(
  p_session_token text,
  p_latitude numeric,
  p_longitude numeric,
  p_accuracy_meters numeric DEFAULT NULL,
  p_device_timestamp timestamptz DEFAULT NULL,
  p_is_offline_sync boolean DEFAULT false,
  p_device_fingerprint text DEFAULT NULL,
  p_spoof_score integer DEFAULT NULL,
  p_spoof_flags text[] DEFAULT NULL
)
RETURNS public.attendance
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
declare
  current_staff uuid := public.staff_session_id(p_session_token);
  result_row public.attendance%rowtype;
  v_check_out timestamptz;
begin
  if current_staff is null then raise exception 'Session expired'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Invalid GPS coordinates'; end if;
  v_check_out := coalesce(p_device_timestamp, now());
  update public.attendance as a
  set check_out = v_check_out,
      total_hours = round((extract(epoch from (v_check_out - check_in)) / 3600)::numeric, 2),
      source = 'staff', check_out_latitude = p_latitude, check_out_longitude = p_longitude,
      accuracy_meters = coalesce(a.accuracy_meters, p_accuracy_meters),
      device_timestamp = coalesce(a.device_timestamp, v_check_out),
      server_timestamp = now(),
      is_offline_sync = coalesce(a.is_offline_sync, p_is_offline_sync),
      device_fingerprint = coalesce(a.device_fingerprint, p_device_fingerprint),
      spoof_score = coalesce(a.spoof_score, p_spoof_score),
      spoof_flags = coalesce(a.spoof_flags, p_spoof_flags),
      updated_at = now()
  where a.staff_id = current_staff and a.work_date = current_date and a.check_in is not null and a.check_out is null
  returning * into result_row;
  if result_row.id is null then raise exception 'No active check-in found'; end if;
  return result_row;
end;
$$;

-- Staff-initiated location ping for Location Checker.
CREATE OR REPLACE FUNCTION public.staff_location_check(
  p_session_token text,
  p_latitude numeric,
  p_longitude numeric,
  p_accuracy_meters numeric DEFAULT NULL,
  p_device_fingerprint text DEFAULT NULL,
  p_spoof_score integer DEFAULT NULL,
  p_spoof_flags text[] DEFAULT NULL
)
RETURNS public.location_verifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
declare
  current_staff public.staff%rowtype;
  result_row public.location_verifications%rowtype;
begin
  select s.* into current_staff from public.staff s where s.id = public.staff_session_id(p_session_token) and s.status = 'active';
  if current_staff.id is null then raise exception 'Session expired'; end if;
  insert into public.location_verifications (
    staff_id, latitude, longitude, result, accuracy_meters, spoof_score, spoof_flags, device_fingerprint
  )
  values (
    current_staff.id, p_latitude, p_longitude, 'captured', p_accuracy_meters, p_spoof_score, p_spoof_flags, p_device_fingerprint
  )
  returning * into result_row;
  return result_row;
end;
$$;

-- Device approval request from staff.
CREATE OR REPLACE FUNCTION public.staff_request_device_approval(
  p_session_token text,
  p_device_fingerprint text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
declare
  current_staff uuid;
begin
  current_staff := public.staff_session_id(p_session_token);
  if current_staff is null then raise exception 'Session expired'; end if;
  update public.staff set pending_device_fingerprint = p_device_fingerprint where id = current_staff;
end;
$$;

-- Admin approves a pending device fingerprint.
CREATE OR REPLACE FUNCTION public.admin_approve_device(
  p_staff_id uuid,
  p_device_fingerprint text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  update public.staff
  set device_fingerprint = p_device_fingerprint,
      pending_device_fingerprint = NULL,
      device_approved_at = now()
  where id = p_staff_id;

  insert into public.trusted_devices (staff_id, fingerprint)
  values (p_staff_id, p_device_fingerprint)
  on conflict (staff_id, fingerprint) do nothing;
end;
$$;

-- Admin requests/reads latest staff location.
-- Pushes a real-time location-check notification to the staff member.
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
  -- Notify the staff device immediately.
  insert into public.staff_notifications (staff_id, company_id, notification_type, title, message)
  values (p_staff_id, p_company_id, 'location_check_request', 'Location check requested', 'Your employer has asked you to verify your current location. Tap to share it now.');

  -- Return the most recent verified location if it exists.
  select lv.* into latest
  from public.location_verifications lv
  join public.staff s on s.id = lv.staff_id
  where lv.staff_id = p_staff_id and s.company_id = p_company_id
  order by lv.verified_at desc
  limit 1;

  return latest;
end;
$$;

-- Admin notifications broadcast.
CREATE OR REPLACE FUNCTION public.admin_send_notification(
  p_company_id uuid,
  p_staff_id uuid DEFAULT NULL,
  p_title text DEFAULT '',
  p_message text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  if p_staff_id is null then
    insert into public.staff_notifications (staff_id, company_id, notification_type, title, message)
    select id, p_company_id, 'admin_broadcast', p_title, p_message
    from public.staff
    where company_id = p_company_id and status = 'active';
  else
    insert into public.staff_notifications (staff_id, company_id, notification_type, title, message)
    values (p_staff_id, p_company_id, 'admin_direct', p_title, p_message);
  end if;
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_notifications(
  p_company_id uuid,
  p_limit integer DEFAULT 20
)
RETURNS SETOF public.staff_notifications
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select n.*
  from public.staff_notifications n
  join public.staff s on s.id = n.staff_id
  where s.company_id = p_company_id
  order by n.created_at desc
  limit p_limit;
$$;

-- Update grants for new signatures.
GRANT EXECUTE ON FUNCTION public.staff_verify_pin(text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_check_in(text, numeric, numeric, numeric, timestamptz, boolean, text, integer, text[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_check_out(text, numeric, numeric, numeric, timestamptz, boolean, text, integer, text[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_location_check(text, numeric, numeric, numeric, text, integer, text[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_request_device_approval(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_approve_device(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_request_location_check(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_notification(uuid, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_notifications(uuid, integer) TO authenticated;
