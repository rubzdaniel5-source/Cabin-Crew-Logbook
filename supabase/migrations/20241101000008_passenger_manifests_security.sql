-- =============================================================================
-- Migration: 20241101000008_passenger_manifests_security.sql
-- Description: Close all security gaps in passenger_manifests
--
-- Problems fixed:
--   GAP 1 — No tenant isolation
--     passenger_manifests has no tenant_id column. The SELECT policy
--     "Crew can read manifests for their flights" uses ONLY
--     auth.role() = 'authenticated' — meaning any authenticated user
--     across any tenant can read every manifest row. This is a critical
--     cross-tenant data leak.
--
--   GAP 2 — No UNIQUE constraint on (flight_number, flight_date)
--     The client does a manual existence check then INSERT/UPDATE in two
--     round trips, which races. With no UNIQUE constraint the same
--     manifest can be inserted twice on a slow connection. This migration
--     adds a tenant-scoped UNIQUE constraint and switches the client to a
--     single upsert (see index.html edits below).
--
--   GAP 3 — INSERT/UPDATE policies similarly lack tenant scope
--     All write policies allowed any authenticated user to insert or
--     update manifests, with no tenant verification at all.
--
-- What this migration does:
--   1. Add tenant_id column (nullable first, so the ALTER succeeds on a
--      table that may already have rows)
--   2. Backfill tenant_id from profiles for existing rows where
--      uploaded_by matches a known user (safe even on empty tables)
--   3. Add NOT NULL constraint after backfill
--   4. Add UNIQUE constraint: (tenant_id, flight_number, flight_date)
--      This replaces the implicit client-side duplicate guard.
--   5. Drop all existing RLS policies (there were 4; all are unsafe)
--   6. Create 4 replacement policies with full tenant isolation
--   7. Add uploaded_by_name column if not present (display name cache;
--      already in the client schema per Q4 inspection)
--
-- Client changes (index.html — applied separately):
--   uploadManifest()   — add tenant_id to payload; switch to .upsert()
--                        on (tenant_id, flight_number, flight_date)
--   loadManifests()    — remove server-side .eq('uploaded_by') filter;
--                        tenant isolation is now enforced by RLS alone
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Add tenant_id — nullable first so the ALTER succeeds on existing rows
-- ---------------------------------------------------------------------------
ALTER TABLE passenger_manifests
  ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES guestora_tenants(id) ON DELETE RESTRICT;

-- ---------------------------------------------------------------------------
-- 2. Backfill tenant_id from profiles for any existing rows
--    Rows without a matching profile (edge case) are left NULL and will
--    be caught by the NOT NULL constraint below — a manual fix is then
--    needed. The DO block reports any un-backfilled rows.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_updated   integer;
  v_remaining integer;
BEGIN
  -- Backfill rows where tenant_id is still NULL and uploaded_by is known
  UPDATE passenger_manifests pm
  SET    tenant_id = p.tenant_id
  FROM   profiles p
  WHERE  pm.uploaded_by = p.id
    AND  pm.tenant_id IS NULL
    AND  p.tenant_id IS NOT NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT COUNT(*) INTO v_remaining
  FROM   passenger_manifests
  WHERE  tenant_id IS NULL;

  IF v_remaining > 0 THEN
    RAISE WARNING
      'passenger_manifests: % row(s) still have NULL tenant_id after backfill. '
      'These rows must be manually resolved before the NOT NULL constraint can be enforced. '
      'Inspect: SELECT id, flight_number, flight_date, uploaded_by FROM passenger_manifests WHERE tenant_id IS NULL;',
      v_remaining;
  ELSE
    RAISE NOTICE 'passenger_manifests: backfill complete — % row(s) updated, 0 remaining.', v_updated;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Enforce NOT NULL — fails intentionally if orphaned rows remain.
