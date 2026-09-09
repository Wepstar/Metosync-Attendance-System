-- Phase 6: Reporting & Analytics

-- Attendance daily summary for a company and date range.
CREATE OR REPLACE FUNCTION public.report_attendance_summary(
  p_company_id uuid,
  p_start date,
  p_end date
)
RETURNS TABLE (
  work_date date,
  present bigint,
  absent bigint,
  late bigint,
  on_leave bigint,
  other bigint,
  total_hours numeric,
  staff_count bigint
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    a.work_date,
    count(*) filter (where a.status = 'present') as present,
    count(*) filter (where a.status = 'absent') as absent,
    count(*) filter (where a.status = 'late') as late,
    count(*) filter (where a.status = 'on_leave') as on_leave,
    count(*) filter (where a.status not in ('present','absent','late','on_leave')) as other,
    coalesce(sum(a.total_hours), 0) as total_hours,
    count(distinct a.staff_id) as staff_count
  from public.attendance a
  where a.company_id = p_company_id
    and a.work_date between p_start and p_end
  group by a.work_date
  order by a.work_date;
$$;

-- Payroll period summary for a company and date range.
CREATE OR REPLACE FUNCTION public.report_payroll_summary(
  p_company_id uuid,
  p_start date,
  p_end date
)
RETURNS TABLE (
  period_name text,
  gross_pay numeric,
  total_deductions numeric,
  net_pay numeric,
  paid_amount numeric,
  pending_amount numeric
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    (pp.period_start::text || ' - ' || pp.period_end::text) as period_name,
    coalesce(sum(pe.gross_pay), 0) as gross_pay,
    coalesce(sum(pe.total_deductions), 0) as total_deductions,
    coalesce(sum(pe.net_pay), 0) as net_pay,
    coalesce(sum((select sum(pr.amount) from public.payment_requests pr where pr.payroll_entry_id = pe.id and pr.status = 'completed')), 0) as paid_amount,
    coalesce(sum(pe.net_pay - coalesce((select sum(pr.amount) from public.payment_requests pr where pr.payroll_entry_id = pe.id and pr.status = 'completed'), 0)), 0) as pending_amount
  from public.payroll_entries pe
  join public.payroll_periods pp on pp.id = pe.payroll_period_id
  where pp.company_id = p_company_id
    and pp.period_start <= p_end
    and pp.period_end >= p_start
  group by pp.id, pp.period_start, pp.period_end
  order by pp.period_start desc;
$$;

-- Payments summary for a company and date range.
CREATE OR REPLACE FUNCTION public.report_payments_summary(
  p_company_id uuid,
  p_start date,
  p_end date
)
RETURNS TABLE (
  provider text,
  status text,
  total_amount numeric,
  count bigint
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    pr.provider,
    pr.status,
    coalesce(sum(pr.amount), 0) as total_amount,
    count(*) as count
  from public.payment_requests pr
  where pr.company_id = p_company_id
    and pr.created_at::date between p_start and p_end
  group by pr.provider, pr.status
  order by pr.provider, pr.status;
$$;

-- Staff summary for a company.
CREATE OR REPLACE FUNCTION public.report_staff_summary(p_company_id uuid)
RETURNS TABLE (
  total_staff bigint,
  active bigint,
  inactive bigint,
  on_leave bigint,
  permanent bigint,
  casual bigint,
  pending_devices bigint
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    count(*) as total_staff,
    count(*) filter (where s.status = 'active') as active,
    count(*) filter (where s.status = 'inactive') as inactive,
    count(*) filter (where s.status = 'on_leave') as on_leave,
    count(*) filter (where s.staff_type = 'permanent') as permanent,
    count(*) filter (where s.staff_type = 'casual') as casual,
    count(*) filter (where s.pending_device_fingerprint is not null and s.pending_device_fingerprint <> coalesce(s.device_fingerprint, '')) as pending_devices
  from public.staff s
  where s.company_id = p_company_id;
$$;

-- Platform-wide summary for owner reports.
CREATE OR REPLACE FUNCTION public.platform_report_summary()
RETURNS TABLE (
  total_companies bigint,
  total_staff bigint,
  total_attendance_today bigint,
  checked_in_today bigint,
  total_payroll_pending numeric,
  total_payments_today numeric
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    (select count(*) from public.companies) as total_companies,
    (select count(*) from public.staff) as total_staff,
    (select count(*) from public.attendance where work_date = current_date) as total_attendance_today,
    (select count(*) from public.attendance where work_date = current_date and check_in is not null) as checked_in_today,
    (select coalesce(sum(pe.net_pay - coalesce((select sum(pr.amount) from public.payment_requests pr where pr.payroll_entry_id = pe.id and pr.status = 'completed'), 0)), 0)
     from public.payroll_entries pe
     join public.payroll_periods pp on pp.id = pe.payroll_period_id
     where pe.net_pay > 0) as total_payroll_pending,
    (select coalesce(sum(amount), 0) from public.payment_requests where status = 'completed' and created_at::date = current_date) as total_payments_today;
$$;

GRANT EXECUTE ON FUNCTION public.report_attendance_summary(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_payroll_summary(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_payments_summary(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_staff_summary(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_report_summary() TO authenticated;
