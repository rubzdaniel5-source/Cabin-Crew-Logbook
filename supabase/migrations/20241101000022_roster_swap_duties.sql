-- =============================================================================
-- Migration: 20241101000022_roster_swap_duties.sql
-- Description: Officer swaps two crew members' duties (e.g. one flight each,
--              or a flight for a standby) in one step.
--
-- Requires migrations 17-21.
--
--   roster_swap_duties(duty_a, duty_b, reason)
--     Each crew member takes the other's duty (type, date, flight, route,
--     times, block, status). Both changes are recorded in the history as
--     'swapped', naming the other crew member. Applies completely or not at all.
--     Refuses duties that are already flown, removed, cancelled or no-show,
--     two duties of the same crew member, and non-officers.
--
-- Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('roster_apply_flight_change(text,date,text,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 22 requires migrations 17-21.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION roster_swap_duties(
  p_duty_a uuid,
  p_duty_b uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  a roster_duties;
  b roster_duties;
  ra crew_rosters;
  rb crew_rosters;
  na text;
  nb text;
  v_why text := COALESCE(NULLIF(btrim(p_reason), ''), '');
  v_a jsonb;
  v_b jsonb;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers can swap duties.' USING ERRCODE = '42501';
  END IF;
  IF p_duty_a IS NULL OR p_duty_b IS NULL OR p_duty_a = p_duty_b THEN
    RAISE EXCEPTION 'Choose two different duties to swap.';
  END IF;

  SELECT * INTO a FROM roster_duties WHERE id = p_duty_a FOR UPDATE;
  SELECT * INTO b FROM roster_duties WHERE id = p_duty_b FOR UPDATE;
  IF a.id IS NULL OR b.id IS NULL THEN
    RAISE EXCEPTION 'Duty not found, or you are not allowed to change it.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO ra FROM crew_rosters WHERE id = a.roster_id;
  SELECT * INTO rb FROM crew_rosters WHERE id = b.roster_id;

  IF ra.id = rb.id
     OR (ra.crew_user_id IS NOT NULL AND ra.crew_user_id = rb.crew_user_id) THEN
    RAISE EXCEPTION 'Both duties belong to the same crew member.';
  END IF;
  IF a.status IN ('completed','diverted','removed','cancelled','no_show')
     OR b.status IN ('completed','diverted','removed','cancelled','no_show') THEN
    RAISE EXCEPTION 'A duty that is already flown, removed or cancelled cannot be swapped.';
  END IF;

  SELECT COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), ra.crew_name, 'crew member')
    INTO na FROM (SELECT 1) x LEFT JOIN profiles p ON p.id = ra.crew_user_id;
  SELECT COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), rb.crew_name, 'crew member')
    INTO nb FROM (SELECT 1) x LEFT JOIN profiles p ON p.id = rb.crew_user_id;

  -- A gets B's duty
  SELECT to_jsonb(r) INTO v_a FROM roster_apply_change(a.id, 'swapped', jsonb_build_object(
      'duty_type', b.duty_type, 'duty_date', b.duty_date, 'flight_number', b.flight_number,
      'origin', b.origin, 'destination', b.destination,
      'std_local', b.std_local, 'std_utc', b.std_utc, 'sta_local', b.sta_local, 'sta_utc', b.sta_utc,
      'block_scheduled_mins', b.block_scheduled_mins, 'status', b.status),
      trim('Swapped with ' || nb || CASE WHEN v_why <> '' THEN ' — ' || v_why ELSE '' END)) r;
  -- B gets A's duty (taken from the row as it was before the swap)
  SELECT to_jsonb(r) INTO v_b FROM roster_apply_change(b.id, 'swapped', jsonb_build_object(
      'duty_type', a.duty_type, 'duty_date', a.duty_date, 'flight_number', a.flight_number,
      'origin', a.origin, 'destination', a.destination,
      'std_local', a.std_local, 'std_utc', a.std_utc, 'sta_local', a.sta_local, 'sta_utc', a.sta_utc,
      'block_scheduled_mins', a.block_scheduled_mins, 'status', a.status),
      trim('Swapped with ' || na || CASE WHEN v_why <> '' THEN ' — ' || v_why ELSE '' END)) r;

  RETURN jsonb_build_object('a', v_a, 'b', v_b);
END;
$$;
REVOKE ALL ON FUNCTION roster_swap_duties(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_swap_duties(uuid, uuid, text) TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('roster_swap_duties(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 22: roster_swap_duties not found';
  END IF;
  RAISE NOTICE 'Migration 22 verified: roster_swap_duties() in place.';
END;
$$;