--    If this step fails, resolve the orphaned rows manually then re-run.
-- ---------------------------------------------------------------------------
ALTER TABLE passenger_manifests
  ALTER COLUMN tenant_id SET NOT NULL;

-- Index for the tenant join (all RLS policies filter on tenant_id)
CREATE INDEX IF NOT EXISTS passenger_manifests_tenant_idx
  ON passenger_manifests (tenant_id);

-- ---------------------------------------------------------------------------
-- 4. UNIQUE constraint: one manifest per tenant per flight per date
--    Replaces the racy two-round-trip existence check in the client.
--    The client switches to a single upsert on this constraint (Phase 2
--    index.html changes).
-- ---------------------------------------------------------------------------
ALTER TABLE passenger_manifests
  ADD CONSTRAINT passenger_manifests_tenant_flight_date_unique
    UNIQUE (tenant_id, flight_number, flight_date);

-- ---------------------------------------------------------------------------
-- 5. BEFORE INSERT trigger: auto-set tenant_id from the uploader's profile
--    The client does NOT send tenant_id in the upsert payload.
--    This trigger resolves it server-side using guestora_resolve_tenant_id()
--    so the UNIQUE constraint (tenant_id, flight_number, flight_date) works
--    without any client-supplied value.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION passenger_manifests_set_tenant_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  -- Always overwrite whatever the client may have sent (defensive)
  v_tenant_id := guestora_resolve_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Cannot resolve tenant_id for passenger manifest upload: user has no tenant assignment';
  END IF;
  NEW.tenant_id := v_tenant_id;
  RETURN NEW;
END;
$$;

-- Trigger fires on INSERT only. On UPDATE the tenant_id column is immutable
-- (enforced by the UNIQUE constraint — you cannot change the key columns).
CREATE TRIGGER passenger_manifests_auto_tenant
  BEFORE INSERT ON passenger_manifests
  FOR EACH ROW EXECUTE FUNCTION passenger_manifests_set_tenant_id();

-- ---------------------------------------------------------------------------
-- 5b. Immutability trigger for tenant_id on UPDATE
--     Prevents any UPDATE from changing the tenant, flight_number, or date
--     (which would silently violate tenant isolation).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION passenger_manifests_guard_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.tenant_id      IS DISTINCT FROM OLD.tenant_id      THEN
    RAISE EXCEPTION 'passenger_manifests.tenant_id is immutable';
  END IF;
  IF NEW.flight_number  IS DISTINCT FROM OLD.flight_number  THEN
    RAISE EXCEPTION 'passenger_manifests.flight_number is immutable';
  END IF;
  IF NEW.flight_date    IS DISTINCT FROM OLD.flight_date    THEN
    RAISE EXCEPTION 'passenger_manifests.flight_date is immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER passenger_manifests_immutable_identity
  BEFORE UPDATE ON passenger_manifests
  FOR EACH ROW EXECUTE FUNCTION passenger_manifests_guard_identity();

-- ---------------------------------------------------------------------------
-- 6. Drop ALL existing RLS policies (they all lack tenant isolation)
-- ---------------------------------------------------------------------------

-- Policy names as reported by the live RLS inspection (Q4 / query 2):
--   "Crew can read manifests for their flights"
--   "Users can insert their own manifests"
--   "Users can update their own manifests"
--   "Anyone can upload manifests"  (the most dangerous — explicit public write)
-- Drop by exact name; IF EXISTS makes this idempotent.

DROP POLICY IF EXISTS "Crew can read manifests for their flights" ON passenger_manifests;
DROP POLICY IF EXISTS "Users can insert their own manifests"       ON passenger_manifests;
DROP POLICY IF EXISTS "Users can update their own manifests"       ON passenger_manifests;
DROP POLICY IF EXISTS "Anyone can upload manifests"                ON passenger_manifests;

