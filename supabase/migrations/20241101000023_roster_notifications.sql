-- =============================================================================
-- Migration: 20241101000023_roster_notifications.sql
-- Description: In-app roster notifications
--
-- Requires migrations 17-22.
--
--   roster_officer_seen            – when each officer last looked at the activity feed
--   roster_activity(limit)         – recent roster changes across the airline,
--                                    with a "new since you last looked" flag (officers)
--   roster_activity_count()        – how many crew-reported changes are new (officers)
--   roster_activity_mark_seen()    – "I've looked"
--   roster_my_unacked_count()      – officer changes a crew member has not acknowledged
--
-- Flown-record changes (completed / diverted) are not notifications.
-- Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('roster_swap_duties(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 23 requires migrations 17-22.';
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS roster_officer_seen (
  user_id uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  seen_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE roster_officer_seen ENABLE ROW LEVEL SECURITY;
-- No policies: only the SECURITY DEFINER functions below touch it.

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_activity_count()
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_seen   timestamptz;
  v_n      int;
BEGIN
  IF auth.uid() IS NULL OR NOT roster_is_officer() THEN RETURN 0; END IF;
  SELECT s.seen_at INTO v_seen FROM roster_officer_seen s WHERE s.user_id = auth.uid();
  SELECT count(*) INTO v_n
    FROM roster_duty_changes c
   WHERE c.tenant_id = v_tenant
     AND c.source = 'crew'
     AND c.change_type NOT IN ('completed','diverted')
     AND c.changed_at > COALESCE(v_seen, now() - interval '7 days')
     AND c.changed_by IS DISTINCT FROM auth.uid();
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION roster_activity_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_activity_count() TO authenticated;

-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS roster_activity(int);
CREATE FUNCTION roster_activity(p_limit int DEFAULT 80)
RETURNS TABLE (
  change_id uuid, changed_at timestamptz, source text, change_type text, reason text,
  old_values jsonb, new_values jsonb, acknowledged_at timestamptz,
  roster_id uuid, duty_id uuid, crew_user_id uuid, crew_name text, crew_code text,
  duty_date date, flight_number text, is_new boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_seen   timestamptz;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Roster activity is for roster officers only.' USING ERRCODE = '42501';
  END IF;
  SELECT s.seen_at INTO v_seen FROM roster_officer_seen s WHERE s.user_id = auth.uid();

  RETURN QUERY
  SELECT c.id, c.changed_at, c.source, c.change_type, c.reason,
         c.old_values, c.new_values, c.acknowledged_at,
         c.roster_id, c.duty_id, r.crew_user_id,
         COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), r.crew_name, 'Unknown'),
         COALESCE(r.crew_code, p.crew_code),
         d.duty_date, d.flight_number,
         (c.source = 'crew' AND c.changed_at > COALESCE(v_seen, now() - interval '7 days')
          AND c.changed_by IS DISTINCT FROM auth.uid())
    FROM roster_duty_changes c
    JOIN crew_rosters r ON r.id = c.roster_id AND r.tenant_id = v_tenant
    JOIN roster_duties d ON d.id = c.duty_id
    LEFT JOIN profiles p ON p.id = r.crew_user_id
   WHERE c.tenant_id = v_tenant
     AND c.change_type NOT IN ('completed','diverted')
   ORDER BY c.changed_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
END;
$$;
REVOKE ALL ON FUNCTION roster_activity(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_activity(int) TO authenticated;

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_activity_mark_seen()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT roster_is_officer() THEN RETURN; END IF;
  INSERT INTO roster_officer_seen (user_id, seen_at) VALUES (auth.uid(), now())
  ON CONFLICT (user_id) DO UPDATE SET seen_at = EXCLUDED.seen_at;
END;
$$;
REVOKE ALL ON FUNCTION roster_activity_mark_seen() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_activity_mark_seen() TO authenticated;

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_my_unacked_count()
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT count(*)::int
    FROM roster_duty_changes c
    JOIN crew_rosters r ON r.id = c.roster_id
   WHERE r.crew_user_id = auth.uid()
     AND c.source = 'officer'
     AND c.acknowledged_at IS NULL;
$$;
REVOKE ALL ON FUNCTION roster_my_unacked_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_my_unacked_count() TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('roster_activity(int)') IS NULL
     OR to_regprocedure('roster_activity_count()') IS NULL
     OR to_regprocedure('roster_activity_mark_seen()') IS NULL
     OR to_regprocedure('roster_my_unacked_count()') IS NULL THEN
    RAISE EXCEPTION 'Migration 23: functions not found';
  END IF;
  RAISE NOTICE 'Migration 23 verified: roster notifications in place.';
END;
$$;
