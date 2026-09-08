-- Watchguard monitoring and remediation layer for Metosync.
-- Immutable event log, rule engine, findings, AI action log, and safety controls.

-- 1. Immutable event log: append-only record of every consequential action.
CREATE TABLE IF NOT EXISTS public.watchguard_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_idempotency_key text UNIQUE,            -- external idempotency key when supplied
  event_type text NOT NULL,                     -- e.g. "attendance:INSERT"
  source_table text NOT NULL,
  source_action text NOT NULL,                  -- INSERT / UPDATE / DELETE / AI_ACTION
  company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
  actor_id uuid,                                -- auth.uid() when available
  actor_role text,                              -- authenticated / service_role / ai
  target_table text,
  target_id uuid,
  action_name text,                             -- for AI or remediation actions
  before_state jsonb,
  after_state jsonb,
  reason text,                                  -- human/AI reason for the change
  model_identity text,                          -- AI model identifier when applicable
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS watchguard_events_company_created_idx ON public.watchguard_events (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS watchguard_events_type_idx ON public.watchguard_events (source_table, source_action);
CREATE INDEX IF NOT EXISTS watchguard_events_target_idx ON public.watchguard_events (target_table, target_id);

-- 2. Findings: rule violations and AI-proposed remediation.
CREATE TABLE IF NOT EXISTS public.watchguard_findings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid,
  severity text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'rejected', 'auto_resolved')),
  rule_name text NOT NULL,
  description text NOT NULL,
  triggering_event_id uuid REFERENCES public.watchguard_events(id) ON DELETE SET NULL,
  proposed_action text,
  proposed_payload jsonb,
  idempotency_key text UNIQUE,
  auto_executed boolean DEFAULT false,
  approved_by uuid,
  approved_at timestamptz,
  approval_reason text,
  rejected_by uuid,
  rejected_at timestamptz,
  rejection_reason text,
  resolved_event_id uuid REFERENCES public.watchguard_events(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS watchguard_findings_open_idx ON public.watchguard_findings (status, severity, created_at DESC);
CREATE INDEX IF NOT EXISTS watchguard_findings_company_idx ON public.watchguard_findings (company_id, status, created_at DESC);

-- 3. AI action log: every AI proposal/execution, with idempotency, model identity and reasoning.
CREATE TABLE IF NOT EXISTS public.watchguard_ai_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE,
  company_id uuid,
  finding_id uuid REFERENCES public.watchguard_findings(id) ON DELETE SET NULL,
  action_name text NOT NULL CHECK (action_name IN ('flag_for_review', 'escalate_to_human', 'correct_attendance_record', 'retry_payment', 'reverse_payment')),
  payload jsonb NOT NULL,
  reason text NOT NULL,
  model_identity text NOT NULL,
  risk_tier text NOT NULL CHECK (risk_tier IN ('low', 'medium', 'high')),
  auto_executed boolean NOT NULL DEFAULT false,
  outcome_event_id uuid REFERENCES public.watchguard_events(id) ON DELETE SET NULL,
  approved_by uuid,
  rejected_by uuid,
  rejection_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  executed_at timestamptz
);

CREATE INDEX IF NOT EXISTS watchguard_ai_actions_model_created_idx ON public.watchguard_ai_actions (model_identity, created_at DESC);
CREATE INDEX IF NOT EXISTS watchguard_ai_actions_idempotency_idx ON public.watchguard_ai_actions (idempotency_key);

-- Helper: write an event.
CREATE OR REPLACE FUNCTION public.watchguard_write_event(
  p_event_type text,
  p_source_table text,
  p_source_action text,
  p_company_id uuid,
  p_actor_id uuid,
  p_actor_role text,
  p_target_table text,
  p_target_id uuid,
  p_action_name text,
  p_before_state jsonb,
  p_after_state jsonb,
  p_reason text,
  p_model_identity text,
  p_idempotency_key text DEFAULT NULL
)
RETURNS public.watchguard_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.watchguard_events%rowtype;
begin
  insert into public.watchguard_events (
    event_idempotency_key, event_type, source_table, source_action, company_id,
    actor_id, actor_role, target_table, target_id, action_name,
    before_state, after_state, reason, model_identity
  ) values (
    p_idempotency_key, p_event_type, p_source_table, p_source_action, p_company_id,
    p_actor_id, p_actor_role, p_target_table, p_target_id, p_action_name,
    p_before_state, p_after_state, p_reason, p_model_identity
  )
  returning * into v_row;
  return v_row;
