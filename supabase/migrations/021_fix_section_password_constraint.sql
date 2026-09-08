-- Allow 'watchguard' as a valid platform section password entry.
-- Defensive: only alters the constraint if it exists.

do $$
begin
  if exists (
    select 1 from information_schema.table_constraints
    where table_name = 'platform_section_passwords'
      and constraint_name = 'platform_section_passwords_section_check'
  ) then
    alter table public.platform_section_passwords
    drop constraint platform_section_passwords_section_check;

    alter table public.platform_section_passwords
    add constraint platform_section_passwords_section_check
    check (section in ('gate', 'owner', 'registry', 'accounts', 'watchguard'));
  end if;
end;
$$;
