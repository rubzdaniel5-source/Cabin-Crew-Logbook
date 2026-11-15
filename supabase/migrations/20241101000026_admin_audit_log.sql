-- =============================================================================
-- Migration: 20241101000026_admin_audit_log.sql
-- Description: Audit log for administrators — who changed what, and when.
--
--   admin_audit_log        – append-only record of account events
--   profiles trigger       – logs role / admin / blocked / crew-code changes
--   admin_audit_list()     – admin-only feed: account events + roster officer
--                            changes, newest first, with paging and filter
--
-- Staff account creation / password resets are written by the Edge Function.
-- Changes made from the SQL editor or the service role (no signed-in user)
-- are not logged by the trigger.
-- Requires migrations 17 and 24. Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('roster_duty_changes') IS NULL THEN
    RAISE EXCEPTION 'Migration 26 requires migration 17.';
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS admin_audit_log (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid,
  actor_id     uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  actor_name   text,
  action       text        NOT NULL,   -- staff_created | staff_password_reset | role_changed | blocked | unblocked | admin_granted | admin_revoked | crew_code_changed
  target_id    uuid,
  target_label text,
  details      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_audit_log_tenant_time ON admin_audit_log (tenant_id, created_at DESC);

-- Nobody reads or writes it directly: only the functions below (and the service role)
ALTER TABLE admin_audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON admin_audit_log FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Trigger: record privileged profile changes made by a signed-in user
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION profiles_audit_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_name  text;
  v_label text := COALESCE(NEW.full_name, NEW.email, NEW.id::text);
BEGIN
  IF v_actor IS NULL THEN RETURN NEW; END IF;
  SELECT full_name INTO v_name FROM profiles WHERE id = v_actor;

  IF NEW.role IS DISTINCT FROM OLD.role THEN
    INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label, details)
    VALUES (NEW.tenant_id, v_actor, v_name, 'role_changed', NEW.id, v_label,
            jsonb_build_object('from', COALESCE(OLD.role,'crew'), 'to', COALESCE(NEW.role,'crew')));
  END IF;
  IF NEW.blocked IS DISTINCT FROM OLD.blocked THEN
    INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label)
    VALUES (NEW.tenant_id, v_actor, v_name,
            CASE WHEN NEW.blocked IS TRUE THEN 'blocked' ELSE 'unblocked' END, NEW.id, v_label);
  END IF;
  IF NEW.is_admin IS DISTINCT FROM OLD.is_admin THEN
    INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label)
    VALUES (NEW.tenant_id, v_actor, v_name,
            CASE WHEN NEW.is_admin IS TRUE THEN 'admin_granted' ELSE 'admin_revoked' END, NEW.id, v_label);
  END IF;
  -- a user setting their own first crew code is routine; a change by someone else is not
  IF NEW.crew_code IS DISTINCT FROM OLD.crew_code AND NOT (NEW.id = v_actor AND OLD.crew_code IS NULL) THEN
    INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label, details)
    VALUES (NEW.tenant_id, v_actor, v_name, 'crew_code_changed', NEW.id, v_label,
            jsonb_build_object('from', OLD.crew_code, 'to', NEW.crew_code));
  END IF;
  RETURN NEW;
END;
$$;

-- AFTER the guard trigger has accepted the change
DROP TRIGGER IF EXISTS profiles_audit_changes ON profiles;
CREATE TRIGGER profiles_audit_changes
  AFTER UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION profiles_audit_changes();

-- ---------------------------------------------------------------------------
-- Feed for administrators
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS admin_audit_list(int, timestamptz, text);
CREATE FUNCTION admin_audit_list(
  p_limit  int         DEFAULT 50,
  p_before timestamptz DEFAULT NULL,
  p_kind   text        DEFAULT 'all'      -- all | account | roster
)
RETURNS TABLE (
  id text, at timestamptz, kind text, action text,
  actor_name text, target_label text, details jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_limit  int  := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  IF NOT COALESCE((SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false) THEN
    RAISE EXCEPTION 'Administrators only.' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT * FROM (
    SELECT l.id::text, l.created_at, 'account'::text, l.action,
           COALESCE(l.actor_name, 'System'), l.target_label, l.details
      FROM admin_audit_log l
     WHERE l.tenant_id = v_tenant AND p_kind IN ('all','account')
       AND (p_before IS NULL OR l.created_at < p_before)
    UNION ALL
    SELECT c.id::text, c.changed_at, 'roster'::text, c.change_type,
           COALESCE(a.full_name, 'Unknown'),
           concat_ws(' · ', r.crew_name, d.duty_date::text, d.flight_number),
           jsonb_build_object('reason', c.reason, 'old', c.old_values, 'new', c.new_values)
      FROM roster_duty_changes c
      JOIN roster_duties d ON d.id = c.duty_id
      JOIN crew_rosters  r ON r.id = c.roster_id
      LEFT JOIN profiles a ON a.id = c.changed_by
     WHERE c.tenant_id = v_tenant AND c.source = 'officer' AND p_kind IN ('all','roster')
       AND (p_before IS NULL OR c.changed_at < p_before)
  ) x
  ORDER BY x.created_at DESC
  LIMIT v_limit;
END;
$$;
REVOKE ALL ON FUNCTION admin_audit_list(int, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_audit_list(int, timestamptz, text) TO authenticated;

DO $$
BEGIN
  IF to_regclass('admin_audit_log') IS NULL
     OR to_regprocedure('admin_audit_list(int,timestamptz,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 26 verification failed.';
  END IF;
  RAISE NOTICE 'Migration 26 OK';
END;
$$;
