-- =============================================================================
-- Migration: 20241101000013_profiles_airline_name.sql
-- Description: Add airline_name column to profiles for quick display
--
-- Context:
--   The profiles table has user_class ('airline'|'independent') but no
--   denormalized airline name, so the admin view must JOIN guestora_tenants
--   to show which airline each crew member belongs to.
--
--   This migration adds:
--     profiles.airline_name  text   — denormalized airline name for fast display
--
--   Backfill logic (same rules as the tenant assignment migrations):
--     • user_class = 'airline'      → guestora_tenants.airline_name via tenant_id
--     • user_class = 'independent'  → stated_airline_name (what the user typed
--                                     at sign-up, may be NULL if they skipped it)
--
--   A trigger keeps the column in sync whenever tenant_id or stated_airline_name
--   is updated on the profile row.
--
-- Available user_class values (CHECK constraint, migration 2):
--   'airline'      – crew employed by a registered airline tenant
--   'independent'  – freelance / contract cabin crew (no airline tenant)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Add the column
-- ---------------------------------------------------------------------------
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS airline_name text;

COMMENT ON COLUMN profiles.airline_name IS
  'Denormalized airline name for display. '
  'For airline users: copied from guestora_tenants.airline_name. '
  'For independent users: copied from stated_airline_name (may be NULL).';

-- ---------------------------------------------------------------------------
-- 2. Backfill existing rows
-- ---------------------------------------------------------------------------

-- 2a. airline users → pull from their tenant record
UPDATE profiles p
SET airline_name = t.airline_name
FROM guestora_tenants t
WHERE p.tenant_id = t.id
  AND p.user_class = 'airline'
  AND p.airline_name IS NULL;

-- 2b. independent users who typed an airline name at sign-up
UPDATE profiles
SET airline_name = stated_airline_name
WHERE user_class = 'independent'
  AND stated_airline_name IS NOT NULL
  AND airline_name IS NULL;

-- ---------------------------------------------------------------------------
-- 3. Trigger: keep airline_name in sync on UPDATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_profile_airline_name()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.user_class = 'airline' AND NEW.tenant_id IS NOT NULL THEN
    SELECT airline_name
      INTO NEW.airline_name
      FROM guestora_tenants
     WHERE id = NEW.tenant_id;
  ELSIF NEW.user_class = 'independent' THEN
    NEW.airline_name := NEW.stated_airline_name;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_profile_airline_name ON profiles;
CREATE TRIGGER trg_sync_profile_airline_name
  BEFORE INSERT OR UPDATE OF tenant_id, stated_airline_name, user_class
  ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION sync_profile_airline_name();

-- ---------------------------------------------------------------------------
-- 4. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_col     int;
  v_airline int;
  v_indep   int;
BEGIN
  -- Column exists
  SELECT COUNT(*) INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'profiles'
     AND column_name  = 'airline_name';

  IF v_col = 0 THEN
    RAISE EXCEPTION 'Migration 13: profiles.airline_name column not found';
  END IF;

  -- Count how many airline-class profiles got a name
  SELECT COUNT(*) INTO v_airline
    FROM profiles
   WHERE user_class = 'airline' AND airline_name IS NOT NULL;

  -- Count how many independent profiles that stated an airline also got it
  SELECT COUNT(*) INTO v_indep
    FROM profiles
   WHERE user_class = 'independent'
     AND stated_airline_name IS NOT NULL
     AND airline_name IS NOT NULL;

  RAISE NOTICE
    'Migration 13 verified: airline_name column present. '
    'Airline users with name set: %. '
    'Independent users with stated airline set: %.',
    v_airline, v_indep;
END;
$$;
