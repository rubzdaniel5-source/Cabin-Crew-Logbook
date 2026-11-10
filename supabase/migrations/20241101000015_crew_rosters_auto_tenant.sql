-- =============================================================================
-- Migration: 20241101000015_crew_rosters_auto_tenant.sql
-- Description: Auto-assign tenant_id on INSERT via BEFORE INSERT trigger
--
-- Problem:
--   confirmRosterImport() was resolving tenant_id client-side (via RPC or
--   profiles SELECT) and passing it in the INSERT payload. If the JWT was
--   stale or the RPC returned null, the import failed with "tenant_id not
--   defined" before even reaching Supabase.
--
-- Fix (same pattern as migration 8 for passenger_manifests):
--   BEFORE INSERT triggers on crew_rosters and roster_duties call
--   guestora_resolve_tenant_id() server-side (SECURITY DEFINER) and
--   overwrite whatever tenant_id the client sent (or fill it when absent).
--   The client no longer needs to supply tenant_id at all.
--
--   The RLS INSERT policy (tenant_id = guestora_resolve_tenant_id()) still
--   applies AFTER the trigger sets the value, so the check always passes.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. crew_rosters — auto-set tenant_id on INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_rosters_set_tenant_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := guestora_resolve_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION
      'Cannot import roster: your account has no tenant assignment. '
      'Contact your administrator.';
  END IF;
  NEW.tenant_id := v_tenant_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS crew_rosters_auto_tenant ON crew_rosters;
CREATE TRIGGER crew_rosters_auto_tenant
  BEFORE INSERT ON crew_rosters
  FOR EACH ROW EXECUTE FUNCTION crew_rosters_set_tenant_id();

-- ---------------------------------------------------------------------------
-- 2. roster_duties — auto-set tenant_id on INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_duties_set_tenant_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := guestora_resolve_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION
      'Cannot import roster duties: your account has no tenant assignment. '
      'Contact your administrator.';
  END IF;
  NEW.tenant_id := v_tenant_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS roster_duties_auto_tenant ON roster_duties;
CREATE TRIGGER roster_duties_auto_tenant
  BEFORE INSERT ON roster_duties
  FOR EACH ROW EXECUTE FUNCTION roster_duties_set_tenant_id();

-- ---------------------------------------------------------------------------
-- 3. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_r int; v_d int;
BEGIN
  SELECT COUNT(*) INTO v_r FROM information_schema.triggers
    WHERE trigger_schema = 'public' AND event_object_table = 'crew_rosters'
      AND trigger_name = 'crew_rosters_auto_tenant';
  SELECT COUNT(*) INTO v_d FROM information_schema.triggers
    WHERE trigger_schema = 'public' AND event_object_table = 'roster_duties'
      AND trigger_name = 'roster_duties_auto_tenant';

  IF v_r = 0 THEN RAISE EXCEPTION 'crew_rosters_auto_tenant trigger not found'; END IF;
  IF v_d = 0 THEN RAISE EXCEPTION 'roster_duties_auto_tenant trigger not found'; END IF;

  RAISE NOTICE 'Migration 15 verified: auto-tenant triggers present on crew_rosters and roster_duties.';
END;
$$;
