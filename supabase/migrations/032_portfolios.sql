-- Portfolios: registry-managed role/access portfolios shown as tiles in the
-- platform Registry and used as the invite-role picker in admin.html.
-- Access model matches existing registry_* RPCs: SECURITY DEFINER, granted to
-- authenticated; Registry access is gated by the platform section password.

CREATE TABLE IF NOT EXISTS public.portfolios (
  code text PRIMARY KEY,
  display_name text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Seed defaults matching the existing admin_users RBAC roles so invite codes
-- stay valid for admin_accept_invite (role CHECK constraint).
INSERT INTO public.portfolios (code, display_name, description, is_active, sort_order) VALUES
  ('owner', 'Super Admin', 'Full control over company settings, staff, payroll, and data', true, 10),
  ('payroll_officer', 'Payroll Manager', 'Manage payroll runs, payments, and reports', true, 20),
  ('admin', 'HR', 'Manage staff, sites, attendance, and notifications', true, 30),
  ('viewer', 'View-Only', 'Read-only access to reports and dashboards', true, 40)
ON CONFLICT (code) DO NOTHING;

-- Registry: list all portfolios (active and inactive).
CREATE OR REPLACE FUNCTION public.registry_list_portfolios()
RETURNS TABLE (
  code text,
  display_name text,
  description text,
  is_active boolean,
  sort_order integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select p.code, p.display_name, p.description, p.is_active, p.sort_order
  from public.portfolios p
  order by p.sort_order, p.display_name;
$$;

-- Registry: add a new portfolio.
CREATE OR REPLACE FUNCTION public.registry_add_portfolio(
  p_code text,
  p_display_name text,
  p_description text DEFAULT NULL,
  p_sort_order integer DEFAULT 0
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_code text := lower(btrim(p_code));
begin
  if v_code = '' or p_display_name is null or btrim(p_display_name) = '' then
    raise exception 'Code and display name are required.';
  end if;
  insert into public.portfolios (code, display_name, description, sort_order)
  values (v_code, btrim(p_display_name), p_description, coalesce(p_sort_order, 0));
  return v_code;
end;
$$;

-- Registry: toggle a portfolio active/inactive.
CREATE OR REPLACE FUNCTION public.registry_set_portfolio_active(
  p_code text,
  p_is_active boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  update public.portfolios set is_active = p_is_active where code = p_code;
  return found;
end;
$$;

-- Company admin: list active portfolios for the invite-role tile grid.
CREATE OR REPLACE FUNCTION public.list_active_portfolios()
RETURNS TABLE (
  code text,
  display_name text,
  description text,
  sort_order integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select p.code, p.display_name, p.description, p.sort_order
  from public.portfolios p
  where p.is_active
  order by p.sort_order, p.display_name;
$$;

GRANT EXECUTE ON FUNCTION public.registry_list_portfolios() TO authenticated;
GRANT EXECUTE ON FUNCTION public.registry_add_portfolio(text, text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registry_set_portfolio_active(text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_active_portfolios() TO authenticated;
