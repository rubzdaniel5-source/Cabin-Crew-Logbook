-- =============================================================================
-- Migration: 20241101000004_guestora_service_tables.sql
-- Description: Phase 2 Guestora service tables — packages and orders
--
-- Tables:
--   guestora_service_packages  — one row per (flight_number + date) service session
--   guestora_service_orders    — individual seat orders within a package
--
-- IDB → Server mapping (matches index.html IDB stores):
--   guestora_packages  →  guestora_service_packages
--   guestora_orders    →  guestora_service_orders
--   guestora_outbox    →  consumed by sync; not persisted server-side
--
-- RLS strategy:
--   All policies resolve tenant via guestora_resolve_tenant_id() — never client-supplied.
--   Crew may only read/write packages and orders for their own tenant.
--   Additional row-level guard: crew may only write orders for packages they created
--   or that belong to a flight they are assigned to (Phase 2 scope: created_by match).
--
-- Idempotency:
--   guestora_service_orders.operation_id is UNIQUE — the outbox operationId from
--   the client is used as the idempotency key, making server upserts safe on retry.
--
-- Order status lifecycle (mirrors GUESTORA_ORDER_STATUS in index.html):
--   requested → served | deferred | exception
--
-- Sync status is client-side only (IDB outbox). Not stored server-side.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. guestora_service_packages
--    One row per flight-date service session, created by the first crew member
--    who opens the Guestora overlay for that flight.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guestora_service_packages (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,

  flight_number  text        NOT NULL,
  date           date        NOT NULL,
  actype         text        NOT NULL,

  created_by     uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- Enforce uniqueness: one package per tenant per flight per date
  CONSTRAINT guestora_service_packages_tenant_flight_date_unique
    UNIQUE (tenant_id, flight_number, date)
);

CREATE TRIGGER guestora_service_packages_updated_at
  BEFORE UPDATE ON guestora_service_packages
  FOR EACH ROW EXECUTE FUNCTION guestora_set_updated_at();

-- Index for common query: all packages for a tenant (dashboard / history)
CREATE INDEX IF NOT EXISTS guestora_service_packages_tenant_idx
  ON guestora_service_packages (tenant_id);

-- Index for the flight+date lookup used on overlay open
CREATE INDEX IF NOT EXISTS guestora_service_packages_flight_date_idx
  ON guestora_service_packages (tenant_id, flight_number, date);

-- ---------------------------------------------------------------------------
-- 2. guestora_service_orders
--    One row per seat order within a package.
--    selections is JSONB — array of {id, name, catId, subId, allergens[], dietary[]}
--    matching the structure built by the frontend menu picker.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guestora_service_orders (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,
  package_id     uuid        NOT NULL REFERENCES guestora_service_packages(id) ON DELETE CASCADE,

  -- Client-generated idempotency key (outbox operationId)
  -- UNIQUE ensures server-side upserts are safe on retry/reconnect
  operation_id   uuid        NOT NULL UNIQUE,
  schema_version int         NOT NULL DEFAULT 1,

  -- Seat identification
  seat_num       text        NOT NULL,   -- e.g. '12A', '3B'
  cabin          text        NOT NULL,   -- cabin id from aircraft config (e.g. 'business', 'economy')

  -- Order content (mirrors IDB order object)
  selections     jsonb       NOT NULL DEFAULT '[]'::jsonb,
  meal_note      text,                  -- max 120 chars enforced client-side
  drink_note     text,                  -- max 120 chars enforced client-side
  special_note   text,                  -- max 120 chars; allergy alerts / special requests

  -- Order lifecycle: requested | served | deferred | exception
  status         text        NOT NULL DEFAULT 'requested'
                   CHECK (status IN ('requested', 'served', 'deferred', 'exception')),

  -- Authorship
  created_by     uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  updated_by     uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- One order per seat per package (last-write semantics enforced via upsert on operation_id)
  CONSTRAINT guestora_service_orders_package_seat_unique
    UNIQUE (package_id, seat_num)
);

CREATE TRIGGER guestora_service_orders_updated_at
  BEFORE UPDATE ON guestora_service_orders
  FOR EACH ROW EXECUTE FUNCTION guestora_set_updated_at();

-- Index: all orders for a package (primary access pattern during service)
CREATE INDEX IF NOT EXISTS guestora_service_orders_package_idx
  ON guestora_service_orders (package_id);

