-- =============================================================================
-- Migration: 20241101000006_guestora_tenants_anon_read.sql
-- Description: Allow anonymous (pre-auth) reads on guestora_tenants
--
-- Why this is needed:
--   The signup form shows a searchable airline dropdown populated from
--   guestora_tenants. The user is not yet authenticated when viewing the
--   signup screen, so the existing `guestora_tenants_read_all` policy
--   (which requires the `authenticated` role) cannot be used.
--
--   guestora_tenants contains only public directory information:
--   airline names, IATA codes, and enabled status. No sensitive data.
--   Exposing this to anonymous reads is safe and intentional.
--
-- The existing authenticated policy is retained unchanged; this policy
-- is additive and covers only the anon role.
-- =============================================================================

-- Allow unauthenticated (pre-signup) reads so the airline dropdown loads
-- without requiring the user to be logged in first.
CREATE POLICY "guestora_tenants_anon_read"
  ON guestora_tenants
  FOR SELECT
  TO anon
  USING (true);

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  pol_count integer;
BEGIN
  SELECT COUNT(*) INTO pol_count FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename  = 'guestora_tenants'
    AND policyname = 'guestora_tenants_anon_read';

  IF pol_count != 1 THEN
    RAISE EXCEPTION 'guestora_tenants_anon_read policy not found';
  END IF;

  RAISE NOTICE 'Migration 6 verified: guestora_tenants_anon_read policy confirmed';
END;
$$;
