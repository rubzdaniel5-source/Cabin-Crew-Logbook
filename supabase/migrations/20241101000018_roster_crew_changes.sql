-- =============================================================================
-- Migration: 20241101000018_roster_crew_changes.sql
-- Description: Crew-reported roster changes — "officer wins" rule + add duty
--
-- Requires migration 17.
--
--   1. Officer wins: once a roster officer has changed a duty, it is marked
--      officer_locked and the crew member can no longer change its schedule
--      or status themselves. They can still mark it as flown. (Policy
--      decision — relax by dropping the roster_duties_officer_wins triggers.)
--   2. roster_add_duty(): add a duty after publication (extra flight, extra
--      sector). Logged in the history as 'added'.
--
-- Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.roster_duty_changes') IS NULL THEN
    RAISE EXCEPTION 'Migration 18 requires migration 17 (roster_duty_changes not found).';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Officer wins
-- ---------------------------------------------------------------------------
ALTER TABLE roster_duties
  ADD COLUMN IF NOT EXISTS officer_locked boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN roster_duties.officer_locked IS
  'true once a roster officer has changed (or added) this duty. The crew member '
  'can then only mark it as flown; further changes go through the officer.';

-- Duties an officer already changed before this migration
UPDATE roster_duties d
   SET officer_locked = true
 WHERE NOT d.officer_locked
   AND EXISTS (SELECT 1 FROM roster_duty_changes c
                WHERE c.duty_id = d.id AND c.source = 'officer');

CREATE OR REPLACE FUNCTION roster_duties_officer_wins()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_owner      uuid;
  v_as_officer boolean;
  v_changed    boolean;
BEGIN
  IF auth.uid() IS NULL THEN                       -- SQL editor / service role
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- An officer acting on someone else's roster is acting as an officer.
  SELECT r.crew_user_id INTO v_owner FROM crew_rosters r WHERE r.id = OLD.roster_id;
  v_as_officer := roster_is_officer() AND v_owner IS DISTINCT FROM auth.uid();

  IF TG_OP = 'DELETE' THEN
    IF OLD.officer_locked AND NOT v_as_officer THEN
      RAISE EXCEPTION 'This roster contains changes made by your roster officer and cannot be deleted.'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  v_changed :=
     (NEW.duty_type, NEW.duty_date, NEW.flight_number, NEW.origin, NEW.destination,
      NEW.std_local, NEW.std_utc, NEW.sta_local, NEW.sta_utc,
      NEW.block_scheduled_mins, NEW.remark, NEW.status)
     IS DISTINCT FROM
     (OLD.duty_type, OLD.duty_date, OLD.flight_number, OLD.origin, OLD.destination,
      OLD.std_local, OLD.std_utc, OLD.sta_local, OLD.sta_utc,
      OLD.block_scheduled_mins, OLD.remark, OLD.status);

  IF v_as_officer THEN
    IF v_changed THEN NEW.officer_locked := true; END IF;
    RETURN NEW;
  END IF;

  -- Acting as crew: the lock itself cannot be touched.
  NEW.officer_locked := OLD.officer_locked;
  IF NOT OLD.officer_locked THEN
    RETURN NEW;
  END IF;

  -- Crew may still record the flight as flown, and correct completion details.
  IF (NEW.duty_type, NEW.duty_date, NEW.flight_number, NEW.origin, NEW.destination,
      NEW.std_local, NEW.std_utc, NEW.sta_local, NEW.sta_utc,
      NEW.block_scheduled_mins, NEW.remark)
     IS DISTINCT FROM
     (OLD.duty_type, OLD.duty_date, OLD.flight_number, OLD.origin, OLD.destination,
      OLD.std_local, OLD.std_utc, OLD.sta_local, OLD.sta_utc,
      OLD.block_scheduled_mins, OLD.remark)
     OR (NEW.status IS DISTINCT FROM OLD.status
         AND NEW.status NOT IN ('completed','diverted')) THEN
    RAISE EXCEPTION 'This duty was set by your roster officer. Contact them to change it.'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger names matter: BEFORE triggers fire alphabetically, so
-- "…_officer_wins" runs before "…_track_change".
DROP TRIGGER IF EXISTS roster_duties_officer_wins ON roster_duties;
CREATE TRIGGER roster_duties_officer_wins
  BEFORE UPDATE ON roster_duties
  FOR EACH ROW EXECUTE FUNCTION roster_duties_officer_wins();

DROP TRIGGER IF EXISTS roster_duties_officer_wins_delete ON roster_duties;
CREATE TRIGGER roster_duties_officer_wins_delete
  BEFORE DELETE ON roster_duties
  FOR EACH ROW EXECUTE FUNCTION roster_duties_officer_wins();

-- ---------------------------------------------------------------------------
-- 2. Add a duty after publication
-- ---------------------------------------------------------------------------