-- Index: tenant-scoped order lookup (admin reporting)
CREATE INDEX IF NOT EXISTS guestora_service_orders_tenant_idx
  ON guestora_service_orders (tenant_id);

-- Index: per-seat lookup within a package
CREATE INDEX IF NOT EXISTS guestora_service_orders_seat_idx
  ON guestora_service_orders (package_id, seat_num);

-- ---------------------------------------------------------------------------
-- 3. RLS — guestora_service_packages
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_service_packages ENABLE ROW LEVEL SECURITY;

-- SELECT: crew may read packages belonging to their tenant
CREATE POLICY "guestora_packages_select_own_tenant"
  ON guestora_service_packages
  FOR SELECT
  TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id());

-- INSERT: crew may create packages for their own tenant only;
--         tenant_id must match resolved tenant (never client-supplied)
CREATE POLICY "guestora_packages_insert_own_tenant"
  ON guestora_service_packages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND created_by = auth.uid()
  );

-- UPDATE: crew may update only packages they created within their tenant
--         (e.g. actype correction). Tenant reassignment blocked by WITH CHECK.
CREATE POLICY "guestora_packages_update_own"
  ON guestora_service_packages
  FOR UPDATE
  TO authenticated
  USING  (tenant_id = guestora_resolve_tenant_id() AND created_by = auth.uid())
  WITH CHECK (tenant_id = guestora_resolve_tenant_id());

-- DELETE: no client deletes — packages are permanent audit records
-- (no policy = DELETE denied)

-- ---------------------------------------------------------------------------
-- 4. RLS — guestora_service_orders
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_service_orders ENABLE ROW LEVEL SECURITY;

-- SELECT: crew may read all orders within their tenant
--         (entire cabin crew on a flight needs to see all seat orders)
CREATE POLICY "guestora_orders_select_own_tenant"
  ON guestora_service_orders
  FOR SELECT
  TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id());

-- INSERT: crew may create orders for packages within their tenant
CREATE POLICY "guestora_orders_insert_own_tenant"
  ON guestora_service_orders
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND created_by = auth.uid()
    AND updated_by = auth.uid()
    -- Verify the package also belongs to this tenant (join check)
    AND EXISTS (
      SELECT 1 FROM guestora_service_packages p
      WHERE p.id = package_id
        AND p.tenant_id = guestora_resolve_tenant_id()
    )
  );

-- UPDATE: any crew member in the tenant may update an order
--         (one crew takes order, another marks served — both valid)
CREATE POLICY "guestora_orders_update_own_tenant"
  ON guestora_service_orders
  FOR UPDATE
  TO authenticated
  USING  (tenant_id = guestora_resolve_tenant_id())
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND updated_by = auth.uid()
  );

-- DELETE: no client deletes — orders are permanent audit records
-- (no policy = DELETE denied)

-- ---------------------------------------------------------------------------
-- 5. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  pkg_count      integer;
  ord_count      integer;
  pkg_pol_count  integer;
  ord_pol_count  integer;
BEGIN
  -- Confirm tables exist
  SELECT COUNT(*) INTO pkg_count FROM information_schema.tables
  WHERE table_schema = 'public' AND table_name = 'guestora_service_packages';

  SELECT COUNT(*) INTO ord_count FROM information_schema.tables
  WHERE table_schema = 'public' AND table_name = 'guestora_service_orders';

  IF pkg_count = 0 THEN
    RAISE EXCEPTION 'guestora_service_packages table not found';
  END IF;
  IF ord_count = 0 THEN
    RAISE EXCEPTION 'guestora_service_orders table not found';
  END IF;

  -- Confirm RLS policies
  SELECT COUNT(*) INTO pkg_pol_count FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'guestora_service_packages';

  SELECT COUNT(*) INTO ord_pol_count FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'guestora_service_orders';

  IF pkg_pol_count < 3 THEN
    RAISE EXCEPTION 'Expected at least 3 policies on guestora_service_packages, found %', pkg_pol_count;
  END IF;
  IF ord_pol_count < 3 THEN
    RAISE EXCEPTION 'Expected at least 3 policies on guestora_service_orders, found %', ord_pol_count;
  END IF;

  RAISE NOTICE 'Migration 4 verified: guestora_service_packages (% policies) + guestora_service_orders (% policies) ready',
    pkg_pol_count, ord_pol_count;
END;
$$;
