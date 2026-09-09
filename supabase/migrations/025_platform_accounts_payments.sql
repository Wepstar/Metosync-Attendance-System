-- Consolidated Phase 2 payment schema and platform accounts dashboard support.
-- Run this if 023 failed or to add the platform payment RPCs.

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS public.payment_providers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid REFERENCES public.companies(id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider IN ('paystack', 'flutterwave', 'stripe')),
  public_key text,
  secret_key_encrypted text,
  webhook_secret text,
  currency text NOT NULL DEFAULT 'GHS',
  is_live boolean NOT NULL DEFAULT false,
  is_global boolean NOT NULL DEFAULT false,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, provider)
);

CREATE INDEX IF NOT EXISTS payment_providers_company_idx ON public.payment_providers (company_id, enabled);

CREATE TABLE IF NOT EXISTS public.payment_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  payroll_entry_id uuid REFERENCES public.payroll_entries(id) ON DELETE SET NULL,
  provider text NOT NULL CHECK (provider IN ('paystack', 'flutterwave', 'stripe')),
  amount numeric(12,2) NOT NULL,
  currency text NOT NULL DEFAULT 'GHS',
  reference text NOT NULL UNIQUE,
  provider_reference text,
  checkout_url text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'reversed')),
  metadata jsonb,
  paid_at timestamptz,
  reversed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payment_requests_company_idx ON public.payment_requests (company_id, status);
CREATE INDEX IF NOT EXISTS payment_requests_reference_idx ON public.payment_requests (reference);

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS payment_request_id uuid REFERENCES public.payment_requests(id) ON DELETE SET NULL;

ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS bank_account_number text,
  ADD COLUMN IF NOT EXISTS bank_code text,
  ADD COLUMN IF NOT EXISTS bank_name text;

-- Provider RPCs.
CREATE OR REPLACE FUNCTION public.watchguard_set_payment_provider(
  p_company_id uuid,
  p_provider text,
  p_public_key text,
  p_secret_key text,
  p_webhook_secret text,
  p_currency text,
  p_is_live boolean,
  p_enabled boolean
)
RETURNS public.payment_providers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.payment_providers%rowtype;
begin
  insert into public.payment_providers (
    company_id, provider, public_key, secret_key_encrypted, webhook_secret,
    currency, is_live, enabled, updated_at
  ) values (
    p_company_id, p_provider, p_public_key, p_secret_key, p_webhook_secret,
    p_currency, p_is_live, p_enabled, now()
  )
  on conflict (company_id, provider) do update set
    public_key = excluded.public_key,
    secret_key_encrypted = excluded.secret_key_encrypted,
    webhook_secret = excluded.webhook_secret,
    currency = excluded.currency,
    is_live = excluded.is_live,
    enabled = excluded.enabled,
    updated_at = now()
  returning * into v_row;
  return v_row;
end;
$$;

CREATE OR REPLACE FUNCTION public.watchguard_get_payment_provider(p_company_id uuid, p_provider text)
RETURNS public.payment_providers
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select *
  from public.payment_providers
  where (company_id = p_company_id or is_global = true)
    and provider = p_provider
    and enabled = true
  order by is_global asc
  limit 1;
$$;

CREATE OR REPLACE FUNCTION public.watchguard_list_payment_providers()
RETURNS SETOF public.payment_providers
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select * from public.payment_providers order by created_at desc;
$$;

-- Payroll payables.
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

-- Payment request lifecycle.
CREATE OR REPLACE FUNCTION public.payment_request_initiate(
  p_company_id uuid,
  p_staff_id uuid,
  p_payroll_entry_id uuid,
  p_amount numeric,
  p_currency text,
  p_reference text,
  p_provider text
)
RETURNS public.payment_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.payment_requests%rowtype;
  v_exists boolean;