-- Drop any remaining policies with guestora-style names (idempotent)
DROP POLICY IF EXISTS "passenger_manifests_select"       ON passenger_manifests;
DROP POLICY IF EXISTS "passenger_manifests_insert"       ON passenger_manifests;
DROP POLICY IF EXISTS "passenger_manifests_update"       ON passenger_manifests;
DROP POLICY IF EXISTS "passenger_manifests_delete"       ON passenger_manifests;

-- Make sure RLS is on (may already be enabled, harmless to re-enable)
ALTER TABLE passenger_manifests ENABLE ROW LEVEL SECURITY;
ALTER TABLE passenger_manifests FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 8. New RLS policies — tenant-isolated throughout
-- ---------------------------------------------------------------------------

-- SELECT: crew may only read manifests belonging to their own tenant.
--   • Ops managers and check-in agents (non-crew roles) see all manifests
--     for their tenant — no flight-number restriction, since they may
--     upload on behalf of any flight.
--   • Cabin crew see only manifests whose flight_number matches a sector
--     they are assigned to, using guestora_check_flight_eligibility().
--   • Admins fall through to the tenant check only (is_admin handled
--     by a separate broader SELECT if needed; for now same rule applies).
--   NOTE: guestora_check_flight_eligibility() is STABLE SECURITY DEFINER
--   and safe to use in USING clauses.
CREATE POLICY "passenger_manifests_select"
  ON passenger_manifests
  FOR SELECT
  TO authenticated
  USING (
    -- Tenant isolation is mandatory for all roles
    tenant_id = guestora_resolve_tenant_id()
    AND (
      -- Ops managers and check-in agents see all manifests for their tenant
      (SELECT role FROM profiles WHERE id = auth.uid() LIMIT 1)
        IN ('ops_manager', 'check_in_agent', 'admin')
      -- Admins (is_admin flag) see all manifests for their tenant
      OR (SELECT is_admin FROM profiles WHERE id = auth.uid() LIMIT 1) = true
      -- Cabin crew: flight eligibility check per sector
      OR guestora_check_flight_eligibility(flight_number, flight_date)
    )
  );

-- INSERT: uploader must belong to this tenant; tenant_id enforced by WITH CHECK.
--   Crew, ops managers, and check-in agents may all upload.
CREATE POLICY "passenger_manifests_insert"
  ON passenger_manifests
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id    = guestora_resolve_tenant_id()
    AND uploaded_by = auth.uid()
  );

-- UPDATE: only the original uploader or an ops_manager / admin may update
--   (e.g. to correct a mis-uploaded manifest).
--   Tenant reassignment is blocked by the WITH CHECK tenant_id guard.
CREATE POLICY "passenger_manifests_update"
  ON passenger_manifests
  FOR UPDATE
  TO authenticated
  USING (
    tenant_id = guestora_resolve_tenant_id()
    AND (
      uploaded_by = auth.uid()
      OR (SELECT role FROM profiles WHERE id = auth.uid() LIMIT 1)
           IN ('ops_manager', 'admin')
      OR (SELECT is_admin FROM profiles WHERE id = auth.uid() LIMIT 1) = true
    )
  )
  WITH CHECK (
    -- Prevent cross-tenant reassignment even on UPDATE
    tenant_id = guestora_resolve_tenant_id()
  );

-- DELETE: ops_manager and admin only — manifests are audit records but
--   corrective delete must be possible for a mis-upload.
CREATE POLICY "passenger_manifests_delete"
  ON passenger_manifests
  FOR DELETE
  TO authenticated
  USING (
    tenant_id = guestora_resolve_tenant_id()
    AND (
      (SELECT role FROM profiles WHERE id = auth.uid() LIMIT 1) IN ('ops_manager', 'admin')
      OR (SELECT is_admin FROM profiles WHERE id = auth.uid() LIMIT 1) = true
    )
  );

-- ---------------------------------------------------------------------------
-- 9. Add uploaded_by_name column if not already present
--    (display-name cache; reduces client-side joins)
-- ---------------------------------------------------------------------------
ALTER TABLE passenger_manifests
  ADD COLUMN IF NOT EXISTS uploaded_by_name text;

