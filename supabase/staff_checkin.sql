create extension if not exists pgcrypto;

alter table public.staff add column if not exists pin_hash text;
alter table public.staff add column if not exists company_id uuid references public.companies(id) on delete cascade;
alter table public.staff add column if not exists site_id uuid references public.sites(id) on delete set null;
alter table public.staff add column if not exists status text not null default 'active';
alter table public.staff add column if not exists staff_type text not null default 'permanent';

alter table public.attendance add column if not exists check_in_latitude numeric(9,6);
alter table public.attendance add column if not exists check_in_longitude numeric(9,6);
alter table public.attendance add column if not exists check_out_latitude numeric(9,6);
alter table public.attendance add column if not exists check_out_longitude numeric(9,6);

create unique index if not exists attendance_one_record_per_staff_day
  on public.attendance (staff_id, work_date);
create index if not exists attendance_staff_date_idx
  on public.attendance (staff_id, work_date desc);
create index if not exists staff_phone_idx
  on public.staff (phone);

create table if not exists public.staff_login_challenges (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.staff_sessions (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists staff_login_challenges_expiry_idx
  on public.staff_login_challenges (expires_at);
create index if not exists staff_sessions_staff_expiry_idx
  on public.staff_sessions (staff_id, expires_at);

create table if not exists public.staff_notifications (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  notification_type text not null,
  title text not null,
  message text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists staff_notifications_feed_idx
  on public.staff_notifications (staff_id, created_at desc);

create table if not exists public.staff_leave_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);

create table if not exists public.staff_loan_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  reason text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists staff_leave_requests_feed_idx
  on public.staff_leave_requests (staff_id, created_at desc);
create index if not exists staff_loan_requests_feed_idx
  on public.staff_loan_requests (staff_id, created_at desc);

create index if not exists attendance_status_changes_staff_event_idx
  on public.attendance_status_changes (staff_id, changed_at desc);

create or replace function public.staff_get_company(p_company_code text)
returns table (company_name text, company_logo_url text, company_code text)
language sql
security definer
stable
set search_path = public
as $$
  select c.name, c.logo_url, c.org_code
  from public.companies c
  where c.org_code = trim(p_company_code) and c.status = 'active'
  limit 1
$$;

drop function if exists public.staff_start_login(text);
create or replace function public.staff_start_login(p_company_code text, p_phone text)
returns table (challenge_token text, expires_at timestamptz, company_name text, company_logo_url text, company_code text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  matched_staff uuid;
  matched_company public.companies%rowtype;
  raw_token text;
  token_expiry timestamptz := now() + interval '5 minutes';
begin
  select s.id into matched_staff
  from public.staff s
  join public.companies c on c.id = s.company_id
  where c.org_code = trim(p_company_code)
    and c.status = 'active'
    and regexp_replace(s.phone, '[^0-9+]', '', 'g') = regexp_replace(trim(p_phone), '[^0-9+]', '', 'g')
    and s.status = 'active'
    and s.pin_hash is not null
  limit 1;

  if matched_staff is null then
    return;
  end if;

  select c.* into matched_company from public.companies c
  join public.staff s on s.company_id = c.id
  where s.id = matched_staff;

  raw_token := encode(gen_random_bytes(32), 'hex');
  insert into public.staff_login_challenges (staff_id, token_hash, expires_at)
  values (matched_staff, encode(digest(raw_token, 'sha256'), 'hex'), token_expiry);
  return query select raw_token, token_expiry, matched_company.name, matched_company.logo_url, matched_company.org_code;
end;
$$;

create or replace function public.staff_verify_pin(p_challenge_token text, p_pin text)
returns table (
  session_token text,
  session_expires_at timestamptz,
  staff_id uuid,
  full_name text,
  company_id uuid,
  site_id uuid,
  already_checked_in boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  challenge public.staff_login_challenges%rowtype;
  staff_row public.staff%rowtype;
  raw_session text;
  session_expiry timestamptz := now() + interval '12 hours';
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

  update public.staff_login_challenges set used_at = now() where id = challenge.id;
  delete from public.staff_sessions as ss where ss.staff_id = staff_row.id and ss.expires_at <= now();
  raw_session := encode(gen_random_bytes(32), 'hex');
  insert into public.staff_sessions (staff_id, token_hash, expires_at)
  values (staff_row.id, encode(digest(raw_session, 'sha256'), 'hex'), session_expiry);

  return query
  select raw_session, session_expiry, staff_row.id, staff_row.full_name, staff_row.company_id,
         staff_row.site_id,
         exists (
           select 1 from public.attendance a
           where a.staff_id = staff_row.id and a.work_date = current_date and a.check_in is not null and a.check_out is null
         );
end;
$$;

create or replace function public.staff_session_id(p_session_token text)
returns uuid
language sql
security definer
stable
set search_path = public, extensions
as $$
  select ss.staff_id
  from public.staff_sessions ss
  where ss.token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
    and ss.expires_at > now()
$$;

create or replace function public.staff_check_in(
  p_session_token text,
  p_latitude numeric,
  p_longitude numeric
)
returns public.attendance
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_staff public.staff%rowtype;
  result_row public.attendance%rowtype;
begin
  select s.* into current_staff from public.staff s where s.id = public.staff_session_id(p_session_token) and s.status = 'active';
  if current_staff.id is null then raise exception 'Session expired'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Invalid GPS coordinates'; end if;
  if exists (select 1 from public.attendance a where a.staff_id = current_staff.id and a.work_date = current_date and a.check_in is not null and a.check_out is null) then
    raise exception 'You are already checked in';
  end if;

  insert into public.attendance (company_id, site_id, staff_id, work_date, status, check_in, source, check_in_latitude, check_in_longitude)
  values (current_staff.company_id, current_staff.site_id, current_staff.id, current_date, 'present', now(), 'staff', p_latitude, p_longitude)
  on conflict (staff_id, work_date) do nothing
  returning * into result_row;
  if result_row.id is null then raise exception 'Attendance already recorded for today'; end if;
  return result_row;
end;
$$;

create or replace function public.staff_check_out(
  p_session_token text,
  p_latitude numeric,
  p_longitude numeric
)
returns public.attendance
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_staff uuid := public.staff_session_id(p_session_token);
  result_row public.attendance%rowtype;
begin
  if current_staff is null then raise exception 'Session expired'; end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Invalid GPS coordinates'; end if;
  update public.attendance as a
  set check_out = now(),
      total_hours = round((extract(epoch from (now() - check_in)) / 3600)::numeric, 2),
      source = 'staff', check_out_latitude = p_latitude, check_out_longitude = p_longitude,
      updated_at = now()
  where a.staff_id = current_staff and a.work_date = current_date and a.check_in is not null and a.check_out is null
  returning * into result_row;
  if result_row.id is null then raise exception 'No active check-in found'; end if;
  return result_row;
end;
$$;

create or replace function public.registry_log_staff_attendance()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  staff_name text;
  company_name text;
  site_name text;
  event_reason text;
begin
  if coalesce(new.source, '') <> 'staff' then return new; end if;
  if tg_op = 'INSERT' and new.check_in is null then return new; end if;
  if tg_op = 'UPDATE' and new.check_in is not distinct from old.check_in and new.check_out is not distinct from old.check_out then return new; end if;

  select s.full_name, c.name, si.name
  into staff_name, company_name, site_name
  from public.staff s
  left join public.companies c on c.id = new.company_id
  left join public.sites si on si.id = new.site_id
  where s.id = new.staff_id;

  event_reason := case when new.check_out is not null then 'staff_check_out' else 'staff_check_in' end;
  insert into public.attendance_status_changes (
    company_id, company_name, staff_id, staff_name, site_id, site_name, work_date,
    old_status, new_status, check_in, check_out, changed_by, changed_at, reason
  ) values (
    new.company_id, company_name, new.staff_id, staff_name, new.site_id, site_name, new.work_date,
    case when tg_op = 'UPDATE' then old.status else null end, new.status, new.check_in, new.check_out,
    null, now(), event_reason
  );
  return new;
end;
$$;

drop trigger if exists registry_staff_attendance_trail on public.attendance;
create trigger registry_staff_attendance_trail after insert or update on public.attendance
for each row execute function public.registry_log_staff_attendance();

create or replace function public.staff_get_status(p_session_token text)
returns table (staff_id uuid, full_name text, checked_in boolean, attendance_id uuid, check_in timestamptz, check_out timestamptz)
language sql
security definer
stable
set search_path = public, extensions
as $$
  select s.id, s.full_name, a.check_in is not null and a.check_out is null, a.id, a.check_in, a.check_out
  from public.staff s
  left join public.attendance a on a.staff_id = s.id and a.work_date = current_date
  where s.id = public.staff_session_id(p_session_token) and s.status = 'active'
$$;

create or replace function public.staff_get_records(p_session_token text, p_from date default current_date - 30, p_to date default current_date)
returns setof public.attendance
language sql
security definer
stable
set search_path = public, extensions
as $$
  select a.* from public.attendance a
  where a.staff_id = public.staff_session_id(p_session_token)
    and a.work_date between p_from and p_to
  order by a.work_date desc
$$;

create or replace function public.staff_get_pay_records(p_session_token text)
returns table (period_start date, period_end date, status text, weekday_days integer, weekend_days integer, gross_pay numeric, total_deductions numeric, net_pay numeric, currency text)
language sql
security definer
stable
set search_path = public, extensions
as $$
  select p.period_start, p.period_end, p.status, e.weekday_days, e.weekend_days, e.gross_pay, e.total_deductions, e.net_pay, s.currency
  from public.payroll_entries e
  join public.payroll_periods p on p.id = e.payroll_period_id
  join public.staff s on s.id = e.staff_id
  where e.staff_id = public.staff_session_id(p_session_token)
  order by p.period_end desc
$$;

create or replace function public.staff_get_notifications(p_session_token text, p_unread_only boolean default false)
returns setof public.staff_notifications
language sql
security definer
stable
set search_path = public, extensions
as $$
  select n.* from public.staff_notifications n
  where n.staff_id = public.staff_session_id(p_session_token)
    and (not p_unread_only or n.read_at is null)
  order by n.created_at desc
  limit 100
$$;

create or replace function public.staff_mark_notification_read(p_session_token text, p_notification_id uuid)
returns boolean
language sql
security definer
set search_path = public, extensions
as $$
  with updated as (
    update public.staff_notifications as n set read_at = coalesce(n.read_at, now())
    where n.id = p_notification_id and n.staff_id = public.staff_session_id(p_session_token)
    returning id
  ) select exists (select 1 from updated)
$$;

create or replace function public.staff_request_leave(p_session_token text, p_start_date date, p_end_date date, p_reason text)
returns public.staff_leave_requests
language plpgsql
security definer
set search_path = public, extensions
as $$
declare result_row public.staff_leave_requests%rowtype; current_staff public.staff%rowtype;
begin
  select * into current_staff from public.staff where id = public.staff_session_id(p_session_token) and status = 'active';
  if current_staff.id is null then raise exception 'Session expired'; end if;
  insert into public.staff_leave_requests (staff_id, company_id, start_date, end_date, reason)
  values (current_staff.id, current_staff.company_id, p_start_date, p_end_date, trim(p_reason)) returning * into result_row;
  return result_row;
end;
$$;

create or replace function public.staff_request_loan(p_session_token text, p_amount numeric, p_reason text)
returns public.staff_loan_requests
language plpgsql
security definer
set search_path = public, extensions
as $$
declare result_row public.staff_loan_requests%rowtype; current_staff public.staff%rowtype;
begin
  select * into current_staff from public.staff where id = public.staff_session_id(p_session_token) and status = 'active';
  if current_staff.id is null then raise exception 'Session expired'; end if;
  insert into public.staff_loan_requests (staff_id, company_id, amount, reason)
  values (current_staff.id, current_staff.company_id, p_amount, trim(p_reason)) returning * into result_row;
  return result_row;
end;
$$;

create or replace function public.notify_staff_request_change()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.status is distinct from old.status then
    insert into public.staff_notifications (staff_id, company_id, notification_type, title, message)
    values (new.staff_id, new.company_id, tg_table_name, initcap(replace(tg_table_name, '_', ' ')) || ' updated', 'Your request status is now ' || new.status || '.');
  end if;
  return new;
end;
$$;

drop trigger if exists staff_leave_request_notification on public.staff_leave_requests;
create trigger staff_leave_request_notification after update on public.staff_leave_requests
for each row execute function public.notify_staff_request_change();
drop trigger if exists staff_loan_request_notification on public.staff_loan_requests;
create trigger staff_loan_request_notification after update on public.staff_loan_requests
for each row execute function public.notify_staff_request_change();

alter table public.staff_login_challenges enable row level security;
alter table public.staff_sessions enable row level security;
alter table public.staff_notifications enable row level security;
alter table public.staff_leave_requests enable row level security;
alter table public.staff_loan_requests enable row level security;

revoke all on public.staff_login_challenges, public.staff_sessions, public.staff_notifications, public.staff_leave_requests, public.staff_loan_requests from anon, authenticated;
grant execute on function public.staff_get_company(text), public.staff_start_login(text, text), public.staff_verify_pin(text, text), public.staff_session_id(text), public.staff_check_in(text, numeric, numeric), public.staff_check_out(text, numeric, numeric), public.staff_get_status(text), public.staff_get_records(text, date, date), public.staff_get_pay_records(text), public.staff_get_notifications(text, boolean), public.staff_mark_notification_read(text, uuid), public.staff_request_leave(text, date, date, text), public.staff_request_loan(text, numeric, text) to anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'staff_notifications') then
    alter publication supabase_realtime add table public.staff_notifications;
  end if;
end;
$$;