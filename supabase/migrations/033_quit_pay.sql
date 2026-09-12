-- Quit Pay: final settlement for a leaving staff member.
-- Preview computes pro-rated final salary, leave entitlement/usage, leave
-- payout, and active deductions. Processing creates a payment_request and
-- marks the staff member inactive.

CREATE OR REPLACE FUNCTION public.staff_quit_settlement_preview(
  p_staff_id uuid,
  p_last_working_date date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
declare
  v_staff public.staff%rowtype;
  v_company public.companies%rowtype;
  v_days_in_month integer;
  v_days_worked integer;
  v_final_salary numeric;
  v_leave_entitled numeric;
  v_leave_taken numeric;
  v_leave_unused numeric;
  v_leave_payout numeric;
  v_daily_rate numeric;
  v_deductions jsonb := '[]'::jsonb;
  v_deductions_total numeric := 0;
begin
  select * into v_staff from public.staff where id = p_staff_id;
  if not found then raise exception 'Staff not found.'; end if;
  if p_last_working_date is null then raise exception 'Last working date is required.'; end if;
  select * into v_company from public.companies where id = v_staff.company_id;

  -- Pro-rated final salary for the month containing the last working date.
  v_days_in_month := extract(day from (date_trunc('month', p_last_working_date) + interval '1 month' - interval '1 day'));
  v_days_worked := extract(day from p_last_working_date);
  v_final_salary := round(coalesce(v_staff.monthly_salary, 0) * v_days_worked / greatest(v_days_in_month, 1), 2);

  -- Leave: annual entitlement pro-rated by months elapsed this year;
  -- taken = attendance rows marked on_leave this year.
  v_leave_entitled := round(coalesce(v_company.leave_policy_annual_days, 20) * extract(month from p_last_working_date) / 12.0, 1);
  select count(*) into v_leave_taken
    from public.attendance a
    where a.staff_id = p_staff_id
      and a.status = 'on_leave'
      and extract(year from a.work_date) = extract(year from p_last_working_date);
  v_leave_unused := greatest(v_leave_entitled - v_leave_taken, 0);
  v_daily_rate := coalesce(v_staff.monthly_salary, 0) / greatest(v_days_in_month, 1);
  v_leave_payout := round(v_leave_unused * v_daily_rate, 2);

  -- Active deductions for this staff member (guarded: the applied-deductions
  -- table may not exist in every deployment; an unset amount stays null).
  if to_regclass('public.staff_deductions') is not null then
    begin
      execute $q$
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', sd.id, 'name', dt.name, 'category', dt.category,
          'amount', coalesce(sd.amount, dt.amount)) order by dt.name), '[]'::jsonb)
        from public.staff_deductions sd
        join public.deduction_types dt on dt.id = sd.deduction_type_id
        where sd.staff_id = $1 and coalesce(sd.is_active, true)
      $q$ into v_deductions using p_staff_id;
      execute $q$
        select coalesce(sum(coalesce(sd.amount, dt.amount)), 0)
        from public.staff_deductions sd
        join public.deduction_types dt on dt.id = sd.deduction_type_id
        where sd.staff_id = $1 and coalesce(sd.is_active, true)
      $q$ into v_deductions_total using p_staff_id;
    exception when others then
      v_deductions := '[]'::jsonb;
      v_deductions_total := 0;
    end;
  end if;

  return jsonb_build_object(
    'staff_id', v_staff.id,
    'staff_name', v_staff.full_name,
    'currency', coalesce(v_staff.currency, v_company.default_currency, 'GHS'),
    'last_working_date', p_last_working_date,
    'days_worked_in_final_month', v_days_worked,
    'days_in_final_month', v_days_in_month,
    'final_salary', v_final_salary,
    'leave_entitled_days', v_leave_entitled,
    'leave_taken_days', v_leave_taken,
    'leave_unused_days', v_leave_unused,
    'leave_payout', v_leave_payout,
    'deductions', v_deductions,
    'deductions_total', v_deductions_total
  );
end;
$$;

CREATE OR REPLACE FUNCTION public.staff_process_quit_settlement(
  p_staff_id uuid,
  p_last_working_date date,
  p_mode text DEFAULT 'direct',
  p_direct_amount numeric DEFAULT NULL,
  p_include_final_salary boolean DEFAULT true,
  p_include_leave_payout boolean DEFAULT true,
  p_deduction_amount numeric DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_provider text DEFAULT 'paystack',
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_staff public.staff%rowtype;
  v_preview jsonb;
  v_amount numeric;
  v_currency text;
  v_reference text;
  v_request_id uuid;
begin
  select * into v_staff from public.staff where id = p_staff_id;
  if not found then raise exception 'Staff not found.'; end if;
  if p_mode not in ('direct', 'itemized') then raise exception 'Mode must be direct or itemized.'; end if;
  if p_provider not in ('paystack', 'flutterwave', 'stripe') then raise exception 'Invalid provider.'; end if;

  v_preview := public.staff_quit_settlement_preview(p_staff_id, p_last_working_date);
  v_currency := coalesce(p_currency, v_staff.currency, 'GHS');

  if p_mode = 'direct' then
    v_amount := coalesce(p_direct_amount, 0);
  else
    v_amount :=
      (case when coalesce(p_include_final_salary, true) then coalesce((v_preview->>'final_salary')::numeric, 0) else 0 end)
      + (case when coalesce(p_include_leave_payout, true) then coalesce((v_preview->>'leave_payout')::numeric, 0) else 0 end)
      - coalesce(p_deduction_amount, 0);
  end if;
  if v_amount < 0 then v_amount := 0; end if;

  v_reference := 'QUIT-' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 8));

  insert into public.payment_requests (company_id, staff_id, provider, amount, currency, reference, status, metadata)
  values (
    v_staff.company_id,
    p_staff_id,
    p_provider,
    v_amount,
    v_currency,
    v_reference,
    'pending',
    jsonb_build_object(
      'type', 'quit_settlement',
      'mode', p_mode,
      'last_working_date', p_last_working_date,
      'notes', p_notes,
      'preview', v_preview
    )
  )
  returning id into v_request_id;

  update public.staff set status = 'inactive' where id = p_staff_id;

  return jsonb_build_object(
    'id', v_request_id,
    'reference', v_reference,
    'amount', v_amount,
    'currency', v_currency,
    'status', 'pending'
  );
end;
$$;

GRANT EXECUTE ON FUNCTION public.staff_quit_settlement_preview(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_process_quit_settlement(uuid, date, text, numeric, boolean, boolean, numeric, text, text, text) TO authenticated;
