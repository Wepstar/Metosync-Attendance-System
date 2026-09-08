-- Phase 1: Notification & Escalation Engine for Watchguard.

-- Enable outbound HTTP if available (defensive; some Supabase plans require enabling).
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Notification channels per company/owner.
CREATE TABLE IF NOT EXISTS public.watchguard_notification_channels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid REFERENCES public.companies(id) ON DELETE CASCADE,
  channel_type text NOT NULL CHECK (channel_type IN ('email', 'sms', 'webhook')),
  label text NOT NULL,
  endpoint text NOT NULL,                -- email address, phone number, or webhook URL
  metadata jsonb DEFAULT '{}'::jsonb,    -- extra config: headers, from_name, region, etc.
  events_filter text[] DEFAULT ARRAY['critical', 'warning'],  -- severities to notify on
  enabled boolean NOT NULL DEFAULT true,
  is_global boolean NOT NULL DEFAULT false,  -- true means this channel is owned by platform owner
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS watchguard_notification_channels_company_idx ON public.watchguard_notification_channels (company_id, enabled);

-- Escalation attempts (notification queue).
CREATE TABLE IF NOT EXISTS public.watchguard_escalations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  finding_id uuid REFERENCES public.watchguard_findings(id) ON DELETE CASCADE,
  channel_id uuid REFERENCES public.watchguard_notification_channels(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
  payload jsonb NOT NULL,
  response_body text,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS watchguard_escalations_pending_idx ON public.watchguard_escalations (status, created_at);
CREATE INDEX IF NOT EXISTS watchguard_escalations_finding_idx ON public.watchguard_escalations (finding_id);

-- Config for the dispatch Edge Function URL.
CREATE TABLE IF NOT EXISTS public.watchguard_config (
  key text PRIMARY KEY,
  value text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.watchguard_config (key, value)
VALUES ('dispatch_edge_function_url', '')
ON CONFLICT (key) DO NOTHING;

-- List notification channels for a company or globally.
CREATE OR REPLACE FUNCTION public.watchguard_list_channels(p_company_id uuid DEFAULT NULL)
RETURNS SETOF public.watchguard_notification_channels
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select *
  from public.watchguard_notification_channels
  where (p_company_id is null and is_global = true)
     or (p_company_id is not null and (company_id = p_company_id or is_global = true))
  order by created_at desc;
$$;

-- Create a notification channel.
CREATE OR REPLACE FUNCTION public.watchguard_create_channel(
  p_company_id uuid,
  p_channel_type text,
  p_label text,
  p_endpoint text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_events_filter text[] DEFAULT ARRAY['critical', 'warning'],
  p_enabled boolean DEFAULT true,
  p_is_global boolean DEFAULT false
)
RETURNS public.watchguard_notification_channels
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.watchguard_notification_channels%rowtype;
begin
  insert into public.watchguard_notification_channels (
    company_id, channel_type, label, endpoint, metadata, events_filter, enabled, is_global, created_by
  ) values (
    p_company_id, p_channel_type, p_label, p_endpoint, p_metadata, p_events_filter, p_enabled, p_is_global, auth.uid()
  )
  returning * into v_row;
  return v_row;
end;
$$;

-- Update a notification channel.
CREATE OR REPLACE FUNCTION public.watchguard_update_channel(
  p_channel_id uuid,
  p_label text,
  p_endpoint text,
  p_metadata jsonb,
  p_events_filter text[],
  p_enabled boolean
)
RETURNS public.watchguard_notification_channels
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.watchguard_notification_channels%rowtype;
begin
  update public.watchguard_notification_channels
  set label = p_label,
      endpoint = p_endpoint,
      metadata = p_metadata,
      events_filter = p_events_filter,
      enabled = p_enabled,
      updated_at = now()
  where id = p_channel_id
  returning * into v_row;
  if not found then raise exception 'Channel not found'; end if;
  return v_row;
end;
$$;

-- Delete a notification channel.
CREATE OR REPLACE FUNCTION public.watchguard_delete_channel(p_channel_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  delete from public.watchguard_notification_channels where id = p_channel_id;
  return found;
end;
$$;

-- Build the payload for a notification.
CREATE OR REPLACE FUNCTION public.watchguard_build_payload(
  p_finding_id uuid,
  p_channel_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
declare
  f public.watchguard_findings%rowtype;
  c public.watchguard_notification_channels%rowtype;
  company_name text;
  payload jsonb;
begin
  select * into f from public.watchguard_findings where id = p_finding_id;
  select * into c from public.watchguard_notification_channels where id = p_channel_id;
  select name into company_name from public.companies where id = f.company_id;

  payload := jsonb_build_object(
    'escalation_id', gen_random_uuid(), -- temporary; replaced on insert
    'channel_type', c.channel_type,
    'endpoint', c.endpoint,
    'finding_id', f.id,
    'company_id', f.company_id,
    'company_name', coalesce(company_name, 'Unknown'),
    'severity', f.severity,
    'rule_name', f.rule_name,
    'description', f.description,
    'proposed_action', f.proposed_action,
    'created_at', f.created_at,
    'metadata', c.metadata
  );

  return payload;
end;
$$;

-- Escalate a finding: create escalation records for every matching channel.
CREATE OR REPLACE FUNCTION public.watchguard_escalate(p_finding_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  f public.watchguard_findings%rowtype;
  c public.watchguard_notification_channels%rowtype;
  v_count integer := 0;
  v_payload jsonb;
  v_edge_url text;
  v_escalation_id uuid;
begin
  select * into f from public.watchguard_findings where id = p_finding_id;
  if not found then return 0; end if;

  select value into v_edge_url from public.watchguard_config where key = 'dispatch_edge_function_url';

  for c in
    select *
    from public.watchguard_notification_channels
    where enabled = true
      and f.severity = any(events_filter)
      and (f.company_id is null or company_id = f.company_id or is_global = true)
  loop
    v_payload := public.watchguard_build_payload(p_finding_id, c.id);

    insert into public.watchguard_escalations (finding_id, channel_id, status, payload)
    values (p_finding_id, c.id, 'pending', v_payload)
    returning id into v_escalation_id;

    -- Update payload with the real escalation id
    update public.watchguard_escalations set payload = v_payload || jsonb_build_object('escalation_id', v_escalation_id)
    where id = v_escalation_id;

    -- Attempt dispatch via pg_net if an Edge Function URL is configured.
    if v_edge_url is not null and v_edge_url <> '' then
      begin
        perform net.http_post(
          url := v_edge_url,
          body := (v_payload || jsonb_build_object('escalation_id', v_escalation_id))::text,
          headers := '{"Content-Type": "application/json"}'::jsonb
        );
      exception when others then
        -- Leave as pending; dispatcher can retry.
        null;
      end;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Auto-escalate new findings.
CREATE OR REPLACE FUNCTION public.watchguard_finding_escalation_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  perform public.watchguard_escalate(new.id);
  return new;
end;
$$;

DROP TRIGGER IF EXISTS watchguard_finding_escalation_trigger ON public.watchguard_findings;
CREATE TRIGGER watchguard_finding_escalation_trigger
AFTER INSERT ON public.watchguard_findings
FOR EACH ROW EXECUTE FUNCTION public.watchguard_finding_escalation_trigger();

-- Config helpers.
CREATE OR REPLACE FUNCTION public.watchguard_set_config(p_key text, p_value text)
RETURNS public.watchguard_config
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.watchguard_config%rowtype;
begin
  insert into public.watchguard_config (key, value, updated_at)
  values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now()
  returning * into v_row;
  return v_row;
end;
$$;

CREATE OR REPLACE FUNCTION public.watchguard_get_config(p_key text)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select value from public.watchguard_config where key = p_key;
$$;

-- Mark escalation as sent/failed.
CREATE OR REPLACE FUNCTION public.watchguard_mark_escalation(
  p_escalation_id uuid,
  p_status text,
  p_response_body text DEFAULT NULL
)
RETURNS public.watchguard_escalations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_row public.watchguard_escalations%rowtype;
begin
  update public.watchguard_escalations
  set status = p_status,
      response_body = p_response_body,
      sent_at = now()
  where id = p_escalation_id
  returning * into v_row;
  return v_row;
end;
$$;

-- List pending escalations for the dispatcher (or dashboard).
CREATE OR REPLACE FUNCTION public.watchguard_pending_escalations(p_limit integer DEFAULT 100)
RETURNS TABLE (
  id uuid,
  finding_id uuid,
  channel_id uuid,
  channel_type text,
  endpoint text,
  payload jsonb,
  created_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    e.id, e.finding_id, e.channel_id, c.channel_type, c.endpoint, e.payload, e.created_at
  from public.watchguard_escalations e
  join public.watchguard_notification_channels c on c.id = e.channel_id
  where e.status = 'pending'
  order by e.created_at asc
  limit p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.watchguard_list_channels(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_create_channel(uuid, text, text, text, jsonb, text[], boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_update_channel(uuid, text, text, jsonb, text[], boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_delete_channel(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_escalate(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_mark_escalation(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_pending_escalations(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_set_config(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.watchguard_get_config(text) TO authenticated;