end;
$$;

-- Trigger function: log any DML to consequential tables and then run rules.
CREATE OR REPLACE FUNCTION public.watchguard_log_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_company_id uuid;
  v_event_type text := tg_table_name || ':' || tg_op;
  v_target_id uuid;
  v_before jsonb := NULL;
  v_after jsonb := NULL;
  v_event public.watchguard_events%rowtype;
begin
  if tg_op = 'DELETE' then
    v_after := NULL;
    v_before := to_jsonb(old);
    v_target_id := old.id;
  elsif tg_op = 'INSERT' then
    v_after := to_jsonb(new);
    v_before := NULL;
    v_target_id := new.id;
  else
    v_after := to_jsonb(new);
    v_before := to_jsonb(old);
    v_target_id := new.id;
  end if;

  -- Resolve company_id for tables that carry or inherit it.
  v_company_id := NULL;
  if tg_op = 'DELETE' then
    if old.company_id is not null then v_company_id := old.company_id;
    elsif tg_table_name = 'attendance' then select company_id into v_company_id from public.staff where id = old.staff_id;
    elsif tg_table_name = 'payroll_entries' then select pp.company_id into v_company_id from public.payroll_periods pp where pp.id = old.payroll_period_id;
    end if;
  else
    if new.company_id is not null then v_company_id := new.company_id;
    elsif tg_table_name = 'attendance' then select company_id into v_company_id from public.staff where id = new.staff_id;
    elsif tg_table_name = 'payroll_entries' then select pp.company_id into v_company_id from public.payroll_periods pp where pp.id = new.payroll_period_id;
    end if;
  end if;

  v_event := public.watchguard_write_event(
    v_event_type, tg_table_name, tg_op, v_company_id, auth.uid(),
    coalesce(auth.role(), 'authenticated'), tg_table_name, v_target_id,
    NULL, v_before, v_after, NULL, NULL
  );

  -- Run rule engine against this event.
  perform public.watchguard_evaluate_rules(v_event.id);

  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

-- Attach triggers to consequential tables.
DROP TRIGGER IF EXISTS watchguard_attendance_trigger ON public.attendance;
CREATE TRIGGER watchguard_attendance_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.attendance
FOR EACH ROW EXECUTE FUNCTION public.watchguard_log_trigger();

DROP TRIGGER IF EXISTS watchguard_staff_trigger ON public.staff;
CREATE TRIGGER watchguard_staff_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.staff
FOR EACH ROW EXECUTE FUNCTION public.watchguard_log_trigger();

DROP TRIGGER IF EXISTS watchguard_payroll_periods_trigger ON public.payroll_periods;
CREATE TRIGGER watchguard_payroll_periods_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.payroll_periods
FOR EACH ROW EXECUTE FUNCTION public.watchguard_log_trigger();

DROP TRIGGER IF EXISTS watchguard_payroll_entries_trigger ON public.payroll_entries;
CREATE TRIGGER watchguard_payroll_entries_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.payroll_entries
FOR EACH ROW EXECUTE FUNCTION public.watchguard_log_trigger();

DROP TRIGGER IF EXISTS watchguard_companies_trigger ON public.companies;
CREATE TRIGGER watchguard_companies_trigger
AFTER UPDATE OR DELETE ON public.companies
FOR EACH ROW EXECUTE FUNCTION public.watchguard_log_trigger();

-- Payments table for the payment remediation features.
CREATE TABLE IF NOT EXISTS public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  payroll_entry_id uuid REFERENCES public.payroll_entries(id) ON DELETE SET NULL,
  amount numeric(12,2) NOT NULL,
  currency text DEFAULT 'GHS',
  reference text NOT NULL,
  provider text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
  paid_at timestamptz,
  reversed_at timestamptz,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS payments_reference_idx ON public.payments (company_id, reference);

