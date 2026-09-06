-- =============================================================================
-- METOSYNC PAYMENT GATEWAY MODULE
-- Multi-tenant Banking & Disbursal Infrastructure for Ghana
-- =============================================================================

-- Create Ghana Bank Registry
create table if not exists public.ghana_banks (
  id uuid primary key default gen_random_uuid(),
  bank_code text not null unique,
  bank_name text not null,
  swift_code text not null,
  ghipss_code text not null,
  provider_type text not null check (provider_type in ('bank', 'momo')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists ghana_banks_code_idx on public.ghana_banks (bank_code);
create index if not exists ghana_banks_provider_idx on public.ghana_banks (provider_type);

-- Insert reference Ghanaian banks
insert into public.ghana_banks (bank_code, bank_name, swift_code, ghipss_code, provider_type) values
  ('GCB', 'Ghana Commercial Bank', 'GCBLGHAC', 'GCB001', 'bank'),
  ('ECOBANK', 'Ecobank Ghana', 'ECOCGHAC', 'ECO001', 'bank'),
  ('FIDELITY', 'Fidelity Bank Ghana', 'FIDBGHAC', 'FID001', 'bank'),
  ('STANDARD', 'Standard Chartered Bank Ghana', 'SCBLGHAC', 'SCB001', 'bank'),
  ('BARCLAYS', 'Barclays Bank Ghana', 'BARXGHAC', 'BAR001', 'bank'),
  ('GTB', 'Guaranty Trust Bank Ghana', 'GTBLGHAC', 'GTB001', 'bank'),
  ('MTN_MOMO', 'MTN Mobile Money', 'MTNMGHAC', 'MTN001', 'momo'),
  ('TELECEL_MOMO', 'Telecel Cash', 'TELCGHAC', 'TEL001', 'momo'),
  ('AT_MONEY', 'AT Money', 'ATMGGHAC', 'ATM001', 'momo')
on conflict (bank_code) do nothing;

-- Employee Payment Destinations (attached to staff)
create table if not exists public.staff_payment_destinations (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null unique references public.staff(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  
  -- Payment Type: bank or momo
  payment_method text not null check (payment_method in ('bank', 'momo')),
  
  -- Bank Account Details
  account_holder_name text,
  account_number text,
  bank_code text references public.ghana_banks(bank_code),
  
  -- Mobile Money Details
  momo_phone text,
  momo_provider_code text references public.ghana_banks(bank_code),
  
  -- Verification
  is_verified boolean default false,
  verification_status text check (verification_status in ('pending', 'verified', 'failed')),
  verification_timestamp timestamptz,
  verification_reference text,
  
  -- Constraints
  is_active boolean default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  
  constraint payment_destination_check check (
    (payment_method = 'bank' and account_number is not null and bank_code is not null) or
    (payment_method = 'momo' and momo_phone is not null and momo_provider_code is not null)
  )
);

create index if not exists staff_payment_dest_company_idx on public.staff_payment_destinations (company_id);
create index if not exists staff_payment_dest_verified_idx on public.staff_payment_destinations (is_verified);

-- Payroll Runs (Batch containers)
create table if not exists public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  
  period_start date not null,
  period_end date not null,
  
  currency text not null default 'GHS',
  total_staff integer not null default 0,
  total_gross_amount numeric(15,2) not null default 0.00,
  total_deductions numeric(15,2) not null default 0.00,
  total_net_amount numeric(15,2) not null default 0.00,
  
  status text not null default 'draft' check (status in ('draft', 'validated', 'submitted', 'processing', 'completed', 'failed', 'partial')),
  
  created_by uuid references public.admin_users(id),
  submitted_at timestamptz,
  completed_at timestamptz,
  
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  
  constraint period_date_check check (period_end >= period_start)
);

create index if not exists payroll_runs_company_idx on public.payroll_runs (company_id);
create index if not exists payroll_runs_status_idx on public.payroll_runs (status);
create index if not exists payroll_runs_period_idx on public.payroll_runs (period_start, period_end);

-- Payroll Transactions (Individual payouts)
create table if not exists public.payroll_transactions (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid not null references public.payroll_runs(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete restrict,
  
  -- Idempotency key (UUIDv4 from company_id + employee_id + payroll_month)
  idempotency_key text not null unique,
  
  -- Payment Details
  gross_amount numeric(15,2) not null,
  total_deductions numeric(15,2) not null default 0.00,
  net_amount numeric(15,2) not null,
  currency text not null default 'GHS',
  
  -- Payment Destination
  payment_method text not null check (payment_method in ('bank', 'momo')),
  payment_destination_id uuid references public.staff_payment_destinations(id),
  
  -- Provider Routing
  bank_code text references public.ghana_banks(bank_code),
  account_number text,
  momo_phone text,
  
  -- Transaction Status
  status text not null default 'pending' check (
    status in ('pending', 'queued', 'processing', 'success', 'failed', 'reversed', 'timeout')
  ),
  
  -- Gateway Reference IDs
  gateway_reference_id text unique,
  provider_transaction_id text,
  
  -- Error Tracking
  error_code text,
  error_message text,
  
  -- Audit
  attempted_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists payroll_txn_payroll_run_idx on public.payroll_transactions (payroll_run_id);
create index if not exists payroll_txn_company_idx on public.payroll_transactions (company_id);
create index if not exists payroll_txn_staff_idx on public.payroll_transactions (staff_id);
create index if not exists payroll_txn_idempotency_idx on public.payroll_transactions (idempotency_key);
create index if not exists payroll_txn_status_idx on public.payroll_transactions (status);
create index if not exists payroll_txn_gateway_ref_idx on public.payroll_transactions (gateway_reference_id);

-- Payment Gateway Configuration (per tenant)
create table if not exists public.gateway_config (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null unique references public.companies(id) on delete cascade,
  
  -- Gateway Selection
  primary_gateway text not null check (primary_gateway in ('paystack', 'hubtel', 'mock')),
  fallback_gateway text,
  
  -- Credentials (encrypted at application layer)
  gateway_secret_key_hash text not null,
  gateway_public_key text,
  merchant_id text,
  
  -- Configuration
  auto_retry_failed boolean default true,
  max_retry_attempts integer default 3,
  webhook_url text,
  webhook_secret_hash text,
  
  is_production boolean default false,
  is_active boolean default false,
  
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists gateway_config_company_idx on public.gateway_config (company_id);
create index if not exists gateway_config_active_idx on public.gateway_config (is_active);

-- Webhook Event Log
create table if not exists public.gateway_webhooks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  
  event_type text not null,
  gateway_reference_id text,
  webhook_payload jsonb not null,
  webhook_signature text,
  
  is_verified boolean default false,
  processed_at timestamptz,
  
  created_at timestamptz not null default now()
);

create index if not exists gateway_webhooks_company_idx on public.gateway_webhooks (company_id);
create index if not exists gateway_webhooks_reference_idx on public.gateway_webhooks (gateway_reference_id);
create index if not exists gateway_webhooks_event_idx on public.gateway_webhooks (event_type);

-- =============================================================================
-- RPC: VALIDATE PAYMENT DESTINATION
-- Resolves account with payment gateway before enqueueing transaction
-- =============================================================================

create or replace function public.validate_payment_destination(
  p_company_id uuid,
  p_staff_id uuid,
  p_payment_method text,
  p_account_details jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_destination public.staff_payment_destinations%rowtype;
  v_gateway_config public.gateway_config%rowtype;
  v_bank public.ghana_banks%rowtype;
  v_result jsonb;
begin
  -- Retrieve or create payment destination
  select * into v_destination
  from public.staff_payment_destinations
  where staff_id = p_staff_id and company_id = p_company_id;

  if v_destination.id is null then
    insert into public.staff_payment_destinations (staff_id, company_id, payment_method)
    values (p_staff_id, p_company_id, p_payment_method)
    returning * into v_destination;
  end if;

  -- Validate based on payment method
  if p_payment_method = 'bank' then
    v_bank := null;
    select * into v_bank
    from public.ghana_banks
    where bank_code = (p_account_details->>'bank_code')
      and provider_type = 'bank'
      and is_active = true;

    if v_bank.id is null then
      return jsonb_build_object(
        'is_valid', false,
        'error', 'Invalid or inactive bank code',
        'error_code', 'INVALID_BANK'
      );
    end if;

    -- TODO: In production, call Paystack/Hubtel resolve account endpoint
    -- For now, perform basic validation
    if (p_account_details->>'account_number') is null or
       length(trim(p_account_details->>'account_number')) < 8 then
      return jsonb_build_object(
        'is_valid', false,
        'error', 'Invalid account number format',
        'error_code', 'INVALID_ACCOUNT'
      );
    end if;

    update public.staff_payment_destinations
    set account_number = p_account_details->>'account_number',
        bank_code = p_account_details->>'bank_code',
        account_holder_name = p_account_details->>'account_holder_name',
        is_verified = true,
        verification_status = 'verified',
        verification_timestamp = now(),
        updated_at = now()
    where id = v_destination.id;

  elsif p_payment_method = 'momo' then
    v_bank := null;
    select * into v_bank
    from public.ghana_banks
    where bank_code = (p_account_details->>'momo_provider_code')
      and provider_type = 'momo'
      and is_active = true;

    if v_bank.id is null then
      return jsonb_build_object(
        'is_valid', false,
        'error', 'Invalid or inactive mobile money provider',
        'error_code', 'INVALID_MOMO_PROVIDER'
      );
    end if;

    -- Validate phone format (allow various Ghana formats: 024XXXXXXX, +233XXXXXXXXX, etc.)
    if (p_account_details->>'momo_phone') is null or
       not ((p_account_details->>'momo_phone') ~ '^\+233[0-9]{9}$' or
            (p_account_details->>'momo_phone') ~ '^0[2-9][0-9]{8}$') then
      return jsonb_build_object(
        'is_valid', false,
        'error', 'Invalid mobile money phone format',
        'error_code', 'INVALID_PHONE_FORMAT'
      );
    end if;

    update public.staff_payment_destinations
    set momo_phone = p_account_details->>'momo_phone',
        momo_provider_code = p_account_details->>'momo_provider_code',
        is_verified = true,
        verification_status = 'verified',
        verification_timestamp = now(),
        updated_at = now()
    where id = v_destination.id;
  else
    return jsonb_build_object(
      'is_valid', false,
      'error', 'Unsupported payment method',
      'error_code', 'UNSUPPORTED_METHOD'
    );
  end if;

  return jsonb_build_object(
    'is_valid', true,
    'destination_id', v_destination.id,
    'payment_method', p_payment_method,
    'verified_at', now()
  );
end;
$$;

-- =============================================================================
-- RPC: GENERATE IDEMPOTENCY KEY
-- Creates deterministic UUIDv5 from company + employee + payroll month
-- =============================================================================

create or replace function public.generate_idempotency_key(
  p_company_id uuid,
  p_staff_id uuid,
  p_payroll_period_start date
)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select encode(
    digest(
      concat(
        p_company_id::text, '|',
        p_staff_id::text, '|',
        to_char(p_payroll_period_start, 'YYYY-MM')
      ),
      'sha256'
    ),
    'hex'
  );
$$;

-- =============================================================================
-- RPC: QUEUE PAYROLL TRANSACTION
-- Creates transaction record with idempotency and validation
-- =============================================================================

create or replace function public.queue_payroll_transaction(
  p_payroll_run_id uuid,
  p_company_id uuid,
  p_staff_id uuid,
  p_gross_amount numeric,
  p_deductions numeric,
  p_net_amount numeric,
  p_payment_destination_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_idempotency_key text;
  v_destination public.staff_payment_destinations%rowtype;
  v_payroll_run public.payroll_runs%rowtype;
  v_transaction public.payroll_transactions%rowtype;
  v_result jsonb;
begin
  -- Retrieve payroll run
  select * into v_payroll_run
  from public.payroll_runs
  where id = p_payroll_run_id and company_id = p_company_id;

  if v_payroll_run.id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Payroll run not found',
      'error_code', 'PAYROLL_RUN_NOT_FOUND'
    );
  end if;

  -- Retrieve payment destination
  select * into v_destination
  from public.staff_payment_destinations
  where id = p_payment_destination_id and staff_id = p_staff_id;

  if v_destination.id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Payment destination not verified',
      'error_code', 'PAYMENT_DESTINATION_NOT_VERIFIED'
    );
  end if;

  if v_destination.is_verified = false then
    return jsonb_build_object(
      'success', false,
      'error', 'Payment destination not verified',
      'error_code', 'PAYMENT_DESTINATION_UNVERIFIED'
    );
  end if;

  -- Generate deterministic idempotency key
  v_idempotency_key := public.generate_idempotency_key(
    p_company_id,
    p_staff_id,
    v_payroll_run.period_start
  );

  -- Check for duplicate (idempotency)
  select * into v_transaction
  from public.payroll_transactions
  where idempotency_key = v_idempotency_key;

  if v_transaction.id is not null then
    return jsonb_build_object(
      'success', true,
      'is_duplicate', true,
      'transaction_id', v_transaction.id,
      'message', 'Transaction already queued for this period'
    );
  end if;

  -- Create new transaction
  insert into public.payroll_transactions (
    payroll_run_id, company_id, staff_id,
    idempotency_key,
    gross_amount, total_deductions, net_amount,
    payment_method, payment_destination_id,
    bank_code, account_number, momo_phone,
    status
  )
  values (
    p_payroll_run_id, p_company_id, p_staff_id,
    v_idempotency_key,
    p_gross_amount, p_deductions, p_net_amount,
    v_destination.payment_method, v_destination.id,
    v_destination.bank_code, v_destination.account_number, v_destination.momo_phone,
    'pending'
  )
  returning * into v_transaction;

  return jsonb_build_object(
    'success', true,
    'is_duplicate', false,
    'transaction_id', v_transaction.id,
    'idempotency_key', v_transaction.idempotency_key,
    'status', v_transaction.status,
    'net_amount', v_transaction.net_amount
  );
end;
$$;

-- =============================================================================
-- RPC: SUBMIT PAYROLL RUN
-- Validates entire batch and prepares for gateway submission
-- =============================================================================

create or replace function public.submit_payroll_run(
  p_payroll_run_id uuid,
  p_company_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payroll_run public.payroll_runs%rowtype;
  v_total_transactions integer;
  v_unverified_destinations integer;
  v_result jsonb;
begin
  select * into v_payroll_run
  from public.payroll_runs
  where id = p_payroll_run_id and company_id = p_company_id;

  if v_payroll_run.id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Payroll run not found'
    );
  end if;

  if v_payroll_run.status != 'draft' then
    return jsonb_build_object(
      'success', false,
      'error', 'Payroll run is not in draft status',
      'current_status', v_payroll_run.status
    );
  end if;

  -- Count transactions
  select count(*) into v_total_transactions
  from public.payroll_transactions
  where payroll_run_id = p_payroll_run_id;

  if v_total_transactions = 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'No transactions queued for this payroll run'
    );
  end if;

  -- Check for unverified payment destinations
  select count(*) into v_unverified_destinations
  from public.payroll_transactions pt
  left join public.staff_payment_destinations spd on pt.payment_destination_id = spd.id
  where pt.payroll_run_id = p_payroll_run_id
    and (spd.is_verified = false or spd.is_verified is null);

  if v_unverified_destinations > 0 then
    return jsonb_build_object(
      'success', false,
      'error', 'Some payment destinations are not verified',
      'unverified_count', v_unverified_destinations
    );
  end if;

  -- Update run status
  update public.payroll_runs
  set status = 'validated',
      submitted_at = now(),
      updated_at = now()
  where id = p_payroll_run_id;

  -- Mark all pending transactions as queued
  update public.payroll_transactions
  set status = 'queued',
      updated_at = now()
  where payroll_run_id = p_payroll_run_id and status = 'pending';

  return jsonb_build_object(
    'success', true,
    'payroll_run_id', p_payroll_run_id,
    'status', 'validated',
    'total_transactions', v_total_transactions,
    'total_amount', v_payroll_run.total_net_amount
  );
end;
$$;

-- =============================================================================
-- RPC: UPDATE TRANSACTION STATUS (Called by webhook handler)
-- =============================================================================

create or replace function public.update_payroll_transaction_status(
  p_transaction_id uuid,
  p_status text,
  p_gateway_reference_id text,
  p_provider_transaction_id text,
  p_error_code text default null,
  p_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.payroll_transactions%rowtype;
begin
  select * into v_transaction
  from public.payroll_transactions
  where id = p_transaction_id;

  if v_transaction.id is null then
    return jsonb_build_object(
      'success', false,
      'error', 'Transaction not found'
    );
  end if;

  update public.payroll_transactions
  set status = p_status,
      gateway_reference_id = coalesce(p_gateway_reference_id, gateway_reference_id),
      provider_transaction_id = coalesce(p_provider_transaction_id, provider_transaction_id),
      error_code = p_error_code,
      error_message = p_error_message,
      completed_at = case when p_status in ('success', 'failed', 'reversed') then now() else completed_at end,
      updated_at = now()
  where id = p_transaction_id;

  return jsonb_build_object(
    'success', true,
    'transaction_id', p_transaction_id,
    'status', p_status,
    'gateway_reference_id', p_gateway_reference_id
  );
end;
$$;

grant execute on function public.validate_payment_destination(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.generate_idempotency_key(uuid, uuid, date) to authenticated;
grant execute on function public.queue_payroll_transaction(uuid, uuid, uuid, numeric, numeric, numeric, uuid) to authenticated;
grant execute on function public.submit_payroll_run(uuid, uuid) to authenticated;
grant execute on function public.update_payroll_transaction_status(uuid, text, text, text, text, text) to authenticated;
