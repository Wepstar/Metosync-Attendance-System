-- Real-time alerting for Watch Guard.
-- Adds watch_guard_events to the realtime publication and auto-generates alerts from attendance/location events.

-- Ensure the events table exists.
CREATE TABLE IF NOT EXISTS public.watch_guard_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid,
  severity text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  category text NOT NULL,
  message text NOT NULL,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Add watch_guard_events to the Supabase realtime publication so the owner dashboard gets live alerts.
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

-- Helper: raise a watch-guard event from a trigger.
CREATE OR REPLACE FUNCTION public.watch_guard_raise_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_company_id uuid;
  v_staff_name text;
  v_event_severity text;
  v_event_category text;
  v_event_message text;
  v_metadata jsonb;
begin
  if tg_table_name = 'attendance' then
    select s.company_id, s.full_name into v_company_id, v_staff_name
    from public.staff s where s.id = new.staff_id;

    if new.spoof_score >= 80 then
      v_event_severity := 'critical';
      v_event_category := 'spoof_detected';
      v_event_message := format('High spoof score (%s) detected for %s during attendance.', new.spoof_score, v_staff_name);
      v_metadata := jsonb_build_object('staff_id', new.staff_id, 'attendance_id', new.id, 'spoof_score', new.spoof_score, 'spoof_flags', new.spoof_flags);
      insert into public.watch_guard_events (company_id, severity, category, message, metadata)
      values (v_company_id, v_event_severity, v_event_category, v_event_message, v_metadata);
    elsif new.spoof_score >= 30 then
      v_event_severity := 'warning';
      v_event_category := 'suspicious_activity';
      v_event_message := format('Elevated spoof score (%s) for %s during attendance.', new.spoof_score, v_staff_name);
      v_metadata := jsonb_build_object('staff_id', new.staff_id, 'attendance_id', new.id, 'spoof_score', new.spoof_score, 'spoof_flags', new.spoof_flags);
      insert into public.watch_guard_events (company_id, severity, category, message, metadata)
      values (v_company_id, v_event_severity, v_event_category, v_event_message, v_metadata);
    end if;

    if new.geofence_status = 'outside' then
      v_event_severity := 'critical';
      v_event_category := 'geofence_violation';
      v_event_message := format('%s checked in/out outside the allowed site radius.', v_staff_name);
      v_metadata := jsonb_build_object('staff_id', new.staff_id, 'attendance_id', new.id, 'distance_meters', new.geofence_distance_meters, 'latitude', new.check_in_latitude, 'longitude', new.check_in_longitude);
      insert into public.watch_guard_events (company_id, severity, category, message, metadata)
      values (v_company_id, v_event_severity, v_event_category, v_event_message, v_metadata);
    end if;
  elsif tg_table_name = 'location_verifications' then
    select s.company_id, s.full_name into v_company_id, v_staff_name
    from public.staff s where s.id = new.staff_id;

    if new.spoof_score >= 80 then
      v_event_severity := 'critical';
      v_event_category := 'spoof_detected';
      v_event_message := format('High spoof score (%s) detected for %s during location check.', new.spoof_score, v_staff_name);
      v_metadata := jsonb_build_object('staff_id', new.staff_id, 'location_verification_id', new.id, 'spoof_score', new.spoof_score, 'spoof_flags', new.spoof_flags);
      insert into public.watch_guard_events (company_id, severity, category, message, metadata)
      values (v_company_id, v_event_severity, v_event_category, v_event_message, v_metadata);
    elsif new.spoof_score >= 30 then
      v_event_severity := 'warning';
      v_event_category := 'suspicious_activity';
      v_event_message := format('Elevated spoof score (%s) for %s during location check.', new.spoof_score, v_staff_name);
      v_metadata := jsonb_build_object('staff_id', new.staff_id, 'location_verification_id', new.id, 'spoof_score', new.spoof_score, 'spoof_flags', new.spoof_flags);
      insert into public.watch_guard_events (company_id, severity, category, message, metadata)
      values (v_company_id, v_event_severity, v_event_category, v_event_message, v_metadata);
    end if;
  end if;

  return new;
end;
$$;

-- Attach triggers.
DROP TRIGGER IF EXISTS trg_watch_guard_attendance_alert ON public.attendance;
CREATE TRIGGER trg_watch_guard_attendance_alert
AFTER INSERT OR UPDATE ON public.attendance
FOR EACH ROW EXECUTE FUNCTION public.watch_guard_raise_event();

DROP TRIGGER IF EXISTS trg_watch_guard_location_alert ON public.location_verifications;
CREATE TRIGGER trg_watch_guard_location_alert
AFTER INSERT ON public.location_verifications
FOR EACH ROW EXECUTE FUNCTION public.watch_guard_raise_event();