DROP TRIGGER IF EXISTS watchguard_payments_trigger ON public.payments;
CREATE TRIGGER watchguard_payments_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.watchguard_log_trigger();

-- 4. Rule engine: evaluate an event and produce findings.
CREATE OR REPLACE FUNCTION public.watchguard_evaluate_rules(p_event_id uuid)
RETURNS SETOF public.watchguard_findings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  e public.watchguard_events%rowtype;
  a public.attendance%rowtype;
  pe public.payroll_entries%rowtype;
  pp public.payments%rowtype;
  f public.watchguard_findings%rowtype;
begin
  select * into e from public.watchguard_events where id = p_event_id;
  if not found then return; end if;

  -- Attendance rules
  if e.source_table = 'attendance' and e.source_action in ('INSERT', 'UPDATE') and e.after_state is not null then
    a := jsonb_populate_record(null::public.attendance, e.after_state);

    -- check-out before check-in
    if a.check_in is not null and a.check_out is not null and a.check_out < a.check_in then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'critical', 'open', 'check_out_before_check_in',
        format('Attendance %s has check-out (%s) before check-in (%s).', a.id, a.check_out::text, a.check_in::text),
        p_event_id,
        'flag_for_review',
        jsonb_build_object('attendance_id', a.id, 'rule', 'check_out_before_check_in')
      ) returning *;
    end if;

    -- impossibly long shift
    if a.total_hours is not null and a.total_hours > 24 then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'critical', 'open', 'excessive_shift_hours',
        format('Attendance %s reports %s hours which exceeds 24.', a.id, a.total_hours),
        p_event_id,
        'flag_for_review',
        jsonb_build_object('attendance_id', a.id, 'rule', 'excessive_shift_hours')
      ) returning *;
    end if;

    -- geofence violation
    if a.geofence_status = 'outside' then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'warning', 'open', 'geofence_violation',
        format('Attendance %s was recorded outside the assigned site radius.', a.id),
        p_event_id,
        'escalate_to_human',
        jsonb_build_object('attendance_id', a.id, 'rule', 'geofence_violation')
      ) returning *;
    end if;

    -- suspiciously fast in/out
    if a.check_in is not null and a.check_out is not null and extract(epoch from (a.check_out - a.check_in)) < 60 then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'warning', 'open', 'too_short_shift',
        format('Attendance %s has a shift under 60 seconds.', a.id),
        p_event_id,
        'flag_for_review',
        jsonb_build_object('attendance_id', a.id, 'rule', 'too_short_shift')
      ) returning *;
    end if;
  end if;

  -- Payroll rules
  if e.source_table = 'payroll_entries' and e.source_action in ('INSERT', 'UPDATE') and e.after_state is not null then
    pe := jsonb_populate_record(null::public.payroll_entries, e.after_state);

    if pe.net_pay is not null and pe.net_pay < 0 then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'critical', 'open', 'negative_net_pay',
        format('Payroll entry %s has a negative net pay (%s).', pe.id, pe.net_pay),
        p_event_id,
        'escalate_to_human',
        jsonb_build_object('payroll_entry_id', pe.id, 'rule', 'negative_net_pay')
      ) returning *;
    end if;

    if pe.gross_pay is not null and pe.total_deductions is not null and pe.gross_pay < pe.total_deductions then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'warning', 'open', 'deductions_exceed_gross',
        format('Payroll entry %s deductions exceed gross pay.', pe.id),
        p_event_id,
        'flag_for_review',
        jsonb_build_object('payroll_entry_id', pe.id, 'rule', 'deductions_exceed_gross')
      ) returning *;
    end if;

    -- duplicate payroll entry for same staff/period
    if exists (
      select 1 from public.payroll_entries x
      where x.staff_id = pe.staff_id and x.payroll_period_id = pe.payroll_period_id and x.id <> pe.id
    ) then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'warning', 'open', 'duplicate_payroll_entry',
        format('Duplicate payroll entry detected for staff %s in period %s.', pe.staff_id, pe.payroll_period_id),
        p_event_id,
        'flag_for_review',
        jsonb_build_object('payroll_entry_id', pe.id, 'rule', 'duplicate_payroll_entry')
      ) returning *;
    end if;
  end if;

  -- Payment rules
  if e.source_table = 'payments' and e.source_action in ('INSERT', 'UPDATE') and e.after_state is not null then
    pp := jsonb_populate_record(null::public.payments, e.after_state);

    -- duplicate reference
    if exists (
      select 1 from public.payments x
      where x.company_id = pp.company_id and x.reference = pp.reference and x.id <> pp.id
    ) then
      return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
      values (
        e.company_id, 'critical', 'open', 'duplicate_payment_reference',
        format('Payment reference %s is duplicated for company %s.', pp.reference, pp.company_id),
        p_event_id,
        'reverse_payment',
        jsonb_build_object('payment_id', pp.id, 'rule', 'duplicate_payment_reference')
      ) returning *;
    end if;

    -- payment mismatch with payroll entry
    if pp.payroll_entry_id is not null and pp.amount is not null then
      if not exists (select 1 from public.payroll_entries pe where pe.id = pp.payroll_entry_id and pe.net_pay = pp.amount) then
        return query insert into public.watchguard_findings (company_id, severity, status, rule_name, description, triggering_event_id, proposed_action, proposed_payload)
        values (
          e.company_id, 'warning', 'open', 'payment_amount_mismatch',
          format('Payment %s amount (%s) does not match the linked payroll entry.', pp.id, pp.amount),
          p_event_id,
          'flag_for_review',
          jsonb_build_object('payment_id', pp.id, 'rule', 'payment_amount_mismatch')
        ) returning *;
      end if;
    end if;
  end if;

  return;
