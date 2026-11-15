-- =============================================================================
-- Migration: 20241101000027_staff_base.sql
-- Description: Base (station) assignment for staff
--
--   profiles.base          – 3-letter IATA station code, e.g. EBB (optional)
--   profiles_guard_base    – only an administrator can change anyone's base
--   admin_set_base()       – the admin path: validates, scopes to the tenant, audits
--   admin_staff_list()     – now also returns base
--
-- Requires migrations 24 and 26. Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('admin_audit_log') IS NULL OR to_regprocedure('admin_staff_list()') IS NULL THEN
    RAISE EXCEPTION 'Migration 27 requires migrations 24 and 26.';
  END IF;
END;
$$;

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS base text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'profiles_base_format') THEN
    ALTER TABLE profiles ADD CONSTRAINT profiles_base_format
      CHECK (base IS NULL OR base ~ '^[A-Z]{3}$');
  END IF;
END;
$$;

-- Nobody changes their own base (or anyone else's) except an administrator.
CREATE OR REPLACE FUNCTION profiles_guard_base()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.base IS NOT DISTINCT FROM OLD.base OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF NOT COALESCE((SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false) THEN
    RAISE EXCEPTION 'Only an administrator can change a base assignment.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS profiles_guard_base ON profiles;
CREATE TRIGGER profiles_guard_base
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION profiles_guard_base();

CREATE OR REPLACE FUNCTION admin_set_base(p_user_id uuid, p_base text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_base   text := NULLIF(upper(btrim(COALESCE(p_base, ''))), '');
  v_old    text;
  v_label  text;
  v_actor  text;
BEGIN
  IF NOT COALESCE((SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false) THEN
    RAISE EXCEPTION 'Administrators only.' USING ERRCODE = '42501';
  END IF;
  IF v_base IS NOT NULL AND v_base !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'A base is a 3-letter station code, e.g. EBB.' USING ERRCODE = '22023';
  END IF;

  SELECT base, COALESCE(full_name, email, id::text) INTO v_old, v_label
    FROM profiles WHERE id = p_user_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Account not found.' USING ERRCODE = 'P0002'; END IF;
  IF v_old IS NOT DISTINCT FROM v_base THEN RETURN; END IF;

  UPDATE profiles SET base = v_base WHERE id = p_user_id;

  SELECT full_name INTO v_actor FROM profiles WHERE id = auth.uid();
  INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label, details)
  VALUES (v_tenant, auth.uid(), v_actor, 'base_changed', p_user_id, v_label,
          jsonb_build_object('from', v_old, 'to', v_base));
END;
$$;
REVOKE ALL ON FUNCTION admin_set_base(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_set_base(uuid, text) TO authenticated;

DROP FUNCTION IF EXISTS admin_staff_list();
CREATE FUNCTION admin_staff_list()
RETURNS TABLE (
  user_id uuid, full_name text, email text, phone text, role text,
  blocked boolean, must_change_password boolean, created_at timestamptz,
  created_by_name text, base text
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
         c.full_name, p.base
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
  IF to_regprocedure('admin_set_base(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 27 verification failed.';
  END IF;
  RAISE NOTICE 'Migration 27 OK';
END;
$$;
