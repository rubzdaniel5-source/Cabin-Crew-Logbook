-- =============================================================================
-- Migration: 20241101000002_profiles_tenant_columns.sql
-- Description: Add tenant columns to profiles + insert independent pseudo-tenant
--
-- User class model:
--   'airline'     — crew whose airline has officially adopted Crew Logbook;
--                   tenant_id → their airline's guestora_tenants row (enabled=true)
--   'independent' — crew self-registered outside an adopted airline;
--                   tenant_id → the shared 'independent' pseudo-tenant row
--
-- Independent user sub-cases:
--   a) Airline exists in directory but not adopted:
--        stated_airline_id → that directory row (enabled=false)
--        stated_airline_name = null
--   b) Airline not in directory at all:
--        stated_airline_id = null
--        stated_airline_name = free text entered at signup
--
-- Isolation invariant:
--   - tenant_id is NEVER supplied by the client in write operations
--   - For 'airline' users: resolved via email domain match at signup
--   - For 'independent' users: always set to the 'independent' pseudo-tenant id
--   - RLS on guestora_* tables: airline users isolated by tenant_id;
--     independent users additionally isolated by auth.uid()
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Insert the 'independent' pseudo-tenant into guestora_tenants
-- This row must exist before profiles FK can reference it.
-- dining_brand = 'Menuva' — the neutral brand for independent crew
-- enabled = true so the row is treated as a valid resolved tenant
-- The slug 'independent' is reserved and must never be deleted or disabled.
-- ---------------------------------------------------------------------------
INSERT INTO guestora_tenants (
  slug,
  airline_name,
  iata_code,
  dining_brand,
  tagline,
  enabled
)
VALUES (
  'independent',
  'Independent Crew',
  null,
  'Menuva',
  'Your inflight dining companion',
  true
)
ON CONFLICT (slug) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Step 2: Add tenant columns to profiles
-- Run each ALTER separately so a partial failure is easy to diagnose.
-- ---------------------------------------------------------------------------

-- Which resolved tenant this user belongs to.
-- NULL temporarily allowed during backfill; set NOT NULL after backfill migration.
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS tenant_id uuid
    REFERENCES guestora_tenants(id) ON DELETE RESTRICT;

-- 'airline' = adopted airline crew | 'independent' = self-registered crew
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS user_class text
    NOT NULL DEFAULT 'independent'
    CHECK (user_class IN ('airline', 'independent'));

-- For independent users whose airline exists in the directory (enabled=false).
-- Null for airline users and for independents whose airline isn't listed.
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS stated_airline_id uuid
    REFERENCES guestora_tenants(id) ON DELETE SET NULL;

-- For independent users whose airline is not in the directory at all.
-- Null for airline users and for independents who selected from the dropdown.
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS stated_airline_name text;

-- ---------------------------------------------------------------------------
-- Step 3: Index tenant_id for join performance (used in every RLS policy)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS profiles_tenant_id_idx
  ON profiles (tenant_id);

-- ---------------------------------------------------------------------------
-- Step 4: Backfill existing Uganda Airlines users
-- Sets tenant_id and user_class for any profiles whose auth email domain
-- matches Uganda Airlines' known domains.
-- This relies on auth.users being joinable via profiles.id = auth.users.id.
-- ---------------------------------------------------------------------------
UPDATE profiles p
SET
  tenant_id  = (SELECT id FROM guestora_tenants WHERE slug = 'uganda-airlines'),
  user_class = 'airline'
FROM auth.users u
WHERE p.id = u.id
  AND (
    u.email ILIKE '%@crew.ugandairlines.com'
    OR u.email ILIKE '%@ugandairlines.com'
  )
  AND p.tenant_id IS NULL;

-- ---------------------------------------------------------------------------
-- Step 5: Backfill remaining profiles → independent pseudo-tenant
-- Any profile still without a tenant_id after the Uganda Airlines backfill
-- is treated as an independent user.
-- ---------------------------------------------------------------------------
UPDATE profiles
SET
  tenant_id  = (SELECT id FROM guestora_tenants WHERE slug = 'independent'),
  user_class = 'independent'
WHERE tenant_id IS NULL;

-- ---------------------------------------------------------------------------
-- Step 6: Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  null_tenant_count   integer;
  independent_id      uuid;
  ug_id               uuid;
BEGIN
  -- Confirm independent pseudo-tenant exists
  SELECT id INTO independent_id FROM guestora_tenants WHERE slug = 'independent';
  IF independent_id IS NULL THEN
    RAISE EXCEPTION 'independent pseudo-tenant row not found';
  END IF;

  -- Confirm Uganda Airlines tenant exists
  SELECT id INTO ug_id FROM guestora_tenants WHERE slug = 'uganda-airlines';
  IF ug_id IS NULL THEN
    RAISE EXCEPTION 'uganda-airlines tenant row not found';
  END IF;

  -- Confirm no profiles have null tenant_id after backfill
  SELECT COUNT(*) INTO null_tenant_count
  FROM profiles
  WHERE tenant_id IS NULL;

  IF null_tenant_count > 0 THEN
    RAISE EXCEPTION '% profile(s) still have null tenant_id after backfill', null_tenant_count;
  END IF;

  RAISE NOTICE 'Migration 2 verified: independent id=%, uganda-airlines id=%, no null tenants',
    independent_id, ug_id;
END;
$$;