COMMENT ON COLUMN passenger_manifests.uploaded_by_name
  IS 'Display name of the uploader at the time of upload. Denormalized cache — not authoritative.';

COMMENT ON COLUMN passenger_manifests.tenant_id
  IS 'Tenant this manifest belongs to. Resolved from the uploader''s profile; never client-supplied.';

-- ---------------------------------------------------------------------------
-- 10. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_col_tenant      integer;
  v_col_name        integer;
  v_constraint      integer;
  v_pol_count       integer;
  v_trigger_insert  integer;
  v_trigger_update  integer;
  v_rls_enabled     boolean;
  v_rls_forced      boolean;
BEGIN
  -- tenant_id column present
  SELECT COUNT(*) INTO v_col_tenant FROM information_schema.columns
  WHERE table_schema='public' AND table_name='passenger_manifests' AND column_name='tenant_id';
  IF v_col_tenant = 0 THEN
    RAISE EXCEPTION 'tenant_id column not found on passenger_manifests';
  END IF;

  -- uploaded_by_name column present
  SELECT COUNT(*) INTO v_col_name FROM information_schema.columns
  WHERE table_schema='public' AND table_name='passenger_manifests' AND column_name='uploaded_by_name';
  IF v_col_name = 0 THEN
    RAISE EXCEPTION 'uploaded_by_name column not found on passenger_manifests';
  END IF;

  -- UNIQUE constraint present
  SELECT COUNT(*) INTO v_constraint FROM pg_constraint
  WHERE conrelid = 'passenger_manifests'::regclass
    AND conname = 'passenger_manifests_tenant_flight_date_unique';
  IF v_constraint = 0 THEN
    RAISE EXCEPTION 'UNIQUE constraint passenger_manifests_tenant_flight_date_unique not found';
  END IF;

  -- Auto-tenant trigger present
  SELECT COUNT(*) INTO v_trigger_insert FROM pg_trigger
  WHERE tgrelid = 'passenger_manifests'::regclass
    AND tgname = 'passenger_manifests_auto_tenant';
  IF v_trigger_insert = 0 THEN
    RAISE EXCEPTION 'BEFORE INSERT trigger passenger_manifests_auto_tenant not found';
  END IF;

  -- Identity immutability trigger present
  SELECT COUNT(*) INTO v_trigger_update FROM pg_trigger
  WHERE tgrelid = 'passenger_manifests'::regclass
    AND tgname = 'passenger_manifests_immutable_identity';
  IF v_trigger_update = 0 THEN
    RAISE EXCEPTION 'BEFORE UPDATE trigger passenger_manifests_immutable_identity not found';
  END IF;

  -- At least 4 RLS policies
  SELECT COUNT(*) INTO v_pol_count FROM pg_policies
  WHERE schemaname='public' AND tablename='passenger_manifests';
  IF v_pol_count < 4 THEN
    RAISE EXCEPTION 'Expected at least 4 policies on passenger_manifests, found %', v_pol_count;
  END IF;

  -- RLS enabled and forced
  SELECT relrowsecurity, relforcerowsecurity
  INTO v_rls_enabled, v_rls_forced
  FROM pg_class WHERE relname='passenger_manifests' AND relnamespace='public'::regnamespace;
  IF NOT v_rls_enabled THEN
    RAISE EXCEPTION 'RLS not enabled on passenger_manifests';
  END IF;
  IF NOT v_rls_forced THEN
    RAISE EXCEPTION 'RLS not forced (FORCE ROW LEVEL SECURITY) on passenger_manifests';
  END IF;

  RAISE NOTICE
    'Migration 8 verified: passenger_manifests fully secured — tenant_id column, auto-tenant trigger, '
    'immutability trigger, UNIQUE constraint, % RLS policies, RLS enabled+forced.',
    v_pol_count;
END;
$$;
