-- Platform-level Watch Guard: cross-organization monitoring for the owner dashboard.

-- Ensure events table exists.
CREATE TABLE IF NOT EXISTS public.watch_guard_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid,
  severity text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  category text NOT NULL,
  message text NOT NULL,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Add watch_guard_events to realtime publication (defensive, in case not yet added).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'watch_guard_events'
  ) then
    alter publication supabase_realtime add table public.watch_guard_events;
  end if;
end;
$$;

-- Aggregated system health report across all companies.
CREATE OR REPLACE FUNCTION public.platform_watch_guard_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
declare
  v_report jsonb;
  v_total_companies integer;
  v_total_staff integer;
  v_active_sessions integer;
  v_checked_in_today integer;
  v_checked_out_today integer;
  v_absent_today integer;
  v_pending_devices integer;
  v_suspicious_attendance integer;
  v_suspicious_locations integer;
  v_geofence_violations integer;
  v_pending_notifications integer;
  v_recent_critical integer;
  v_offline_sync_count integer;
  v_failed_challenges_24h integer;
begin
  select count(*) into v_total_companies from public.companies;
  select count(*) into v_total_staff from public.staff where status = 'active';
  select count(*) into v_active_sessions from public.staff_sessions where expires_at > now();

  select count(*) into v_checked_in_today
  from public.attendance a
  where a.work_date = current_date and a.check_in is not null;

  select count(*) into v_checked_out_today
  from public.attendance a
  where a.work_date = current_date and a.check_out is not null;

  v_absent_today := greatest(v_total_staff - v_checked_in_today, 0);

  select count(*) into v_pending_devices
  from public.staff
  where status = 'active' and pending_device_fingerprint is not null;

  select count(*) into v_suspicious_attendance
  from public.attendance
  where spoof_score >= 30 or geofence_status = 'outside';

  select count(*) into v_suspicious_locations
  from public.location_verifications
  where spoof_score >= 30;

  select count(*) into v_geofence_violations
  from public.attendance
  where geofence_status = 'outside';

  select count(*) into v_pending_notifications
  from public.staff_notifications
  where read_at is null;

  select count(*) into v_recent_critical
  from public.watch_guard_events
  where severity = 'critical' and created_at > now() - interval '24 hours';

  select count(*) into v_offline_sync_count from public.attendance where is_offline_sync = true;

  select count(*) into v_failed_challenges_24h
  from public.staff_login_challenges lc
  where lc.created_at > now() - interval '24 hours'
    and lc.used_at is null
    and lc.expires_at <= now();

  v_report := jsonb_build_object(
    'generated_at', now(),
    'summary', jsonb_build_object(
      'total_companies', v_total_companies,
      'total_staff', v_total_staff,
      'active_sessions', v_active_sessions,
      'checked_in_today', v_checked_in_today,
      'checked_out_today', v_checked_out_today,
      'absent_today', v_absent_today,
      'pending_devices', v_pending_devices,
      'suspicious_attendance', v_suspicious_attendance,
      'suspicious_locations', v_suspicious_locations,
      'geofence_violations', v_geofence_violations,
      'pending_notifications', v_pending_notifications,
      'offline_sync_records', v_offline_sync_count,
      'failed_login_attempts_24h', v_failed_challenges_24h,
      'critical_events_24h', v_recent_critical
    )
  );

  return v_report;
end;
$$;

-- Recent cross-organization watch-guard events, with company name.
CREATE OR REPLACE FUNCTION public.platform_watch_guard_events(p_limit integer DEFAULT 50)
RETURNS TABLE (
  id uuid,
  company_id uuid,
  company_name text,
  severity text,
  category text,
  message text,
  metadata jsonb,
  created_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    e.id,
    e.company_id,
    c.name as company_name,
    e.severity,
    e.category,
    e.message,
    e.metadata,
    e.created_at
  from public.watch_guard_events e
  left join public.companies c on c.id = e.company_id
  order by e.created_at desc
  limit p_limit;
$$;

-- Cross-organization per-company health snapshot.
CREATE OR REPLACE FUNCTION public.platform_company_health(p_limit integer DEFAULT 50)
RETURNS TABLE (
  company_id uuid,
  company_name text,
  staff_count integer,
  active_sessions integer,
  checked_in_today integer,
  suspicious_events integer,
  geofence_violations integer,
  pending_devices integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    c.id,
    c.name,
    (select count(*) from public.staff s where s.company_id = c.id and s.status = 'active')::integer,
    (select count(*) from public.staff_sessions ss join public.staff s on s.id = ss.staff_id where s.company_id = c.id and ss.expires_at > now())::integer,
    (select count(*) from public.attendance a join public.staff s on s.id = a.staff_id where s.company_id = c.id and a.work_date = current_date and a.check_in is not null)::integer,
    (select count(*) from public.attendance a join public.staff s on s.id = a.staff_id where s.company_id = c.id and (a.spoof_score >= 30 or a.geofence_status = 'outside'))::integer,
    (select count(*) from public.attendance a join public.staff s on s.id = a.staff_id where s.company_id = c.id and a.geofence_status = 'outside')::integer,
    (select count(*) from public.staff s where s.company_id = c.id and s.status = 'active' and s.pending_device_fingerprint is not null)::integer
  from public.companies c
  order by c.created_at desc
  limit p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.platform_watch_guard_report() TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_watch_guard_events(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_company_health(integer) TO authenticated;
