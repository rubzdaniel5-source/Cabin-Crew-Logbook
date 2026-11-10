-- =============================================================================
-- Migration: 20241101000007_guestora_sessions.sql
-- Description: CRANE CUISINE shared session workspace per individual flight sector
--
-- New objects:
--   guestora_sessions                   — shared workspace lifecycle per sector
--   guestora_check_flight_eligibility() — SECURITY DEFINER: does caller have this flight?
--   guestora_set_session_status()       — SECURITY DEFINER: open/close a session
--   guestora_sessions_immutable_identity trigger
--
-- Modified objects:
--   guestora_service_orders: add additional_request column
--   guestora_service_packages: relax UPDATE policy from created_by-only to any eligible crew
--   guestora_service_orders INSERT + UPDATE: add session-open gate
--   guestora_service_orders: add package_id immutability trigger
--
-- Architecture notes:
--   • A session is keyed on (tenant_id, flight_number, flight_date) UNIQUE.
--     flight_number is the INDIVIDUAL sector number (e.g. 'UR206' or 'UR207'),
--     derived client-side by parsing the combined string stored in flights.flight_num
--     (e.g. 'UR206/7' → ['UR206','UR207']) using parseCombinedFlightNum().
--   • A 3-sector duty has one flight number throughout; one session serves all 3 sectors.
--   • A 4-sector duty: fn1 'UR206/7' → sessions for UR206 + UR207;
--                       fn2 'UR202/3' → sessions for UR202 + UR203.
--   • Sessions may exist without any package or orders (workspace opened, no orders taken).
--   • Package FK to session is not used — the natural key tuple is sufficient.
--     Session-open enforcement is at the order INSERT/UPDATE RLS level.
--   • flight_date = the duty's date field (crew entry date), even for midnight-crossing duties.
--   • guestora_check_flight_eligibility() checks flights.flight_num AND flights.flight_num_2
--     using parsed individual sector numbers.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Helper: guestora_set_updated_at() must exist (created in migration 3)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. guestora_sessions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guestora_sessions (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,

  -- Individual sector identity — parsed from flights.flight_num / flight_num_2
  -- e.g. 'UR206' (never the combined 'UR206/7')
  flight_number  text        NOT NULL,
  flight_date    date        NOT NULL,

  -- Lifecycle: open → closed (reversible via guestora_set_session_status())
  status         text        NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'closed')),

  -- Authorship
  opened_by      uuid        NOT NULL REFERENCES profiles(id) ON DELETE RESTRICT,
  opened_at      timestamptz NOT NULL DEFAULT now(),
  closed_by      uuid        REFERENCES profiles(id) ON DELETE RESTRICT,
  closed_at      timestamptz,

  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- One session per tenant per individual sector per date
  CONSTRAINT guestora_sessions_tenant_flight_date_unique
    UNIQUE (tenant_id, flight_number, flight_date)
);

CREATE TRIGGER guestora_sessions_updated_at
  BEFORE UPDATE ON guestora_sessions
  FOR EACH ROW EXECUTE FUNCTION guestora_set_updated_at();

CREATE INDEX IF NOT EXISTS guestora_sessions_tenant_idx
  ON guestora_sessions (tenant_id);

CREATE INDEX IF NOT EXISTS guestora_sessions_flight_date_idx
  ON guestora_sessions (tenant_id, flight_number, flight_date);

CREATE INDEX IF NOT EXISTS guestora_sessions_status_idx
  ON guestora_sessions (tenant_id, status);

