-- Phase 3: RBAC & Multi-Admin.

-- Add role and contact columns to admin_users if not present.
ALTER TABLE public.admin_users
  ADD COLUMN IF NOT EXISTS role text DEFAULT 'owner',
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS invited_by uuid,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS last_sign_in_at timestamptz;

-- Backfill existing admin_users from system_role to role for compatibility.
UPDATE public.admin_users
SET role = CASE
  WHEN system_role = 'view_only' THEN 'viewer'
  WHEN system_role = 'payroll_manager' THEN 'payroll_officer'
  WHEN system_role = 'hr' THEN 'admin'
  WHEN system_role = 'super_admin' THEN 'owner'
  ELSE 'owner'
END
WHERE role IS NULL OR role = '' OR role NOT IN ('owner', 'admin', 'manager', 'payroll_officer', 'viewer');

-- Role constraint.
ALTER TABLE public.admin_users
  DROP CONSTRAINT IF EXISTS admin_users_role_check,
  ADD CONSTRAINT admin_users_role_check CHECK (role IN ('owner', 'admin', 'manager', 'payroll_officer', 'viewer'));

-- Permission catalog.
CREATE TABLE IF NOT EXISTS public.role_permissions (
  role text NOT NULL,
  permission text NOT NULL,
  PRIMARY KEY (role, permission)
);

TRUNCATE public.role_permissions RESTART IDENTITY;

-- Owner: all permissions.
INSERT INTO public.role_permissions (role, permission) VALUES
  ('owner', 'manage_staff'), ('owner', 'manage_sites'), ('owner', 'manage_payroll'), ('owner', 'manage_payments'),
  ('owner', 'manage_settings'), ('owner', 'view_reports'), ('owner', 'manage_admins'), ('owner', 'broadcast_notifications'),
  ('owner', 'use_watchguard'), ('owner', 'export_data');

-- Admin: nearly all except manage_admins? admin can manage most.
INSERT INTO public.role_permissions (role, permission) VALUES
  ('admin', 'manage_staff'), ('admin', 'manage_sites'), ('admin', 'manage_payroll'), ('admin', 'manage_payments'),
  ('admin', 'manage_settings'), ('admin', 'view_reports'), ('admin', 'broadcast_notifications'),
  ('admin', 'use_watchguard'), ('admin', 'export_data');

-- Manager: staff and sites, view reports.
INSERT INTO public.role_permissions (role, permission) VALUES
  ('manager', 'manage_staff'), ('manager', 'manage_sites'), ('manager', 'view_reports'), ('manager', 'broadcast_notifications');

-- Payroll officer: payroll and payments.
INSERT INTO public.role_permissions (role, permission) VALUES
  ('payroll_officer', 'manage_payroll'), ('payroll_officer', 'manage_payments'), ('payroll_officer', 'view_reports');

-- Viewer: read-only.
INSERT INTO public.role_permissions (role, permission) VALUES
  ('viewer', 'view_reports');

-- Admin invites table.
CREATE TABLE IF NOT EXISTS public.admin_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  email text,
  role text NOT NULL DEFAULT 'manager',
  created_by uuid,
  used_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '7 days'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_invites_company_idx ON public.admin_invites (company_id, used_at);

