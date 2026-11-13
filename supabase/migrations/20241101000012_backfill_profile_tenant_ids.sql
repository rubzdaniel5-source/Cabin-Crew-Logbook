-- =============================================================================
-- Migration: 20241101000012_backfill_profile_tenant_ids.sql
-- Description: Backfill tenant_id for any profiles still NULL after migration 2
--
-- Context:
--   Migration 2 backfilled existing users at deploy time, but users who
--   registered after that migration may have tenant_id = NULL if the
--   client-side sign-up write failed or was skipped.
--
--   Rules (same as migration 2):
--     @crew.ugandairlines.com / @ugandairlines.com  → uganda-airlines tenant
--     everything else                               → independent pseudo-tenant
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Uganda Airlines users registered after migration 2
-- ---------------------------------------------------------------------------
UPDATE profiles p
SET
  tenant_id  = (SELECT id FROM guestora_tenants WHERE slug = 'uganda-airlines'),
  user_class = 'airline'
FROM auth.users u
WHERE p.id        = u.id
  AND p.tenant_id IS NULL
  AND (
    u.email ILIKE '%@crew.ugandairlines.com'
    OR u.email ILIKE '%@ugandairlines.com'
  );

-- ---------------------------------------------------------------------------
-- 2. All remaining profiles with NULL tenant_id → independent
-- ---------------------------------------------------------------------------
UPDATE profiles
SET
  tenant_id  = (SELECT id FROM guestora_tenants WHERE slug = 'independent'),
  user_class = COALESCE(user_class, 'independent')
WHERE tenant_id IS NULL;

-- ---------------------------------------------------------------------------
-- 3. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  null_count integer;
BEGIN
  SELECT COUNT(*) INTO null_count FROM profiles WHERE tenant_id IS NULL;
  IF null_count > 0 THEN
    RAISE EXCEPTION 'Migration 12: % profile(s) still have null tenant_id', null_count;
  END IF;
  RAISE NOTICE 'Migration 12 verified: all profiles have a tenant_id assigned.';
END;
$$;