-- ---------------------------------------------------------------------------
-- 2. guestora_check_flight_eligibility()
--    SECURITY DEFINER — the only trusted path for flight ownership verification.
--    Returns true if the authenticated user has a duty record where either
--    flight_num OR flight_num_2 (after parsing) contains p_flight_number.
--
--    For combined strings like 'UR206/7':
--      - The individual number 'UR206' matches flight_num = 'UR206/7'?
--        → YES via the prefix match: upper(trim('UR206/7')) like 'UR206%'
--        → AND the suffix check: 'UR206' is the base of 'UR206/7'
--      This logic is kept SIMPLE and SAFE by checking two patterns:
--        (a) exact match: trim(flight_num) = p_flight_number
--        (b) combined prefix: p_flight_number is base of flight_num combined string
--            i.e. flight_num starts with p_flight_number and next char is '/'
--      Pattern (b) handles 'UR206' matching stored 'UR206/7'.
--      For the second number 'UR207', the client derives it and passes it here;
--      the DB checks exact match (stored 'UR206/7' does NOT exactly equal 'UR207').
--      Therefore for the second half of a pair, the client must also check flight_num_2
--      and the same two-pattern approach applies there.
--
--    Net result: eligible if p_flight_number matches either stored field by exact
--    or combined-string-base match.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guestora_check_flight_eligibility(
  p_flight_number text,
  p_flight_date   date
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_uid uuid;
  v_normalized text;
BEGIN
  -- Reject unauthenticated callers immediately
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN false;
  END IF;

  -- Normalize to match client-side .toUpperCase().trim()
  v_normalized := upper(trim(p_flight_number));

  RETURN EXISTS (
    SELECT 1
    FROM public.flights
    WHERE user_id = v_uid
      AND date = p_flight_date
      AND (
        -- flight_num: exact match (e.g. single-sector 'UR110' = 'UR110')
        upper(trim(flight_num)) = v_normalized
        -- flight_num: base of combined string (e.g. 'UR206' matches stored 'UR206/7')
        OR (
          upper(trim(flight_num)) LIKE (v_normalized || '/%')
        )
        -- flight_num: second number of combined string
        -- e.g. 'UR207' matches stored 'UR206/7' via suffix reconstruction
        OR (
          flight_num IS NOT NULL
          AND position('/' IN flight_num) > 0
          AND v_normalized = (
            -- Reconstruct second number: take alpha prefix + base digits with suffix replaced
            -- e.g. 'UR206/7' → prefix='UR', base_digits='206', suffix='7' → 'UR207'
            regexp_replace(upper(trim(flight_num)), '^([A-Z]+)(\d+)/(\d+)$',
              '\1' || -- airline prefix (e.g. 'UR')
              regexp_replace(
                -- replace last N digits of base with suffix
                regexp_replace(upper(trim(flight_num)), '^[A-Z]+(\d+)/\d+$', '\1'),
                '\d{' || length(split_part(upper(trim(flight_num)), '/', 2)) || '}$',
                split_part(upper(trim(flight_num)), '/', 2)
              )
            )
          )
        )
        -- flight_num_2: same three patterns
        OR upper(trim(flight_num_2)) = v_normalized
        OR (
          flight_num_2 IS NOT NULL
          AND upper(trim(flight_num_2)) LIKE (v_normalized || '/%')
        )
        OR (
          flight_num_2 IS NOT NULL
          AND position('/' IN flight_num_2) > 0
          AND v_normalized = (
            regexp_replace(upper(trim(flight_num_2)), '^([A-Z]+)(\d+)/(\d+)$',
              '\1' ||
              regexp_replace(
                regexp_replace(upper(trim(flight_num_2)), '^[A-Z]+(\d+)/\d+$', '\1'),
                '\d{' || length(split_part(upper(trim(flight_num_2)), '/', 2)) || '}$',
                split_part(upper(trim(flight_num_2)), '/', 2)
              )
            )
          )
        )
      )
  );
END;
$$;

-- Restrict EXECUTE: only authenticated users (anon has no access)
REVOKE ALL ON FUNCTION guestora_check_flight_eligibility(text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION guestora_check_flight_eligibility(text, date) FROM anon;
GRANT EXECUTE ON FUNCTION guestora_check_flight_eligibility(text, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. guestora_set_session_status()
--    SECURITY DEFINER — the ONLY UPDATE path for sessions.
--    No broad UPDATE RLS policy exists; identity fields are never changed here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guestora_set_session_status(
  p_session_id uuid,
  p_new_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_uid    uuid;
  v_session public.guestora_sessions%ROWTYPE;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_new_status NOT IN ('open', 'closed') THEN
    RAISE EXCEPTION 'invalid session status: %', p_new_status;
  END IF;

  -- Load session and verify tenant membership
  SELECT * INTO v_session
  FROM public.guestora_sessions
  WHERE id = p_session_id
    AND tenant_id = guestora_resolve_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found or not in your tenant';
  END IF;

  -- Verify flight eligibility
  IF NOT guestora_check_flight_eligibility(v_session.flight_number, v_session.flight_date) THEN
    RAISE EXCEPTION 'not eligible for sector % on %', v_session.flight_number, v_session.flight_date;
  END IF;

  -- Update only lifecycle fields; identity fields untouched
  IF p_new_status = 'closed' THEN
    UPDATE public.guestora_sessions
    SET status     = 'closed',
        closed_by  = v_uid,
        closed_at  = now(),
        updated_at = now()
    WHERE id = p_session_id;
  ELSE
    UPDATE public.guestora_sessions
    SET status     = 'open',
        closed_by  = NULL,
        closed_at  = NULL,
        updated_at = now()
    WHERE id = p_session_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION guestora_set_session_status(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION guestora_set_session_status(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION guestora_set_session_status(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. RLS — guestora_sessions
--    SELECT + INSERT only. UPDATE goes through guestora_set_session_status() only.
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_sessions ENABLE ROW LEVEL SECURITY;

-- SELECT: crew can read sessions they are eligible for within their tenant
CREATE POLICY "guestora_sessions_select"
  ON guestora_sessions
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = guestora_resolve_tenant_id()
    AND guestora_check_flight_eligibility(flight_number, flight_date)
  );

-- INSERT: crew can create sessions; tenant_id and opened_by are enforced here
CREATE POLICY "guestora_sessions_insert"
  ON guestora_sessions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND opened_by = auth.uid()
    AND guestora_check_flight_eligibility(flight_number, flight_date)
  );

-- No UPDATE policy — guestora_set_session_status() handles all updates
-- No DELETE policy — sessions are permanent audit records

-- ---------------------------------------------------------------------------
-- 5. Identity immutability trigger on guestora_sessions
--    Prevents any UPDATE from changing identity fields, even via admin.
--    guestora_set_session_status() only changes status/closed_by/closed_at/updated_at.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guestora_sessions_guard_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.tenant_id      <> OLD.tenant_id      THEN RAISE EXCEPTION 'session tenant_id is immutable'; END IF;
  IF NEW.flight_number  <> OLD.flight_number  THEN RAISE EXCEPTION 'session flight_number is immutable'; END IF;
  IF NEW.flight_date    <> OLD.flight_date    THEN RAISE EXCEPTION 'session flight_date is immutable'; END IF;
  IF NEW.opened_by      <> OLD.opened_by      THEN RAISE EXCEPTION 'session opened_by is immutable'; END IF;
  IF NEW.opened_at      <> OLD.opened_at      THEN RAISE EXCEPTION 'session opened_at is immutable'; END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER guestora_sessions_immutable_identity
  BEFORE UPDATE ON guestora_sessions
  FOR EACH ROW EXECUTE FUNCTION guestora_sessions_guard_identity();

-- ---------------------------------------------------------------------------
-- 6. additional_request column on guestora_service_orders
--    Free-text field for off-menu items available on board.
--    Distinct from special_note (allergy/pre-order alert).
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_service_orders
  ADD COLUMN IF NOT EXISTS additional_request text;

COMMENT ON COLUMN guestora_service_orders.additional_request
  IS 'Passenger request for available off-menu items (e.g. extra bread roll, specific drink not on menu). Distinct from special_note which is for allergy alerts and pre-ordered meals.';

-- ---------------------------------------------------------------------------
-- 7. Relax guestora_service_packages UPDATE policy
--    Original policy restricted UPDATE to created_by = auth.uid() only.
--    Any eligible crew member (same tenant, flight-eligible) may update
--    package fields such as actype correction.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "guestora_packages_update_own" ON guestora_service_packages;

CREATE POLICY "guestora_packages_update_eligible_crew"
  ON guestora_service_packages
  FOR UPDATE
  TO authenticated
  USING (
    tenant_id = guestora_resolve_tenant_id()
    AND guestora_check_flight_eligibility(flight_number, date)
  )
  WITH CHECK (
    tenant_id = guestora_resolve_tenant_id()
  );

-- ---------------------------------------------------------------------------
-- 8. Add session-open gate to guestora_service_orders INSERT + UPDATE
--    Orders may only be written against packages whose session is open.
--    This replaces the existing policies.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "guestora_orders_insert_own_tenant" ON guestora_service_orders;
DROP POLICY IF EXISTS "guestora_orders_update_own_tenant" ON guestora_service_orders;

CREATE POLICY "guestora_orders_insert_own_tenant"
  ON guestora_service_orders
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND created_by = auth.uid()
    AND updated_by = auth.uid()
    -- Package must exist in this tenant
    AND EXISTS (
      SELECT 1 FROM guestora_service_packages p
      WHERE p.id = package_id
        AND p.tenant_id = guestora_resolve_tenant_id()
    )
    -- Corresponding session must be open
    AND EXISTS (
      SELECT 1
      FROM guestora_sessions gs
      INNER JOIN guestora_service_packages gsp
        ON  gsp.tenant_id     = gs.tenant_id
        AND gsp.flight_number = gs.flight_number
        AND gsp.date          = gs.flight_date
      WHERE gsp.id        = package_id
        AND gs.tenant_id  = guestora_resolve_tenant_id()
        AND gs.status     = 'open'
    )
  );

CREATE POLICY "guestora_orders_update_own_tenant"
  ON guestora_service_orders
  FOR UPDATE
  TO authenticated
  USING  (tenant_id = guestora_resolve_tenant_id())
  WITH CHECK (
    tenant_id  = guestora_resolve_tenant_id()
    AND updated_by = auth.uid()
    -- Session must still be open for updates too
    AND EXISTS (
      SELECT 1
      FROM guestora_sessions gs
      INNER JOIN guestora_service_packages gsp
        ON  gsp.tenant_id     = gs.tenant_id
        AND gsp.flight_number = gs.flight_number
        AND gsp.date          = gs.flight_date
      WHERE gsp.id        = package_id
        AND gs.tenant_id  = guestora_resolve_tenant_id()
        AND gs.status     = 'open'
    )
  );

-- ---------------------------------------------------------------------------
-- 9. package_id immutability trigger on guestora_service_orders
--    Prevents an order from being reassigned to a different package.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guestora_orders_guard_package_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.package_id <> OLD.package_id THEN
    RAISE EXCEPTION 'order package_id is immutable — an order cannot be moved between packages';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER guestora_orders_immutable_package_id
  BEFORE UPDATE ON guestora_service_orders
  FOR EACH ROW EXECUTE FUNCTION guestora_orders_guard_package_id();

-- ---------------------------------------------------------------------------
-- 10. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_sessions_exists  integer;
  v_elig_exists      integer;
  v_status_exists    integer;
  v_addl_req_exists  integer;
  v_sess_pol_count   integer;
BEGIN
  SELECT COUNT(*) INTO v_sessions_exists FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'guestora_sessions';
  IF v_sessions_exists = 0 THEN
    RAISE EXCEPTION 'guestora_sessions table not created';
  END IF;

  SELECT COUNT(*) INTO v_elig_exists FROM pg_proc
    WHERE proname = 'guestora_check_flight_eligibility'
      AND pronamespace = 'public'::regnamespace;
  IF v_elig_exists = 0 THEN
    RAISE EXCEPTION 'guestora_check_flight_eligibility function not created';
  END IF;

  SELECT COUNT(*) INTO v_status_exists FROM pg_proc
    WHERE proname = 'guestora_set_session_status'
      AND pronamespace = 'public'::regnamespace;
  IF v_status_exists = 0 THEN
    RAISE EXCEPTION 'guestora_set_session_status function not created';
  END IF;

  SELECT COUNT(*) INTO v_addl_req_exists FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'guestora_service_orders'
      AND column_name = 'additional_request';
  IF v_addl_req_exists = 0 THEN
    RAISE EXCEPTION 'additional_request column not added to guestora_service_orders';
  END IF;

  SELECT COUNT(*) INTO v_sess_pol_count FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'guestora_sessions';
  IF v_sess_pol_count < 2 THEN
    RAISE EXCEPTION 'Expected at least 2 policies on guestora_sessions, found %', v_sess_pol_count;
  END IF;

  RAISE NOTICE 'Migration 7 verified: guestora_sessions ready, eligibility + lifecycle functions ready, additional_request added, session-open gate on orders active';
END;
$$;