begin
  select exists (select 1 from public.payment_requests where reference = p_reference) into v_exists;
  if v_exists then raise exception 'Payment reference already exists: %', p_reference; end if;

  insert into public.payment_requests (
    company_id, staff_id, payroll_entry_id, provider, amount, currency, reference, status
  ) values (
    p_company_id, p_staff_id, p_payroll_entry_id, p_provider, p_amount, p_currency, p_reference, 'pending'
  )
  returning * into v_row;
  return v_row;
end;
$$;

CREATE OR REPLACE FUNCTION public.payment_request_by_reference(p_reference text)
RETURNS public.payment_requests
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select * from public.payment_requests where reference = p_reference limit 1;
$$;

CREATE OR REPLACE FUNCTION public.payment_request_update(
  p_reference text,
  p_status text,
  p_provider_reference text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS public.payment_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.payment_requests%rowtype;
  v_payment public.payments%rowtype;
begin
  update public.payment_requests
  set status = p_status,
      provider_reference = coalesce(p_provider_reference, provider_reference),
      metadata = metadata || p_metadata,
      paid_at = case when p_status = 'completed' then now() else paid_at end,
      reversed_at = case when p_status = 'reversed' then now() else reversed_at end
  where reference = p_reference
  returning * into v_row;

  if not found then raise exception 'Payment request not found: %', p_reference; end if;

  if p_status = 'completed' and not exists (select 1 from public.payments where payment_request_id = v_row.id) then
    insert into public.payments (
      company_id, staff_id, payroll_entry_id, amount, currency, reference,
      provider, status, paid_at, payment_request_id, metadata
    ) values (
      v_row.company_id, v_row.staff_id, v_row.payroll_entry_id, v_row.amount, v_row.currency,
      v_row.reference, v_row.provider, 'completed', v_row.paid_at, v_row.id, v_row.metadata
    )
    returning * into v_payment;
  end if;

  return v_row;
end;
$$;

-- Platform-wide payment request listing and stats.
CREATE OR REPLACE FUNCTION public.watchguard_list_payment_requests(p_company_id uuid DEFAULT NULL)
RETURNS TABLE (
  id uuid,
  company_id uuid,
  company_name text,
  staff_id uuid,
  staff_name text,
  amount numeric,
  currency text,
  reference text,
  provider text,
  status text,
  created_at timestamptz,
  paid_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    pr.id,
    pr.company_id,
    c.name as company_name,
    pr.staff_id,
    s.full_name as staff_name,
    pr.amount,
    pr.currency,
    pr.reference,
    pr.provider,
    pr.status,
    pr.created_at,
    pr.paid_at
  from public.payment_requests pr
  join public.companies c on c.id = pr.company_id
  join public.staff s on s.id = pr.staff_id
  where p_company_id is null or pr.company_id = p_company_id
  order by pr.created_at desc;
$$;

CREATE OR REPLACE FUNCTION public.watchguard_payment_stats(p_company_id uuid DEFAULT NULL)
RETURNS TABLE (
  total_requests bigint,
  completed_amount numeric,
  pending_amount numeric,
  failed_amount numeric
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    count(*)::bigint as total_requests,
    coalesce(sum(case when pr.status = 'completed' then pr.amount else 0 end), 0) as completed_amount,
    coalesce(sum(case when pr.status = 'pending' or pr.status = 'processing' then pr.amount else 0 end), 0) as pending_amount,
    coalesce(sum(case when pr.status = 'failed' then pr.amount else 0 end), 0) as failed_amount
  from public.payment_requests pr
  where p_company_id is null or pr.company_id = p_company_id;
$$;

GRANT EXECUTE ON FUNCTION public.watchguard_set_payment_provider(uuid, text, text, text, text, text, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_get_payment_provider(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_list_payment_providers() TO authenticated;
GRANT EXECUTE ON FUNCTION public.payroll_payables(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.payment_request_initiate(uuid, uuid, uuid, numeric, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.payment_request_update(text, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.payment_request_by_reference(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_list_payment_requests(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_payment_stats(uuid) TO authenticated;
