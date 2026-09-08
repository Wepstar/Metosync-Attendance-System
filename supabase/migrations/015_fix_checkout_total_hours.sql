-- Fix check-out error: total_hours was a generated column or missing.
-- Make total_hours a regular numeric column and auto-compute it via trigger.

-- Drop generated expression if it exists, then ensure the column is plain numeric.
do $$
declare
  col_info record;
begin
  select a.attname, a.attgenerated into col_info
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'attendance'
    and a.attname = 'total_hours';

  if col_info.attgenerated is not null then
    execute 'alter table public.attendance alter column total_hours drop expression';
  end if;
end;
$$;

alter table public.attendance
  alter column total_hours type numeric,
  alter column total_hours drop not null,
  alter column total_hours set default null;

-- Trigger function: compute total_hours whenever check_in and check_out are both present.
create or replace function public.calculate_attendance_total_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.check_in is not null and new.check_out is not null then
    new.total_hours := round((extract(epoch from (new.check_out - new.check_in)) / 3600)::numeric, 2);
  end if;
  return new;
end;
$$;

-- Apply the trigger to attendance inserts and updates.
drop trigger if exists trg_calculate_attendance_total_hours on public.attendance;
create trigger trg_calculate_attendance_total_hours
before insert or update on public.attendance
for each row execute function public.calculate_attendance_total_hours();

-- Update staff_check_out to not manually set total_hours (trigger handles it).
-- It will still work with the p_device_timestamp and other new parameters.
create or replace function public.staff_check_out(
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
returns public.attendance
language plpgsql
security definer
set search_path = public, extensions
as $$
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

grant execute on function public.staff_check_out(text, numeric, numeric, numeric, timestamptz, boolean, text, integer, text[]) to anon, authenticated;