-- Check permission.
CREATE OR REPLACE FUNCTION public.has_permission(p_admin_id uuid, p_permission text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select exists (
    select 1
    from public.admin_users au
    join public.role_permissions rp on rp.role = au.role
    where au.id = p_admin_id
      and au.is_active = true
      and rp.permission = p_permission
  );
$$;

-- Get permissions for an admin.
CREATE OR REPLACE FUNCTION public.my_permissions(p_admin_id uuid)
RETURNS TABLE (permission text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  select rp.permission
  from public.admin_users au
  join public.role_permissions rp on rp.role = au.role
  where au.id = p_admin_id
    and au.is_active = true;
$$;

-- List admins for a company.
CREATE OR REPLACE FUNCTION public.admin_list_company(p_company_id uuid)
RETURNS TABLE (
  id uuid,
  email text,
  role text,
  is_active boolean,
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
    au.created_at,
    au.last_sign_in_at
  from public.admin_users au
  where au.company_id = p_company_id
  order by au.created_at desc;
$$;

-- Create an admin invite.
CREATE OR REPLACE FUNCTION public.admin_create_invite(
  p_company_id uuid,
  p_email text,
  p_role text,
  p_created_by uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_code text;
begin
  if not public.has_permission(p_created_by, 'manage_admins') and not exists (
    select 1 from public.admin_users where id = p_created_by and role = 'owner'
  ) then
    raise exception 'You do not have permission to invite admins.';
  end if;

  v_code := upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 8));

  insert into public.admin_invites (code, company_id, email, role, created_by, expires_at)
  values (v_code, p_company_id, p_email, p_role, p_created_by, now() + interval '7 days');

  return v_code;
end;
$$;

-- Accept an admin invite.
CREATE OR REPLACE FUNCTION public.admin_accept_invite(
  p_code text,
  p_user_id uuid,
  p_email text DEFAULT NULL
)
RETURNS public.admin_users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_invite public.admin_invites%rowtype;
  v_user public.admin_users%rowtype;
begin
  select * into v_invite
  from public.admin_invites
  where code = upper(p_code)
    and used_at is null
    and expires_at > now();

  if not found then
    raise exception 'Invalid or expired invite code.';
  end if;

  insert into public.admin_users (id, company_id, email, role, is_active, invited_by, created_at)
  values (p_user_id, v_invite.company_id, coalesce(p_email, v_invite.email), v_invite.role, true, v_invite.created_by, now())
  on conflict (id) do update set
    company_id = excluded.company_id,
    email = coalesce(excluded.email, public.admin_users.email),
    role = excluded.role,
    is_active = true,
    invited_by = excluded.invited_by
  returning * into v_user;

  update public.admin_invites set used_at = now() where id = v_invite.id;
  return v_user;
end;
$$;

-- Update admin role (only owner or manage_admins).
CREATE OR REPLACE FUNCTION public.admin_update_role(
  p_actor_id uuid,
  p_admin_id uuid,
  p_role text
)
RETURNS public.admin_users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_actor public.admin_users%rowtype;
  v_target public.admin_users%rowtype;
begin
  select * into v_actor from public.admin_users where id = p_actor_id;
  select * into v_target from public.admin_users where id = p_admin_id;

  if not found then raise exception 'Admin not found.'; end if;

  -- Owner can change anyone; admin with manage_admins can change non-owners.
  if v_actor.role <> 'owner' and not public.has_permission(p_actor_id, 'manage_admins') then
    raise exception 'Permission denied.';
  end if;

  if v_target.role = 'owner' and v_actor.id <> v_target.id then
    raise exception 'Cannot modify the owner role.';
  end if;

  update public.admin_users set role = p_role where id = p_admin_id
  returning * into v_target;
  return v_target;
end;
$$;

-- Deactivate admin (only owner or manage_admins).
CREATE OR REPLACE FUNCTION public.admin_deactivate(
  p_actor_id uuid,
  p_admin_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_actor public.admin_users%rowtype;
  v_target public.admin_users%rowtype;
begin
  select * into v_actor from public.admin_users where id = p_actor_id;
  select * into v_target from public.admin_users where id = p_admin_id;

  if not found then return false; end if;

  if v_actor.role <> 'owner' and not public.has_permission(p_actor_id, 'manage_admins') then
    raise exception 'Permission denied.';
  end if;

  if v_target.role = 'owner' then
    raise exception 'Cannot deactivate the owner.';
  end if;

  update public.admin_users set is_active = false where id = p_admin_id;
  return true;
end;
$$;

-- Audit permission changes.
CREATE OR REPLACE FUNCTION public.admin_role_change_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  if old.role is distinct from new.role or old.is_active is distinct from new.is_active then
    perform public.watchguard_write_event(
      'admin_role_change', 'admin_users', 'UPDATE', new.company_id, auth.uid(),
      coalesce(auth.role(), 'authenticated'), 'admin_users', new.id,
      NULL, jsonb_build_object('role', old.role, 'is_active', old.is_active),
      jsonb_build_object('role', new.role, 'is_active', new.is_active), NULL, NULL
    );
  end if;
  return new;
end;
$$;

DROP TRIGGER IF EXISTS admin_role_change_trigger ON public.admin_users;
CREATE TRIGGER admin_role_change_trigger
AFTER UPDATE OF role, is_active ON public.admin_users
FOR EACH ROW EXECUTE FUNCTION public.admin_role_change_trigger();

GRANT EXECUTE ON FUNCTION public.has_permission(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_permissions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_company(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_invite(uuid, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_accept_invite(text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_role(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_deactivate(uuid, uuid) TO authenticated;
