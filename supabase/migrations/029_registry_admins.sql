-- Move admin management into Registry side for platform support team.
-- These RPCs assume Registry access is already gated by platform section password.

-- List all admins across all companies (registry view).
CREATE OR REPLACE FUNCTION public.registry_admin_list_all()
RETURNS TABLE (
  id uuid,
  email text,
  role text,
  is_active boolean,
  company_id uuid,
  company_name text,
  created_at timestamptz,
  last_sign_in_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select
    au.id,
    au.email,
    au.role,
    au.is_active,
    au.company_id,
    c.name as company_name,
    au.created_at,
    au.last_sign_in_at
  from public.admin_users au
  left join public.companies c on c.id = au.company_id
  order by c.name, au.created_at desc;
$$;

-- Create an admin invite for a specific company from the registry side.
CREATE OR REPLACE FUNCTION public.registry_admin_invite(
  p_company_id uuid,
  p_email text,
  p_role text,
  p_created_by uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_code text;
begin
  if p_company_id is null or p_email is null or p_role is null then
    raise exception 'Company, email, and role are required.';
  end if;

  v_code := upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 8));

  insert into public.admin_invites (code, company_id, email, role, created_by, expires_at)
  values (v_code, p_company_id, p_email, p_role, p_created_by, now() + interval '7 days');

  return v_code;
end;
$$;

-- Update an admin role from the registry side (no company-scoped permission check).
CREATE OR REPLACE FUNCTION public.registry_admin_update_role(
  p_admin_id uuid,
  p_role text
)
RETURNS public.admin_users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_target public.admin_users%rowtype;
begin
  select * into v_target from public.admin_users where id = p_admin_id;
  if not found then raise exception 'Admin not found.'; end if;

  update public.admin_users set role = p_role where id = p_admin_id
  returning * into v_target;
  return v_target;
end;
$$;

-- Deactivate an admin from the registry side.
CREATE OR REPLACE FUNCTION public.registry_admin_deactivate(
  p_admin_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  update public.admin_users set is_active = false where id = p_admin_id;
  return found;
end;
$$;

GRANT EXECUTE ON FUNCTION public.registry_admin_list_all() TO authenticated;
GRANT EXECUTE ON FUNCTION public.registry_admin_invite(uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registry_admin_update_role(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registry_admin_deactivate(uuid) TO authenticated;