-- INSERT trigger function (replaces the migration 17 version): a duty added
-- through roster_add_duty() is stamped as an 'added' change instead of as
-- part of the original publication.
CREATE OR REPLACE FUNCTION roster_duties_set_tenant_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant_id uuid;
  v_owner     uuid;
BEGIN
  v_tenant_id := guestora_resolve_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION
      'Cannot import roster duties: your account has no tenant assignment. '
      'Contact your administrator.';
  END IF;
  NEW.tenant_id := v_tenant_id;
  NEW.revision  := 0;

  IF current_setting('roster.change_type', true) = 'added' THEN
    SELECT r.crew_user_id INTO v_owner FROM crew_rosters r WHERE r.id = NEW.roster_id;
    NEW.published          := jsonb_build_object('added', true);
    NEW.status             := 'rostered';
    NEW.last_change_type   := 'added';
    NEW.last_change_reason := NULLIF(current_setting('roster.change_reason', true), '');
    NEW.last_change_source := CASE
      WHEN roster_is_officer() AND v_owner IS DISTINCT FROM auth.uid() THEN 'officer'
      ELSE 'crew' END;
    NEW.last_changed_at    := now();
    NEW.last_changed_by    := auth.uid();
    NEW.officer_locked     := (NEW.last_change_source = 'officer');
  ELSE
    NEW.officer_locked     := false;
    NEW.published          := roster_duty_snapshot(NEW);
    NEW.last_change_type   := NULL;
    NEW.last_change_reason := NULL;
    NEW.last_change_source := NULL;
    NEW.last_changed_at    := NULL;
    NEW.last_changed_by    := NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION roster_duties_log_added()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.last_change_type = 'added' THEN
    INSERT INTO roster_duty_changes
      (tenant_id, roster_id, duty_id, revision, change_type,
       old_values, new_values, reason, source, changed_by)
    VALUES
      (NEW.tenant_id, NEW.roster_id, NEW.id, 0, 'added',
       '{}'::jsonb, roster_duty_snapshot(NEW),
       NEW.last_change_reason, NEW.last_change_source, NEW.last_changed_by);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS roster_duties_log_added ON roster_duties;
CREATE TRIGGER roster_duties_log_added
  AFTER INSERT ON roster_duties
  FOR EACH ROW EXECUTE FUNCTION roster_duties_log_added();

CREATE OR REPLACE FUNCTION roster_add_duty(
  p_roster_id uuid,
  p_duty      jsonb,
  p_reason    text DEFAULT NULL
)
RETURNS roster_duties
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  c_allowed constant text[] := ARRAY[
    'duty_date','duty_type','flight_number','origin','destination',
    'std_local','sta_local','block_scheduled_mins','remark'];
  v_bad text;
  v_row roster_duties;
BEGIN
  IF p_duty IS NULL OR jsonb_typeof(p_duty) <> 'object' THEN
    RAISE EXCEPTION 'No duty supplied.';
  END IF;
  SELECT string_agg(k, ', ') INTO v_bad
    FROM jsonb_object_keys(p_duty) AS k
   WHERE k <> ALL (c_allowed);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'These fields cannot be set here: %', v_bad;
  END IF;
  IF NULLIF(p_duty->>'duty_date', '') IS NULL OR NULLIF(p_duty->>'duty_type', '') IS NULL THEN
    RAISE EXCEPTION 'A duty needs a date and a duty type.';
  END IF;

  PERFORM set_config('roster.change_type',   'added', true);
  PERFORM set_config('roster.change_reason', COALESCE(btrim(p_reason), ''), true);

  INSERT INTO roster_duties
    (roster_id, duty_date, duty_type, flight_number, origin, destination,
     std_local, sta_local, block_scheduled_mins, remark)
  VALUES
    (p_roster_id,
     (p_duty->>'duty_date')::date,
     p_duty->>'duty_type',
     p_duty->>'flight_number',
     p_duty->>'origin',
     p_duty->>'destination',
     p_duty->>'std_local',
     p_duty->>'sta_local',
     (p_duty->>'block_scheduled_mins')::int,
     p_duty->>'remark')
  RETURNING * INTO v_row;

  PERFORM set_config('roster.change_type',   '', true);
  PERFORM set_config('roster.change_reason', '', true);

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION roster_add_duty(uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_add_duty(uuid, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_trg int;
BEGIN
  SELECT count(*) INTO v_trg FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
   WHERE c.relname = 'roster_duties' AND NOT t.tgisinternal
     AND t.tgname IN ('roster_duties_officer_wins','roster_duties_officer_wins_delete',
                      'roster_duties_log_added','roster_duties_track_change',
                      'roster_duties_auto_tenant');
  IF v_trg <> 5 THEN
    RAISE EXCEPTION 'Migration 18: expected 5 roster_duties triggers, found %', v_trg;
  END IF;
  RAISE NOTICE 'Migration 18 verified: officer-wins rule and roster_add_duty() in place.';
END;
$$;
