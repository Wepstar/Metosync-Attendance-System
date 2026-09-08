-- Watch Guard: system analysis, alerting, chatbot, and AI API entry point.

CREATE TABLE IF NOT EXISTS public.watch_guard_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid,
  severity text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  category text NOT NULL,
  message text NOT NULL,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS watch_guard_events_company_created_idx
  ON public.watch_guard_events (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS watch_guard_events_severity_idx
  ON public.watch_guard_events (company_id, severity, created_at DESC);

ALTER TABLE public.watch_guard_events ENABLE ROW LEVEL SECURITY;

-- Helper: emit a watch-guard event for a company.
CREATE OR REPLACE FUNCTION public.watch_guard_log_event(
  p_company_id uuid,
  p_severity text,
  p_category text,
  p_message text,
  p_metadata jsonb DEFAULT NULL
)
RETURNS public.watch_guard_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.watch_guard_events%rowtype;
begin
  insert into public.watch_guard_events (company_id, severity, category, message, metadata)
  values (p_company_id, p_severity, p_category, p_message, p_metadata)
  returning * into v_row;
  return v_row;
end;
$$;

-- Core system health report for the owner dashboard.
CREATE OR REPLACE FUNCTION public.watch_guard_report(p_company_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
declare
  v_report jsonb;
  v_active_sessions integer;
  v_checked_in_today integer;
  v_checked_out_today integer;
  v_absent_today integer;
  v_total_staff integer;
  v_pending_devices integer;
  v_suspicious_attendance integer;
  v_suspicious_locations integer;
  v_pending_notifications integer;
  v_recent_critical integer;
  v_offline_sync_count integer;
  v_failed_challenges_24h integer;
begin
  select count(*) into v_total_staff from public.staff where company_id = p_company_id;
  select count(*) into v_active_sessions
  from public.staff_sessions ss
  join public.staff s on s.id = ss.staff_id
  where s.company_id = p_company_id and ss.expires_at > now();

  select count(*) into v_checked_in_today
  from public.attendance a
  join public.staff s on s.id = a.staff_id
  where s.company_id = p_company_id and a.work_date = current_date and a.check_in is not null;

  select count(*) into v_checked_out_today
  from public.attendance a
  join public.staff s on s.id = a.staff_id
  where s.company_id = p_company_id and a.work_date = current_date and a.check_out is not null;

  v_absent_today := greatest(v_total_staff - v_checked_in_today, 0);

  select count(*) into v_pending_devices
  from public.staff
  where company_id = p_company_id and pending_device_fingerprint is not null;

  select count(*) into v_suspicious_attendance
  from public.attendance a
  join public.staff s on s.id = a.staff_id
  where s.company_id = p_company_id and (a.spoof_score >= 30 or a.geofence_status = 'outside');

  select count(*) into v_suspicious_locations
  from public.location_verifications lv
  join public.staff s on s.id = lv.staff_id
  where s.company_id = p_company_id and (lv.spoof_score >= 30);

  select count(*) into v_pending_notifications
  from public.staff_notifications n
  join public.staff s on s.id = n.staff_id
  where s.company_id = p_company_id and n.read_at is null;

  select count(*) into v_recent_critical
  from public.watch_guard_events
  where company_id = p_company_id and severity = 'critical' and created_at > now() - interval '24 hours';

  -- Approximate offline sync count: attendance records flagged as offline sync.
  select count(*) into v_offline_sync_count
  from public.attendance a
  join public.staff s on s.id = a.staff_id
  where s.company_id = p_company_id and a.is_offline_sync = true;

  -- Failed login attempts in the last 24h (challenges created but never verified/used).
  select count(*) into v_failed_challenges_24h
  from public.staff_login_challenges lc
  join public.staff s on s.id = lc.staff_id
  where s.company_id = p_company_id
    and lc.created_at > now() - interval '24 hours'
    and lc.used_at is null
    and lc.expires_at <= now();

  v_report := jsonb_build_object(
    'generated_at', now(),
    'company_id', p_company_id,
    'summary', jsonb_build_object(
      'total_staff', v_total_staff,
      'active_sessions', v_active_sessions,
      'checked_in_today', v_checked_in_today,
      'checked_out_today', v_checked_out_today,
      'absent_today', v_absent_today,
      'pending_devices', v_pending_devices,
      'suspicious_attendance', v_suspicious_attendance,
      'suspicious_locations', v_suspicious_locations,
      'pending_notifications', v_pending_notifications,
      'offline_sync_records', v_offline_sync_count,
      'failed_login_attempts_24h', v_failed_challenges_24h,
      'critical_events_24h', v_recent_critical
    ),
    'recent_events', (
      select coalesce(jsonb_agg(e.* order by e.created_at desc), '[]'::jsonb)
      from (
        select id, severity, category, message, metadata, created_at
        from public.watch_guard_events
        where company_id = p_company_id
        order by created_at desc
        limit 20
      ) e
    )
  );

  return v_report;
end;
$$;

-- Simple rule-based chatbot. Later this can call an external LLM or vector store.
CREATE OR REPLACE FUNCTION public.watch_guard_chat(
  p_company_id uuid,
  p_message text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_msg text := lower(trim(p_message));
  v_report jsonb;
  v_reply text;
  v_action text := 'info';
  v_data jsonb := '{}'::jsonb;
begin
  v_report := public.watch_guard_report(p_company_id);

  if v_msg like '%report%' or v_msg like '%status%' or v_msg like '%health%' or v_msg like '%summary%' then
    v_reply := 'Here is the current system health summary.';
    v_data := jsonb_build_object('report', v_report);
  elsif v_msg like '%attendance%' or v_msg like '%check-in%' or v_msg like '%checked in%' then
    v_reply := format(
      'Today: %s checked in, %s checked out, %s absent out of %s total staff.',
      v_report->'summary'->>'checked_in_today',
      v_report->'summary'->>'checked_out_today',
      v_report->'summary'->>'absent_today',
      v_report->'summary'->>'total_staff'
    );
  elsif v_msg like '%suspicious%' or v_msg like '%spoof%' or v_msg like '%fraud%' then
    v_reply := format(
      'Found %s suspicious attendance record(s) and %s suspicious location ping(s) with spoof_score >= 30.',
      v_report->'summary'->>'suspicious_attendance',
      v_report->'summary'->>'suspicious_locations'
    );
    v_action := 'alert';
  elsif v_msg like '%device%' or v_msg like '%pending device%' then
    v_reply := format(
      'There are %s staff member(s) with a pending device fingerprint awaiting approval.',
      v_report->'summary'->>'pending_devices'
    );
    v_action := 'warning';
  elsif v_msg like '%offline%' or v_msg like '%sync%' then
    v_reply := format(
      'There are %s offline-synced attendance record(s) in the database. Staff devices may have pending queue items that are not visible server-side.',
      v_report->'summary'->>'offline_sync_records'
    );
  elsif v_msg like '%login%' or v_msg like '%failed%' or v_msg like '%lock%' then
    v_reply := format(
      '%s failed/expired login challenge(s) in the last 24 hours. If this spikes, review staff PINs and device binding.',
      v_report->'summary'->>'failed_login_attempts_24h'
    );
    v_action := 'warning';
  elsif v_msg like '%help%' or v_msg like '%what can%' then
    v_reply := 'I can report on attendance, suspicious activity, pending devices, offline sync, login failures, and overall system health. Try: "show report", "attendance today", "suspicious activity", or "pending devices".';
  else
    v_reply := 'I did not understand. Try asking for "report", "attendance", "suspicious", "devices", "offline", or "login failures".';
  end if;

  return jsonb_build_object('reply', v_reply, 'action', v_action, 'data', v_data);
end;
$$;

-- AI / external agent API entry point. Read-only by default; modification actions are gated.
CREATE OR REPLACE FUNCTION public.watch_guard_api(
  p_company_id uuid,
  p_action text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_result jsonb;
begin
  case p_action
    when 'report' then
      v_result := public.watch_guard_report(p_company_id);
    when 'chat' then
      v_result := public.watch_guard_chat(p_company_id, p_payload->>'message');
    when 'events' then
      v_result := (
        select coalesce(jsonb_agg(e.* order by e.created_at desc), '[]'::jsonb)
        from (
          select id, severity, category, message, metadata, created_at
          from public.watch_guard_events
          where company_id = p_company_id
          order by created_at desc
          limit 50
        ) e
      );
    when 'log' then
      -- Allow AI/owner to log an observation for audit.
      v_result := to_jsonb(public.watch_guard_log_event(
        p_company_id,
        p_payload->>'severity',
        p_payload->>'category',
        p_payload->>'message',
        p_payload->'metadata'
      ));
    else
      raise exception 'Unknown watch_guard_api action: %', p_action;
  end case;

  return jsonb_build_object('action', p_action, 'payload', p_payload, 'result', v_result);
end;
$$;

GRANT EXECUTE ON FUNCTION public.watch_guard_report(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watch_guard_chat(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watch_guard_api(uuid, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watch_guard_log_event(uuid, text, text, text, jsonb) TO authenticated;
