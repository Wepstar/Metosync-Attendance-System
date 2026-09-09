-- Fix payroll_payables to avoid GROUP BY error by using a CTE and WHERE on the computed pending amount.
CREATE OR REPLACE FUNCTION public.payroll_payables(p_company_id uuid)
RETURNS TABLE (
  payroll_entry_id uuid,
  staff_id uuid,
  full_name text,
  phone text,
  net_pay numeric,
  period_name text,
  paid_amount numeric,
  pending_amount numeric
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  with base as (
    select
      pe.id as payroll_entry_id,
      s.id as staff_id,
      s.full_name,
      s.phone,
      pe.net_pay,
      coalesce(pp.period_start::text || ' - ' || pp.period_end::text, '') as period_name,
      coalesce((select sum(pr.amount) from public.payment_requests pr where pr.payroll_entry_id = pe.id and pr.status = 'completed'), 0) as paid_amount,
      pe.net_pay - coalesce((select sum(pr.amount) from public.payment_requests pr where pr.payroll_entry_id = pe.id and pr.status = 'completed'), 0) as pending_amount,
      pp.period_end
    from public.payroll_entries pe
    join public.staff s on s.id = pe.staff_id
    join public.payroll_periods pp on pp.id = pe.payroll_period_id
    where s.company_id = p_company_id
      and pe.net_pay > 0
  )
  select payroll_entry_id, staff_id, full_name, phone, net_pay, period_name, paid_amount, pending_amount
  from base
  where pending_amount > 0
  order by period_end desc, full_name;
$$;

GRANT EXECUTE ON FUNCTION public.payroll_payables(uuid) TO authenticated;
