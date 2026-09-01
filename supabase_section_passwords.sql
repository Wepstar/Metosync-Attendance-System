-- ==============================================================================
-- SECTION PASSWORDS FIX (Owner Dashboard, Registry, Accounts)
-- ==============================================================================
-- Run this in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/lqgdyjvfirdhstcmepyr/sql/new
-- ==============================================================================

-- Enable pgcrypto extension for bcrypt hashing
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.platform_section_passwords (
  section TEXT PRIMARY KEY,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.platform_section_passwords ENABLE ROW LEVEL SECURITY;

-- 1. Check if section password is set
CREATE OR REPLACE FUNCTION public.section_password_is_set(p_section TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.platform_section_passwords 
    WHERE section = p_section
  );
END;
$$;

-- 2. Set section password
CREATE OR REPLACE FUNCTION public.set_section_password(p_section TEXT, p_password TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF length(p_password) < 1 THEN
    RAISE EXCEPTION 'Password cannot be empty';
  END IF;

  INSERT INTO public.platform_section_passwords (section, password_hash, updated_at)
  VALUES (p_section, extensions.crypt(p_password, extensions.gen_salt('bf')), now())
  ON CONFLICT (section) DO UPDATE 
  SET password_hash = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now();
END;
$$;

-- 3. Verify section password
CREATE OR REPLACE FUNCTION public.verify_section_password(p_section TEXT, p_password TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash TEXT;
BEGIN
  SELECT password_hash INTO v_hash
  FROM public.platform_section_passwords
  WHERE section = p_section;

  IF v_hash IS NULL THEN
    RETURN FALSE;
  END IF;

  RETURN (v_hash = extensions.crypt(p_password, v_hash));
END;
$$;
