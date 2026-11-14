-- =============================================================================
-- Migration: 20241101000024_staff_accounts.sql
-- Description: Staff accounts created by an administrator
--
-- Roster officers, check-in agents and ops managers do not sign up. An admin
-- creates their account (Edge Function admin-create-staff) with a temporary
-- password. This migration adds:
--
--   profiles.must_change_password  – set on creation / reset; the app forces a
--                                    new password before anything else
--   profiles.created_by            – which admin created the account
--   staff_clear_password_flag()    – the user clears their own flag after
--                                    changing the password
--   admin_staff_list()             – staff accounts of the admin's airline
--
-- Requires migration 17. Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('roster_is_officer()') IS NULL THEN
    RAISE EXCEPTION 'Migration 24 requires migration 17.';
  END IF;
END;
$$;

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS must_change_password boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES profiles(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION staff_clear_password_flag()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  UPDATE profiles SET must_change_password = false WHERE id = auth.uid();
$$;
REVOKE ALL ON FUNCTION staff_clear_password_flag() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION staff_clear_password_flag() TO authenticated;

-- Staff roles an admin can create. Kept in one place for the database side.
CREATE OR REPLACE FUNCTION is_staff_role(p_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p_role IN ('roster_officer', 'check_in_agent', 'ops_manager'); $$;

DROP FUNCTION IF EXISTS admin_staff_list();
CREATE FUNCTION admin_staff_list()
RETURNS TABLE (
  user_id uuid, full_name text, email text, phone text, role text,
  blocked boolean, must_change_password boolean, created_at timestamptz,
  created_by_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT COALESCE((SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false) THEN
    RAISE EXCEPTION 'Administrators only.' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT p.id, p.full_name, p.email, p.phone, p.role,
         p.blocked IS TRUE, p.must_change_password, p.created_at,
         c.full_name
    FROM profiles p
    LEFT JOIN profiles c ON c.id = p.created_by
   WHERE p.tenant_id = v_tenant
     AND is_staff_role(p.role)
   ORDER BY p.role, p.full_name;
END;
$$;
REVOKE ALL ON FUNCTION admin_staff_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_staff_list() TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('admin_staff_list()') IS NULL
     OR to_regprocedure('staff_clear_password_flag()') IS NULL THEN
    RAISE EXCEPTION 'Migration 24: functions not found';
  END IF;
  RAISE NOTICE 'Migration 24 verified: staff account support in place.';
END;
$$;
