-- =============================================================================
-- Migration: 20241101000005_guestora_config_tables.sql
-- Description: Guestora admin config tables — aircraft configs and menus
--
-- Tables:
--   guestora_aircraft_configs  — per-tenant seat layouts for each aircraft type
--   guestora_menus             — versioned menu snapshots per tenant
--
-- IDB → Server mapping (matches index.html IDB stores):
--   guestora_aircraft_configs  →  guestora_aircraft_configs  (same name)
--   guestora_menus             →  guestora_menus             (same name)
--
-- Design notes:
--   Aircraft configs:
--     • cabins is JSONB — stores the full cabin array with id, label, layout,
--       rows[], seats[], columns[][], seatCount matching GUESTORA_SEAT_CONFIGS
--     • aliases[] stored as text[] — alternate actype strings (e.g. 'B738' for 'B737')
--     • UNIQUE (tenant_id, actype) — one layout per aircraft type per tenant
--     • Admins can INSERT/UPDATE; crew can SELECT (needed for seat map render)
--
--   Menus:
--     • content is JSONB — stores the full category/subcategory/item tree,
--       matching the GUESTORA_DEFAULT_MENU structure: categories[{id, label, icon,
--       subcategories[{id, label, items[{id, name, description, allergens[],
--       dietary[], isSpecialMeal, available, sortOrder}]}]}]
--     • Only one menu per tenant may be active at a time — enforced by a partial
--       unique index on (tenant_id) WHERE is_active = true
--     • Admins manage menus; crew can SELECT (needed for order sheet picker)
--
-- RLS strategy (same anchor as all Guestora tables):
--   All policies resolve tenant via guestora_resolve_tenant_id().
--   Crew: SELECT only.
--   Admins (is_admin = true): SELECT + INSERT + UPDATE.
--   DELETE: no policy = denied (menus and configs are audit records).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. guestora_aircraft_configs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guestora_aircraft_configs (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,

  actype     text        NOT NULL,   -- e.g. 'A330-800', 'CRJ900', 'B737'
  aliases    text[]      NOT NULL DEFAULT '{}',  -- alternate type strings for fuzzy match

  -- Full cabin layout tree. Shape per cabin:
  --   { id, label, layout, rows[], seats[], columns[][], seatCount }
  cabins     jsonb       NOT NULL DEFAULT '[]'::jsonb,

  created_by uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  updated_by uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- One layout per aircraft type per tenant
  CONSTRAINT guestora_aircraft_configs_tenant_actype_unique
    UNIQUE (tenant_id, actype)
);

CREATE TRIGGER guestora_aircraft_configs_updated_at
  BEFORE UPDATE ON guestora_aircraft_configs
  FOR EACH ROW EXECUTE FUNCTION guestora_set_updated_at();

CREATE INDEX IF NOT EXISTS guestora_aircraft_configs_tenant_idx
  ON guestora_aircraft_configs (tenant_id);

-- ---------------------------------------------------------------------------
-- 2. guestora_menus
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guestora_menus (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,

  name         text        NOT NULL DEFAULT 'Default Menu',

  -- Full category/item tree. Top-level shape:
  --   [ { id, label, icon, subcategories: [ { id, label, items: [
  --       { id, name, description, allergens[], dietary[],
  --         isSpecialMeal, available, sortOrder } ] } ] } ]
  content      jsonb       NOT NULL DEFAULT '[]'::jsonb,

  is_active    boolean     NOT NULL DEFAULT false,
  published_at timestamptz,

  created_by   uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  updated_by   uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER guestora_menus_updated_at
  BEFORE UPDATE ON guestora_menus
  FOR EACH ROW EXECUTE FUNCTION guestora_set_updated_at();

-- Enforce at most one active menu per tenant at any time
CREATE UNIQUE INDEX IF NOT EXISTS guestora_menus_one_active_per_tenant
  ON guestora_menus (tenant_id)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS guestora_menus_tenant_idx
  ON guestora_menus (tenant_id);

CREATE INDEX IF NOT EXISTS guestora_menus_tenant_active_idx
  ON guestora_menus (tenant_id, is_active);

-- ---------------------------------------------------------------------------
-- 3. RLS — guestora_aircraft_configs
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_aircraft_configs ENABLE ROW LEVEL SECURITY;

-- SELECT: any crew in the tenant (needed for seat map render during service)
CREATE POLICY "guestora_aircraft_configs_select_own_tenant"
  ON guestora_aircraft_configs
  FOR SELECT
  TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id());

-- INSERT: admins only
CREATE POLICY "guestora_aircraft_configs_insert_admin"
  ON guestora_aircraft_configs
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND created_by = auth.uid()
    AND updated_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true
    )
  );

-- UPDATE: admins only; tenant reassignment blocked
CREATE POLICY "guestora_aircraft_configs_update_admin"
  ON guestora_aircraft_configs
  FOR UPDATE
  TO authenticated
  USING (
    tenant_id = guestora_resolve_tenant_id()
    AND EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true
    )
  )
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND updated_by = auth.uid()
  );

-- DELETE: no policy = denied

-- ---------------------------------------------------------------------------
-- 4. RLS — guestora_menus
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_menus ENABLE ROW LEVEL SECURITY;

-- SELECT: any crew in the tenant (needed for order sheet menu picker)
CREATE POLICY "guestora_menus_select_own_tenant"
  ON guestora_menus
  FOR SELECT
  TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id());

-- INSERT: admins only
CREATE POLICY "guestora_menus_insert_admin"
  ON guestora_menus
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND created_by = auth.uid()
    AND updated_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true
    )
  );

-- UPDATE: admins only (covers publish, deactivate, edit)
CREATE POLICY "guestora_menus_update_admin"
  ON guestora_menus
  FOR UPDATE
  TO authenticated
  USING (
    tenant_id = guestora_resolve_tenant_id()
    AND EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true
    )
  )
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND updated_by = auth.uid()
  );

-- DELETE: no policy = denied

-- ---------------------------------------------------------------------------
-- 5. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  ac_pol_count   integer;
  mn_pol_count   integer;
  ac_idx_exists  boolean;
  mn_idx_exists  boolean;
BEGIN
  -- Confirm aircraft configs policies
  SELECT COUNT(*) INTO ac_pol_count FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'guestora_aircraft_configs';

  IF ac_pol_count < 3 THEN
    RAISE EXCEPTION 'Expected 3 policies on guestora_aircraft_configs, found %', ac_pol_count;
  END IF;

  -- Confirm menus policies
  SELECT COUNT(*) INTO mn_pol_count FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'guestora_menus';

  IF mn_pol_count < 3 THEN
    RAISE EXCEPTION 'Expected 3 policies on guestora_menus, found %', mn_pol_count;
  END IF;

  -- Confirm partial unique index on menus (one active per tenant)
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename  = 'guestora_menus'
      AND indexname  = 'guestora_menus_one_active_per_tenant'
  ) INTO mn_idx_exists;

  IF NOT mn_idx_exists THEN
    RAISE EXCEPTION 'Partial unique index guestora_menus_one_active_per_tenant not found';
  END IF;

  RAISE NOTICE 'Migration 5 verified: guestora_aircraft_configs (% policies) + guestora_menus (% policies) + active-menu unique index confirmed',
    ac_pol_count, mn_pol_count;
END;
$$;