end;
$$;

-- 5. Safety controls: rate limits and circuit breaker.
CREATE OR REPLACE FUNCTION public.watchguard_check_ai_safety(p_model_identity text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
declare
  v_calls_1m integer;
  v_rejections_1h integer;
  v_total_1h integer;
  v_rejection_rate numeric;
  v_result jsonb;
begin
  -- Rate limit: 100 calls per minute per model.
  select count(*) into v_calls_1m from public.watchguard_ai_actions
  where model_identity = p_model_identity and created_at > now() - interval '1 minute';

  if v_calls_1m >= 100 then
    return jsonb_build_object('allowed', false, 'reason', 'Rate limit exceeded: 100 calls per minute.');
  end if;

  -- Circuit breaker: if rejection rate in last hour is > 40% and there are at least 10 actions, suspend.
  select count(*) into v_total_1h from public.watchguard_ai_actions
  where model_identity = p_model_identity and created_at > now() - interval '1 hour';

  select count(*) into v_rejections_1h from public.watchguard_ai_actions
  where model_identity = p_model_identity and created_at > now() - interval '1 hour' and rejected_by is not null;

  if v_total_1h >= 10 then
    v_rejection_rate := v_rejections_1h::numeric / v_total_1h::numeric;
    if v_rejection_rate > 0.40 then
      return jsonb_build_object('allowed', false, 'reason', format('Circuit breaker open: rejection rate %s%% in last hour.', round(v_rejection_rate * 100, 1)));
    end if;
  end if;

  return jsonb_build_object('allowed', true, 'calls_1m', v_calls_1m, 'rejections_1h', v_rejections_1h);
end;
$$;

-- Risk tier lookup.
CREATE OR REPLACE FUNCTION public.watchguard_action_risk_tier(p_action text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public
AS $$
  select case p_action
    when 'flag_for_review' then 'low'
    when 'escalate_to_human' then 'low'
    when 'correct_attendance_record' then 'medium'
    when 'retry_payment' then 'high'
    when 'reverse_payment' then 'high'
    else 'medium'
  end;
$$;

-- 6. AI API action endpoint.
CREATE OR REPLACE FUNCTION public.watchguard_ai_action(
  p_company_id uuid,
  p_action text,
  p_payload jsonb,
  p_idempotency_key text,
  p_reason text,
  p_model_identity text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_safety jsonb;
  v_existing public.watchguard_ai_actions%rowtype;
  v_risk_tier text;
  v_finding_id uuid;
  v_action_row public.watchguard_ai_actions%rowtype;
  v_event public.watchguard_events%rowtype;
  v_result jsonb;
  v_status text;
  v_outcome_event_id uuid;
begin
  -- Validate action.
  if p_action not in ('flag_for_review', 'escalate_to_human', 'correct_attendance_record', 'retry_payment', 'reverse_payment') then
    raise exception 'Invalid watchguard AI action: %', p_action;
  end if;

  -- Idempotency.
  select * into v_existing from public.watchguard_ai_actions where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('status', 'duplicate', 'idempotency_key', p_idempotency_key, 'action', v_existing.action_name, 'created_at', v_existing.created_at);
  end if;

  -- Rate limits / circuit breaker.
  v_safety := public.watchguard_check_ai_safety(p_model_identity);
  if not (v_safety->>'allowed')::boolean then
    raise exception 'AI safety block: %', v_safety->>'reason';
  end if;

  v_risk_tier := public.watchguard_action_risk_tier(p_action);

  -- For high-risk actions, create a finding for human review unless explicitly configured to auto-execute.
  -- Low-risk actions are logged and auto-resolved by creating a remediation event.
  if v_risk_tier = 'low' then
    insert into public.watchguard_ai_actions (idempotency_key, company_id, action_name, payload, reason, model_identity, risk_tier, auto_executed, executed_at)
    values (p_idempotency_key, p_company_id, p_action, p_payload, p_reason, p_model_identity, v_risk_tier, true, now())
    returning * into v_action_row;

    v_event := public.watchguard_write_event(
      'ai:' || p_action, 'watchguard_ai_actions', 'INSERT', p_company_id, auth.uid(),
      'ai', 'watchguard_ai_actions', v_action_row.id,
      p_action, '{}'::jsonb, to_jsonb(v_action_row), p_reason, p_model_identity
    );
    update public.watchguard_ai_actions set outcome_event_id = v_event.id where id = v_action_row.id;

    v_status := 'auto_executed';
  else
    -- Medium/high risk: create an open finding for human approval.
    insert into public.watchguard_findings (company_id, severity, status, rule_name, description, proposed_action, proposed_payload, idempotency_key)
    values (
      p_company_id,
      case when v_risk_tier = 'high' then 'critical' else 'warning' end,
      'open',
      'ai_proposed_' || p_action,
      format('AI (%s) proposes %s: %s', p_model_identity, p_action, p_reason),
      p_action,
      p_payload,
      p_idempotency_key
    )
    returning id into v_finding_id;

    insert into public.watchguard_ai_actions (idempotency_key, company_id, finding_id, action_name, payload, reason, model_identity, risk_tier, auto_executed)
    values (p_idempotency_key, p_company_id, v_finding_id, p_action, p_payload, p_reason, p_model_identity, v_risk_tier, false)
    returning * into v_action_row;

    v_status := 'pending_approval';
  end if;

  v_result := jsonb_build_object(
    'status', v_status,
    'idempotency_key', p_idempotency_key,
    'action', p_action,
    'risk_tier', v_risk_tier,
    'finding_id', v_finding_id,
    'ai_action_id', v_action_row.id
  );

  return v_result;
end;
$$;

-- 7. Human approval / rejection of AI-proposed actions.
CREATE OR REPLACE FUNCTION public.watchguard_approve_action(
  p_finding_id uuid,
  p_user_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  f public.watchguard_findings%rowtype;
  a public.watchguard_ai_actions%rowtype;
  v_event public.watchguard_events%rowtype;
  v_result jsonb;
begin
  select * into f from public.watchguard_findings where id = p_finding_id and status = 'open';
  if not found then raise exception 'Finding % not found or not open.', p_finding_id; end if;

  select * into a from public.watchguard_ai_actions where finding_id = p_finding_id;

  -- Execute the action as an immutable offsetting event.
  v_event := public.watchguard_write_event(
    'ai_action:' || f.proposed_action, 'watchguard_findings', 'UPDATE', f.company_id,
    p_user_id, 'authenticated', 'watchguard_findings', f.id,
    f.proposed_action, to_jsonb(f), jsonb_build_object('approved_by', p_user_id, 'approval_reason', p_reason, 'payload', f.proposed_payload),
    p_reason, a.model_identity
  );

  update public.watchguard_findings set
    status = 'approved',
    approved_by = p_user_id,
    approved_at = now(),
    approval_reason = p_reason,
    resolved_event_id = v_event.id
  where id = p_finding_id;

  update public.watchguard_ai_actions set
    approved_by = p_user_id,
    executed_at = now(),
    outcome_event_id = v_event.id
  where finding_id = p_finding_id;

  -- Apply simple, safe compensations where they are pure event writes:
  -- (Actual row mutations can be added here behind additional safety checks.)

  v_result := jsonb_build_object('status', 'approved', 'finding_id', p_finding_id, 'event_id', v_event.id);
  return v_result;
end;
$$;

CREATE OR REPLACE FUNCTION public.watchguard_reject_action(
  p_finding_id uuid,
  p_user_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  f public.watchguard_findings%rowtype;
  a public.watchguard_ai_actions%rowtype;
  v_event public.watchguard_events%rowtype;
  v_result jsonb;
begin
  select * into f from public.watchguard_findings where id = p_finding_id and status = 'open';
  if not found then raise exception 'Finding % not found or not open.', p_finding_id; end if;

  select * into a from public.watchguard_ai_actions where finding_id = p_finding_id;

  v_event := public.watchguard_write_event(
    'ai_action:rejected', 'watchguard_findings', 'UPDATE', f.company_id,
    p_user_id, 'authenticated', 'watchguard_findings', f.id,
    f.proposed_action, to_jsonb(f), jsonb_build_object('rejected_by', p_user_id, 'rejection_reason', p_reason, 'payload', f.proposed_payload),
    p_reason, a.model_identity
  );

  update public.watchguard_findings set
    status = 'rejected',
    rejected_by = p_user_id,
    rejected_at = now(),
    rejection_reason = p_reason,
    resolved_event_id = v_event.id
  where id = p_finding_id;

  update public.watchguard_ai_actions set
    rejected_by = p_user_id,
    executed_at = now()
  where finding_id = p_finding_id;

  v_result := jsonb_build_object('status', 'rejected', 'finding_id', p_finding_id, 'event_id', v_event.id);
  return v_result;
end;
$$;

-- 8. Dashboard RPCs.
CREATE OR REPLACE FUNCTION public.watchguard_open_findings(p_company_id uuid DEFAULT NULL)
RETURNS TABLE (
  id uuid,
  company_id uuid,
  company_name text,
  severity text,
  status text,
  rule_name text,
  description text,
  proposed_action text,
  proposed_payload jsonb,
  created_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    f.id, f.company_id, c.name, f.severity, f.status, f.rule_name, f.description,
    f.proposed_action, f.proposed_payload, f.created_at
  from public.watchguard_findings f
  left join public.companies c on c.id = f.company_id
  where f.status = 'open'
    and (p_company_id is null or f.company_id = p_company_id)
  order by
    case f.severity when 'critical' then 1 when 'warning' then 2 else 3 end,
    f.created_at desc;
$$;

CREATE OR REPLACE FUNCTION public.watchguard_event_log(p_company_id uuid DEFAULT NULL, p_limit integer DEFAULT 100)
RETURNS TABLE (
  id uuid,
  event_type text,
  company_id uuid,
  company_name text,
  actor_role text,
  action_name text,
  target_table text,
  target_id uuid,
  created_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    e.id, e.event_type, e.company_id, c.name, e.actor_role, e.action_name,
    e.target_table, e.target_id, e.created_at
  from public.watchguard_events e
  left join public.companies c on c.id = e.company_id
  where p_company_id is null or e.company_id = p_company_id
  order by e.created_at desc
  limit p_limit;
$$;

-- Grants
GRANT EXECUTE ON FUNCTION public.watchguard_ai_action(uuid, text, jsonb, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_approve_action(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_reject_action(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_open_findings(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_event_log(uuid, integer) TO authenticated;
