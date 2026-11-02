-- =============================================================================
-- Migration: 20241101000003_rls_policies_and_helpers.sql
-- Description: RLS policies for profiles + guestora_tenants admin write,
--              and guestora_resolve_tenant_id() helper function
--
-- Scope:
--   1. SECURITY DEFINER helper: guestora_resolve_tenant_id()
--      Returns the caller's tenant_id from profiles via auth.uid().
--      Used by RLS policies on all future guestora_* tables so the
--      join never executes with client-supplied values.
--
--   2. profiles RLS — tightened after tenant_id backfill:
--      a. Any authenticated user can read their OWN row (always)
--      b. Airline users can read profiles within their own tenant
--         (needed for Phase 2 crew session visibility)
--      c. Independent users can only read their own row
--      d. Users can update only their own row (existing behaviour)
--      e. INSERT: auth trigger handles profile creation (existing)
--
--   3. guestora_tenants — explicit admin-only write policy
--      Authenticated users with is_admin = true in profiles may
--      UPDATE guestora_tenants. INSERT/DELETE remain migration-only.
--
-- Isolation invariant:
--   tenant_id is NEVER supplied by the client.
--   guestora_resolve_tenant_id() is the single trusted resolution path.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Helper function: guestora_resolve_tenant_id()
--    SECURITY DEFINER so it runs as the function owner (postgres),
--    not the calling user — safe to use inside RLS USING clauses.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guestora_resolve_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT tenant_id
  FROM profiles
  WHERE id = auth.uid()
  LIMIT 1;
$$;

-- Grant execute to authenticated role only
REVOKE ALL ON FUNCTION guestora_resolve_tenant_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION guestora_resolve_tenant_id() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. profiles RLS
--    Drop and recreate policies so this migration is idempotent.
--    Existing policies (if any) on profiles are replaced cleanly.
-- ---------------------------------------------------------------------------
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Drop existing policies before recreating (safe to run if they don't exist)
DROP POLICY IF EXISTS "profiles_select_own"        ON profiles;
DROP POLICY IF EXISTS "profiles_select_same_tenant" ON profiles;
DROP POLICY IF EXISTS "profiles_update_own"         ON profiles;
DROP POLICY IF EXISTS "profiles_insert_own"         ON profiles;

-- 2a. Own row — always readable by the user themselves
CREATE POLICY "profiles_select_own"
  ON profiles
  FOR SELECT
  TO authenticated
  USING (id = auth.uid());

-- 2b. Same-tenant read — airline users only
--     Independent users (tenant = 'independent' pseudo-tenant) are
--     excluded via user_class check so they cannot read each other's rows.
CREATE POLICY "profiles_select_same_tenant"
  ON profiles
  FOR SELECT
  TO authenticated
  USING (
    user_class = 'airline'
    AND tenant_id = guestora_resolve_tenant_id()
  );

-- 2c. Own row update — users may update only their own profile
CREATE POLICY "profiles_update_own"
  ON profiles
  FOR UPDATE
  TO authenticated
  USING  (id = auth.uid())
  WITH CHECK (
    id = auth.uid()
    -- Prevent client from reassigning tenant_id or user_class
    AND tenant_id  = guestora_resolve_tenant_id()
    AND user_class = (SELECT user_class FROM profiles WHERE id = auth.uid())
  );

-- 2d. Insert — auth trigger creates the profile row on signup.
--     Block any direct client INSERT (trigger runs as SECURITY DEFINER).
--     This policy is intentionally absent: no INSERT policy = INSERT denied.

-- ---------------------------------------------------------------------------
-- 3. guestora_tenants — explicit admin-only UPDATE policy
--    INSERT and DELETE remain migration-only (no policies = denied).
--    Admins can update tenant config (branding, enabled flag, etc.)
--    via the future admin dashboard.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "guestora_tenants_admin_update" ON guestora_tenants;

CREATE POLICY "guestora_tenants_admin_update"
  ON guestora_tenants
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid()
        AND is_admin = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid()
        AND is_admin = true
    )
  );

-- ---------------------------------------------------------------------------
-- 4. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  fn_exists       boolean;
  policy_count    integer;
BEGIN
  -- Confirm helper function exists
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'guestora_resolve_tenant_id'
  ) INTO fn_exists;

  IF NOT fn_exists THEN
    RAISE EXCEPTION 'guestora_resolve_tenant_id() function not found';
  END IF;

  -- Confirm profiles policies exist
  SELECT COUNT(*) INTO policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename  = 'profiles'
    AND policyname IN (
      'profiles_select_own',
      'profiles_select_same_tenant',
      'profiles_update_own'
    );

  IF policy_count != 3 THEN
    RAISE EXCEPTION 'Expected 3 profiles policies, found %', policy_count;
  END IF;

  -- Confirm guestora_tenants admin policy exists
  SELECT COUNT(*) INTO policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename  = 'guestora_tenants'
    AND policyname = 'guestora_tenants_admin_update';

  IF policy_count != 1 THEN
    RAISE EXCEPTION 'guestora_tenants_admin_update policy not found';
  END IF;

  RAISE NOTICE 'Migration 3 verified: helper function + % profiles policies + tenants admin policy all confirmed', 3;
END;
$$;
