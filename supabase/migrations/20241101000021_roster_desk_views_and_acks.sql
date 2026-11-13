-- =============================================================================
-- Migration: 20241101000021_roster_desk_views_and_acks.sql
-- Description: By-day / by-flight desk views, flight-wide changes, crew
--              acknowledgement of officer changes.
--
-- Requires migrations 17–20.
--
--   roster_desk_duties(from, to)     – every duty in a date window, with crew
--                                      (officer-only, max 31 days)
--   roster_apply_flight_change(...)  – apply one change to every crew member on
--                                      a flight/date (delay, cancel, retime…)
--   roster_ack_changes(roster)       – a crew member acknowledges the officer
--                                      changes on their own roster
--
-- Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('roster_apply_revision(uuid,jsonb,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 21 requires migrations 17-20.';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Duties in a date window, across crew
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS roster_desk_duties(date, date);
CREATE FUNCTION roster_desk_duties(p_from date, p_to date)
RETURNS TABLE (
  duty_id uuid, roster_id uuid, crew_user_id uuid, crew_name text, crew_code text,
  duty_date date, duty_type text, flight_number text, origin text, destination text,
  std_local text, sta_local text, status text, officer_locked boolean,
  last_change_type text, unacked boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Roster desk is for roster officers only.' USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 31 THEN
    RAISE EXCEPTION 'Choose a date window of up to 31 days.';
  END IF;

  RETURN QUERY
  SELECT d.id, d.roster_id, r.crew_user_id,
         COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), r.crew_name, 'Unknown'),
         COALESCE(r.crew_code, p.crew_code),
         d.duty_date, d.duty_type, d.flight_number, d.origin, d.destination,
         d.std_local, d.sta_local, d.status, d.officer_locked, d.last_change_type,
         EXISTS (SELECT 1 FROM roster_duty_changes c
                  WHERE c.duty_id = d.id AND c.source = 'officer' AND c.acknowledged_at IS NULL)
    FROM roster_duties d
    JOIN crew_rosters r ON r.id = d.roster_id AND r.tenant_id = v_tenant
    LEFT JOIN profiles p ON p.id = r.crew_user_id
   WHERE d.tenant_id = v_tenant
     AND d.duty_date BETWEEN p_from AND p_to
   ORDER BY d.duty_date, d.flight_number NULLS LAST, 4;
END;
$$;
REVOKE ALL ON FUNCTION roster_desk_duties(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_desk_duties(date, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Flight-wide change: one action, every crew member on the flight
--    Already-flown, removed and cancelled duties are left alone.
--    All or nothing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_apply_flight_change(
  p_flight       text,
  p_date         date,
  p_change_type  text,
  p_changes      jsonb,
  p_reason       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_ids     uuid[];
  v_id      uuid;
  v_skipped int;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers can change a whole flight.' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(btrim(p_flight), '') IS NULL OR p_date IS NULL THEN
    RAISE EXCEPTION 'A flight number and date are needed.';
  END IF;
  IF p_changes ? 'flight_number' OR p_changes ? 'duty_type' THEN
    RAISE EXCEPTION 'Flight-wide changes cover timing and status. Change a crew member''s flight or duty on their own roster.';
  END IF;

  SELECT array_agg(d.id ORDER BY d.id) INTO v_ids
    FROM roster_duties d
   WHERE d.duty_date = p_date
     AND upper(btrim(d.flight_number)) = upper(btrim(p_flight))
     AND d.status NOT IN ('completed','diverted','removed','cancelled');
  SELECT count(*) INTO v_skipped
    FROM roster_duties d
   WHERE d.duty_date = p_date
     AND upper(btrim(d.flight_number)) = upper(btrim(p_flight))
     AND d.status IN ('completed','diverted');

  IF v_ids IS NULL THEN
    RETURN jsonb_build_object('changed', 0, 'skipped_flown', v_skipped);
  END IF;

  FOREACH v_id IN ARRAY v_ids LOOP
    PERFORM roster_apply_change(v_id, p_change_type, p_changes, p_reason);
  END LOOP;

  RETURN jsonb_build_object('changed', array_length(v_ids, 1), 'skipped_flown', v_skipped);
END;
$$;
REVOKE ALL ON FUNCTION roster_apply_flight_change(text, date, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_apply_flight_change(text, date, text, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Crew acknowledge officer changes on their own roster
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_ack_changes(p_roster_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not signed in.' USING ERRCODE = '42501';
  END IF;
  UPDATE roster_duty_changes c
     SET acknowledged_at = now()
   WHERE c.roster_id = p_roster_id
     AND c.source = 'officer'
     AND c.acknowledged_at IS NULL
     AND EXISTS (SELECT 1 FROM crew_rosters r WHERE r.id = p_roster_id AND r.crew_user_id = auth.uid());
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION roster_ack_changes(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_ack_changes(uuid) TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('roster_desk_duties(date,date)') IS NULL
     OR to_regprocedure('roster_apply_flight_change(text,date,text,jsonb,text)') IS NULL
     OR to_regprocedure('roster_ack_changes(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Migration 21: functions not found';
  END IF;
  RAISE NOTICE 'Migration 21 verified: desk day/flight view, flight-wide change and acknowledgement in place.';
END;
$$;
