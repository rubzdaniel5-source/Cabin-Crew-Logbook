-- =============================================================================
-- Migration: 20241101000017_roster_ownership_and_change_history.sql
-- Description: Roster foundation — ownership, roster officer role,
--              change history, and tightened access rules
--
-- Before this migration:
--   • crew_rosters recorded who UPLOADED a roster, not whose roster it is.
--   • RLS was tenant-wide: every user in a tenant could read, edit and
--     delete every other crew member's roster.
--   • A duty change overwrote the row; the published roster was lost.
--
-- After this migration:
--   1. profiles.crew_code            – the crew code printed on the roster PDF
--   2. crew_rosters.crew_user_id     – the crew member the roster belongs to
--      crew_rosters.source           – 'crew' (self-upload) | 'officer'
--   3. Role 'roster_officer'         – sees and edits every roster in the tenant
--   4. roster_duties.published       – immutable snapshot of the duty as issued
--      roster_duty_changes           – one row per change (old/new/reason/who)
--   5. roster_apply_change()         – RPC used by the app to make a change
--   6. RLS: crew see only their own roster; officers/admins see the tenant
--   7. profiles guard: only an admin can change role / is_admin / blocked
--
-- Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Pre-flight: the columns this migration relies on must exist
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_missing text;
BEGIN
  SELECT string_agg(c, ', ') INTO v_missing
  FROM unnest(ARRAY['role','is_admin','blocked','tenant_id','user_class']) AS c
  WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = c
  );
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'Migration 17: profiles is missing column(s): %', v_missing;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. profiles.crew_code
-- ---------------------------------------------------------------------------
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS crew_code text;

COMMENT ON COLUMN profiles.crew_code IS
  'Crew code as printed on the airline roster (e.g. ARMS crew code). '
  'Used to match officer-uploaded rosters to a crew member. '
  'Unique per airline tenant.';

-- ---------------------------------------------------------------------------
-- 2. Role helper
--    Officer powers apply only inside an airline tenant — never across the
--    shared "independent" pseudo-tenant.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_is_officer()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE((
    SELECT (p.is_admin IS TRUE OR p.role IN ('roster_officer', 'admin'))
           AND p.user_class = 'airline'
           AND p.blocked IS NOT TRUE
      FROM profiles p
     WHERE p.id = auth.uid()
  ), false);
$$;

REVOKE ALL ON FUNCTION roster_is_officer() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_is_officer() TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. crew_rosters: owner + source
-- ---------------------------------------------------------------------------
ALTER TABLE crew_rosters
  ADD COLUMN IF NOT EXISTS crew_user_id uuid REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'crew';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'crew_rosters_source_check') THEN
    ALTER TABLE crew_rosters
      ADD CONSTRAINT crew_rosters_source_check CHECK (source IN ('crew', 'officer'));
  END IF;
END;
$$;

COMMENT ON COLUMN crew_rosters.crew_user_id IS
  'The crew member this roster belongs to. NULL = uploaded by an officer for a '
  'crew code that has no account yet.';
COMMENT ON COLUMN crew_rosters.source IS
  '''crew'' = uploaded by the crew member themselves; ''officer'' = published by a roster officer.';

-- Every roster so far was self-uploaded, so the uploader is the owner.
UPDATE crew_rosters
   SET crew_user_id = uploaded_by
 WHERE crew_user_id IS NULL
   AND uploaded_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS crew_rosters_owner_period
  ON crew_rosters (crew_user_id, period_from DESC);

-- Backfill profiles.crew_code from existing rosters, only where unambiguous:
-- the user has exactly one code, and no other user in the tenant has that code.
WITH per_user AS (
  SELECT r.crew_user_id AS user_id, r.tenant_id,
         min(upper(btrim(r.crew_code))) AS code
    FROM crew_rosters r
   WHERE r.crew_user_id IS NOT NULL
     AND NULLIF(btrim(r.crew_code), '') IS NOT NULL
   GROUP BY r.crew_user_id, r.tenant_id
  HAVING count(DISTINCT upper(btrim(r.crew_code))) = 1
), unique_codes AS (
  SELECT tenant_id, code
    FROM per_user
   GROUP BY tenant_id, code
  HAVING count(*) = 1
)
UPDATE profiles p
   SET crew_code = u.code
  FROM per_user u
  JOIN unique_codes c ON c.tenant_id = u.tenant_id AND c.code = u.code
 WHERE p.id = u.user_id
   AND p.tenant_id = u.tenant_id
   AND p.user_class = 'airline'
   AND p.crew_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS profiles_tenant_crew_code_uniq
  ON profiles (tenant_id, upper(crew_code))
  WHERE crew_code IS NOT NULL AND user_class = 'airline';

-- ---------------------------------------------------------------------------
-- 4. Access helpers (used by the RLS policies below)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_can_access(p_roster_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT EXISTS (
    SELECT 1 FROM crew_rosters r
     WHERE r.id = p_roster_id
       AND r.tenant_id = guestora_resolve_tenant_id()
       AND (r.crew_user_id = auth.uid() OR roster_is_officer())
  );
$$;

-- Deleting is narrower than editing: crew may delete only a roster they
-- uploaded themselves. An officer-published roster can only be deleted by
-- an officer.
CREATE OR REPLACE FUNCTION roster_can_delete(p_roster_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT EXISTS (
    SELECT 1 FROM crew_rosters r
     WHERE r.id = p_roster_id
       AND r.tenant_id = guestora_resolve_tenant_id()
       AND (roster_is_officer()
            OR (r.crew_user_id = auth.uid() AND r.source = 'crew'))
  );
$$;

REVOKE ALL ON FUNCTION roster_can_access(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION roster_can_delete(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_can_access(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION roster_can_delete(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. crew_rosters INSERT trigger — now also sets the owner
--    (replaces the migration 15 function; the trigger itself is unchanged)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_rosters_set_tenant_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant_id uuid;
  v_code      text;
BEGIN
  v_tenant_id := guestora_resolve_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION
      'Cannot import roster: your account has no tenant assignment. '
      'Contact your administrator.';
  END IF;

  NEW.tenant_id   := v_tenant_id;
  NEW.uploaded_by := auth.uid();

  IF roster_is_officer() AND NEW.source = 'officer' THEN
    -- Officer publishing for someone else. Owner may be NULL (no account yet).
    IF NEW.crew_user_id IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM profiles p
          WHERE p.id = NEW.crew_user_id AND p.tenant_id = v_tenant_id
       ) THEN
      RAISE EXCEPTION 'Cannot publish roster: that crew member is not in your airline.';
    END IF;
  ELSE
    -- Self-upload: the uploader is always the owner.
    NEW.source       := 'crew';
    NEW.crew_user_id := auth.uid();

    -- First self-upload claims the crew code for the profile, if it is free.
    v_code := NULLIF(upper(btrim(NEW.crew_code)), '');
    IF v_code IS NOT NULL THEN
      UPDATE profiles p
         SET crew_code = v_code
       WHERE p.id = auth.uid()
         AND p.crew_code IS NULL
         AND p.user_class = 'airline'
         AND NOT EXISTS (
               SELECT 1 FROM profiles o
                WHERE o.tenant_id = p.tenant_id
                  AND o.user_class = 'airline'
                  AND upper(o.crew_code) = v_code
             );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Crew may not hand a roster to someone else or relabel its source.
CREATE OR REPLACE FUNCTION crew_rosters_guard_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;   -- SQL editor / service role
  NEW.tenant_id := OLD.tenant_id;
  IF NOT roster_is_officer() THEN
    NEW.crew_user_id := OLD.crew_user_id;
    NEW.source       := OLD.source;
    NEW.uploaded_by  := OLD.uploaded_by;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS crew_rosters_guard_update ON crew_rosters;
CREATE TRIGGER crew_rosters_guard_update
  BEFORE UPDATE ON crew_rosters
  FOR EACH ROW EXECUTE FUNCTION crew_rosters_guard_update();

-- ---------------------------------------------------------------------------
-- 6. roster_duties: published snapshot + change metadata + wider statuses
-- ---------------------------------------------------------------------------
ALTER TABLE roster_duties
  ADD COLUMN IF NOT EXISTS published          jsonb,
  ADD COLUMN IF NOT EXISTS revision           int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_change_type   text,
  ADD COLUMN IF NOT EXISTS last_change_reason text,
  ADD COLUMN IF NOT EXISTS last_change_source text,
  ADD COLUMN IF NOT EXISTS last_changed_at    timestamptz,
  ADD COLUMN IF NOT EXISTS last_changed_by    uuid REFERENCES profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN roster_duties.published IS
  'The duty exactly as first published. Never changes. Compare with the live '
  'columns to see how the duty differs from the original roster.';
COMMENT ON COLUMN roster_duties.revision IS
  'Number of changes applied since publication (0 = as published).';

-- Lifecycle statuses.
--   rostered  – planned, as it currently stands
--   delayed   – flight delayed (new times on the row)
--   cancelled – the flight itself was cancelled
--   removed   – the flight operates, but this crew member was taken off it
--   completed / diverted – flown (set by Mark Complete)
--   no_show   – crew member did not report
--   standby   – legacy value, kept for compatibility
ALTER TABLE roster_duties DROP CONSTRAINT IF EXISTS roster_duties_status_check;
ALTER TABLE roster_duties ADD CONSTRAINT roster_duties_status_check CHECK (
  status IN ('rostered','delayed','cancelled','removed',
             'completed','diverted','no_show','standby')
);

CREATE OR REPLACE FUNCTION roster_duty_snapshot(d roster_duties)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'duty_type',            d.duty_type,
    'duty_date',            d.duty_date,
    'flight_number',        d.flight_number,
    'origin',               d.origin,
    'destination',          d.destination,
    'std_local',            d.std_local,
    'std_utc',              d.std_utc,
    'sta_local',            d.sta_local,
    'sta_utc',              d.sta_utc,
    'block_scheduled_mins', d.block_scheduled_mins,
    'remark',               d.remark
  );
$$;

-- Existing duties have never been changed, so their current values are the
-- published values. (Runs before the change-tracking trigger exists.)
UPDATE roster_duties d
   SET published = roster_duty_snapshot(d)
 WHERE d.published IS NULL;

-- INSERT trigger — now also stamps the published snapshot
-- (replaces the migration 15 function; the trigger itself is unchanged)
CREATE OR REPLACE FUNCTION roster_duties_set_tenant_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  v_tenant_id := guestora_resolve_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION
      'Cannot import roster duties: your account has no tenant assignment. '
      'Contact your administrator.';
  END IF;
  NEW.tenant_id          := v_tenant_id;
  NEW.published          := roster_duty_snapshot(NEW);
  NEW.revision           := 0;
  NEW.last_change_type   := NULL;
  NEW.last_change_reason := NULL;
  NEW.last_change_source := NULL;
  NEW.last_changed_at    := NULL;
  NEW.last_changed_by    := NULL;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. roster_duty_changes — the change history
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roster_duty_changes (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,
  roster_id       uuid        NOT NULL REFERENCES crew_rosters(id)  ON DELETE CASCADE,
  duty_id         uuid        NOT NULL REFERENCES roster_duties(id) ON DELETE CASCADE,
  revision        int         NOT NULL,
  change_type     text        NOT NULL,
  old_values      jsonb       NOT NULL,   -- only the fields that changed
  new_values      jsonb       NOT NULL,
  reason          text,
  source          text        NOT NULL,   -- crew | officer | system
  changed_by      uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  changed_at      timestamptz NOT NULL DEFAULT now(),
  acknowledged_at timestamptz,            -- crew has seen an officer's change
  CONSTRAINT roster_duty_changes_source_check
    CHECK (source IN ('crew','officer','system')),
  CONSTRAINT roster_duty_changes_type_check CHECK (change_type IN (
    'activated',      -- standby called out to a flight
    'assigned',       -- DMA / other duty became a flight
    'stood_down',     -- flight became standby / DMA / other duty
    'type_changed',   -- any other duty-type change (sick, leave, training…)
    'delayed',        -- later times, same date
    'retimed',        -- times changed (incl. earlier)
    'postponed',      -- moved to another date
    'cancelled',      -- flight cancelled
    'removed',        -- crew member taken off a flight that still operates
    'reinstated',     -- cancelled / removed duty put back
    'flight_changed', -- flight number or route changed
    'swapped',        -- exchanged with another crew member
    'no_show',
    'completed',
    'diverted',
    'reopened',       -- completed duty reopened for correction
    'added',          -- duty added after publication
    'edited'          -- anything else
  ))
);

COMMENT ON TABLE roster_duty_changes IS
  'Append-only history of every change to a roster duty. Written only by the '
  'roster_duties change-tracking trigger — never directly by the client.';

CREATE INDEX IF NOT EXISTS roster_duty_changes_duty
  ON roster_duty_changes (duty_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS roster_duty_changes_roster
  ON roster_duty_changes (roster_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS roster_duty_changes_unack
  ON roster_duty_changes (roster_id)
  WHERE acknowledged_at IS NULL AND source = 'officer';

-- ---------------------------------------------------------------------------
-- 8. Change-tracking trigger on roster_duties
--    Every UPDATE that alters a tracked field is logged, whoever makes it and
--    however it is made. The client cannot forge or skip the history.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_duties_track_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  c_schedule constant text[] := ARRAY[
    'duty_type','duty_date','flight_number','origin','destination',
    'std_local','std_utc','sta_local','sta_utc','block_scheduled_mins'];
  c_other constant text[] := ARRAY[
    'status','remark','block_actual_mins','atd_local','ata_local',
    'divert_airport','completion_note'];
  v_old      jsonb := to_jsonb(OLD);
  v_new      jsonb := to_jsonb(NEW);
  v_old_diff jsonb := '{}'::jsonb;
  v_new_diff jsonb := '{}'::jsonb;
  v_sched    boolean := false;
  v_key      text;
  v_type     text;
  v_reason   text;
  v_source   text;
  v_owner    uuid;
BEGIN
  -- Fields the client may never rewrite
  NEW.tenant_id  := OLD.tenant_id;
  NEW.published  := OLD.published;
  NEW.created_at := OLD.created_at;

  FOREACH v_key IN ARRAY c_schedule || c_other LOOP
    IF (v_old -> v_key) IS DISTINCT FROM (v_new -> v_key) THEN
      v_old_diff := v_old_diff || jsonb_build_object(v_key, v_old -> v_key);
      v_new_diff := v_new_diff || jsonb_build_object(v_key, v_new -> v_key);
      IF v_key = ANY (c_schedule) THEN v_sched := true; END IF;
    END IF;
  END LOOP;

  -- Nothing tracked changed: keep the change metadata exactly as it was.
  IF v_new_diff = '{}'::jsonb THEN
    NEW.revision           := OLD.revision;
    NEW.last_change_type   := OLD.last_change_type;
    NEW.last_change_reason := OLD.last_change_reason;
    NEW.last_change_source := OLD.last_change_source;
    NEW.last_changed_at    := OLD.last_changed_at;
    NEW.last_changed_by    := OLD.last_changed_by;
    RETURN NEW;
  END IF;

  -- Change type: supplied by roster_apply_change(), otherwise inferred.
  v_type   := NULLIF(current_setting('roster.change_type',   true), '');
  v_reason := NULLIF(current_setting('roster.change_reason', true), '');

  IF v_type IS NULL THEN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      v_type := CASE
        WHEN NEW.status IN ('completed','diverted','cancelled','removed',
                            'delayed','no_show')            THEN NEW.status
        WHEN OLD.status IN ('completed','diverted')         THEN 'reopened'
        WHEN OLD.status IN ('cancelled','removed','no_show') THEN 'reinstated'
        ELSE 'edited' END;
    ELSIF NEW.duty_type IS DISTINCT FROM OLD.duty_type THEN
      v_type := CASE
        WHEN upper(NEW.duty_type) LIKE 'OP%' AND upper(OLD.duty_type) = 'SBY' THEN 'activated'
        WHEN upper(NEW.duty_type) LIKE 'OP%'                                  THEN 'assigned'
        WHEN upper(OLD.duty_type) LIKE 'OP%'                                  THEN 'stood_down'
        ELSE 'type_changed' END;
    ELSIF NEW.duty_date IS DISTINCT FROM OLD.duty_date THEN
      v_type := 'postponed';
    ELSIF (v_new_diff ?| ARRAY['std_local','std_utc','sta_local','sta_utc']) THEN
      v_type := 'retimed';
    ELSIF (v_new_diff ?| ARRAY['flight_number','origin','destination']) THEN
      v_type := 'flight_changed';
    ELSE
      v_type := 'edited';
    END IF;
  END IF;

  -- A flown duty is locked. Its completion details can be corrected, but the
  -- schedule and status cannot change unless it is explicitly reopened.
  IF OLD.status IN ('completed','diverted') AND v_type <> 'reopened' THEN
    IF v_sched OR NEW.status NOT IN ('completed','diverted') THEN
      RAISE EXCEPTION
        'This duty is already marked as flown. Reopen it before changing it.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF v_type = 'reopened' AND NEW.status IN ('completed','diverted') THEN
    RAISE EXCEPTION 'A reopened duty cannot stay marked as flown.';
  END IF;

  -- Who made the change
  SELECT r.crew_user_id INTO v_owner FROM crew_rosters r WHERE r.id = OLD.roster_id;
  v_source := CASE
    WHEN auth.uid() IS NULL                                  THEN 'system'
    WHEN roster_is_officer() AND v_owner IS DISTINCT FROM auth.uid() THEN 'officer'
    ELSE 'crew' END;

  NEW.revision           := OLD.revision + 1;
  NEW.last_change_type   := v_type;
  NEW.last_change_reason := v_reason;
  NEW.last_change_source := v_source;
  NEW.last_changed_at    := now();
  NEW.last_changed_by    := auth.uid();

  INSERT INTO roster_duty_changes
    (tenant_id, roster_id, duty_id, revision, change_type,
     old_values, new_values, reason, source, changed_by)
  VALUES
    (OLD.tenant_id, OLD.roster_id, OLD.id, NEW.revision, v_type,
     v_old_diff, v_new_diff, v_reason, v_source, auth.uid());

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS roster_duties_track_change ON roster_duties;
CREATE TRIGGER roster_duties_track_change
  BEFORE UPDATE ON roster_duties
  FOR EACH ROW EXECUTE FUNCTION roster_duties_track_change();

-- ---------------------------------------------------------------------------
-- 9. roster_apply_change() — how the app makes a roster change
--    Runs with the caller's own permissions (RLS decides whether they may
--    touch the duty). Only schedule fields, remark and status can be set.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_apply_change(
  p_duty_id     uuid,
  p_change_type text,
  p_changes     jsonb,
  p_reason      text DEFAULT NULL
)
RETURNS roster_duties
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  c_allowed constant text[] := ARRAY[
    'duty_type','duty_date','flight_number','origin','destination',
    'std_local','std_utc','sta_local','sta_utc','block_scheduled_mins',
    'remark','status'];
  v_bad text;
  v_row roster_duties;
BEGIN
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION 'No changes supplied.';
  END IF;

  SELECT string_agg(k, ', ') INTO v_bad
    FROM jsonb_object_keys(p_changes) AS k
   WHERE k <> ALL (c_allowed);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'These fields cannot be changed here: %', v_bad;
  END IF;

  IF p_change_type IN ('completed','diverted') THEN
    RAISE EXCEPTION 'Use Mark Complete to record a flown duty.';
  END IF;

  PERFORM set_config('roster.change_type',   COALESCE(p_change_type, ''), true);
  PERFORM set_config('roster.change_reason', COALESCE(btrim(p_reason), ''), true);

  UPDATE roster_duties d SET
    duty_type     = CASE WHEN p_changes ? 'duty_type'     THEN p_changes->>'duty_type'          ELSE d.duty_type     END,
    duty_date     = CASE WHEN p_changes ? 'duty_date'     THEN (p_changes->>'duty_date')::date  ELSE d.duty_date     END,
    flight_number = CASE WHEN p_changes ? 'flight_number' THEN p_changes->>'flight_number'      ELSE d.flight_number END,
    origin        = CASE WHEN p_changes ? 'origin'        THEN p_changes->>'origin'             ELSE d.origin        END,
    destination   = CASE WHEN p_changes ? 'destination'   THEN p_changes->>'destination'        ELSE d.destination   END,
    std_local     = CASE WHEN p_changes ? 'std_local'     THEN p_changes->>'std_local'          ELSE d.std_local     END,
    std_utc       = CASE WHEN p_changes ? 'std_utc'       THEN p_changes->>'std_utc'            ELSE d.std_utc       END,
    sta_local     = CASE WHEN p_changes ? 'sta_local'     THEN p_changes->>'sta_local'          ELSE d.sta_local     END,
    sta_utc       = CASE WHEN p_changes ? 'sta_utc'       THEN p_changes->>'sta_utc'            ELSE d.sta_utc       END,
    block_scheduled_mins = CASE WHEN p_changes ? 'block_scheduled_mins'
                                THEN (p_changes->>'block_scheduled_mins')::int
                                ELSE d.block_scheduled_mins END,
    remark        = CASE WHEN p_changes ? 'remark'        THEN p_changes->>'remark'             ELSE d.remark        END,
    status        = CASE WHEN p_changes ? 'status'        THEN p_changes->>'status'             ELSE d.status        END
  WHERE d.id = p_duty_id
  RETURNING d.* INTO v_row;

  -- Clear so a later statement in the same transaction is not mislabelled
  PERFORM set_config('roster.change_type',   '', true);
  PERFORM set_config('roster.change_reason', '', true);

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Duty not found, or you are not allowed to change it.'
      USING ERRCODE = '42501';
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION roster_apply_change(uuid, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_apply_change(uuid, text, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 10. RLS — crew see their own roster; officers/admins see the tenant
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS crew_rosters_select ON crew_rosters;
DROP POLICY IF EXISTS crew_rosters_insert ON crew_rosters;
DROP POLICY IF EXISTS crew_rosters_update ON crew_rosters;
DROP POLICY IF EXISTS crew_rosters_delete ON crew_rosters;

CREATE POLICY crew_rosters_select ON crew_rosters
  FOR SELECT TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id()
         AND (crew_user_id = auth.uid() OR roster_is_officer()));

CREATE POLICY crew_rosters_insert ON crew_rosters
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = guestora_resolve_tenant_id()
              AND (crew_user_id = auth.uid() OR roster_is_officer()));

CREATE POLICY crew_rosters_update ON crew_rosters
  FOR UPDATE TO authenticated
  USING      (tenant_id = guestora_resolve_tenant_id()
              AND (crew_user_id = auth.uid() OR roster_is_officer()))
  WITH CHECK (tenant_id = guestora_resolve_tenant_id()
              AND (crew_user_id = auth.uid() OR roster_is_officer()));

CREATE POLICY crew_rosters_delete ON crew_rosters
  FOR DELETE TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id()
         AND (roster_is_officer()
              OR (crew_user_id = auth.uid() AND source = 'crew')));

DROP POLICY IF EXISTS roster_duties_select ON roster_duties;
DROP POLICY IF EXISTS roster_duties_insert ON roster_duties;
DROP POLICY IF EXISTS roster_duties_update ON roster_duties;
DROP POLICY IF EXISTS roster_duties_delete ON roster_duties;

CREATE POLICY roster_duties_select ON roster_duties
  FOR SELECT TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id() AND roster_can_access(roster_id));

CREATE POLICY roster_duties_insert ON roster_duties
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = guestora_resolve_tenant_id() AND roster_can_access(roster_id));

CREATE POLICY roster_duties_update ON roster_duties
  FOR UPDATE TO authenticated
  USING      (tenant_id = guestora_resolve_tenant_id() AND roster_can_access(roster_id))
  WITH CHECK (tenant_id = guestora_resolve_tenant_id() AND roster_can_access(roster_id));

CREATE POLICY roster_duties_delete ON roster_duties
  FOR DELETE TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id() AND roster_can_delete(roster_id));

-- History: readable by whoever can see the roster. No write policies —
-- only the SECURITY DEFINER trigger writes here.
ALTER TABLE roster_duty_changes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS roster_duty_changes_select ON roster_duty_changes;
CREATE POLICY roster_duty_changes_select ON roster_duty_changes
  FOR SELECT TO authenticated
  USING (tenant_id = guestora_resolve_tenant_id() AND roster_can_access(roster_id));

-- ---------------------------------------------------------------------------
-- 11. profiles guard — the access rules above depend on role / is_admin,
--     so a user must not be able to grant those to themselves.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION profiles_guard_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_admin boolean;
BEGIN
  NEW.crew_code := NULLIF(upper(btrim(NEW.crew_code)), '');

  -- SQL editor, migrations and the service role have no auth.uid()
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;

  SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
    INTO v_admin
    FROM profiles p WHERE p.id = auth.uid();
  IF COALESCE(v_admin, false) THEN RETURN NEW; END IF;

  IF NEW.is_admin IS DISTINCT FROM OLD.is_admin
     OR NEW.role    IS DISTINCT FROM OLD.role
     OR NEW.blocked IS DISTINCT FROM OLD.blocked THEN
    RAISE EXCEPTION 'Only an administrator can change a role, admin or blocked status.'
      USING ERRCODE = '42501';
  END IF;

  -- Crew code: a user may set their own once; after that only an officer
  -- or admin can change it.
  IF NEW.crew_code IS DISTINCT FROM OLD.crew_code
     AND NOT roster_is_officer()
     AND NOT (OLD.id = auth.uid() AND OLD.crew_code IS NULL) THEN
    RAISE EXCEPTION 'Your crew code is already set. Ask a roster officer to change it.'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_guard_privileged_columns ON profiles;
CREATE TRIGGER profiles_guard_privileged_columns
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION profiles_guard_privileged_columns();

-- ---------------------------------------------------------------------------
-- 12. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_orphans  int;
  v_rosters  int;
  v_nosnap   int;
  v_codes    int;
  v_policies int;
BEGIN
  SELECT count(*) INTO v_rosters FROM crew_rosters;
  SELECT count(*) INTO v_orphans FROM crew_rosters WHERE crew_user_id IS NULL;
  SELECT count(*) INTO v_nosnap  FROM roster_duties WHERE published IS NULL;
  SELECT count(*) INTO v_codes   FROM profiles WHERE crew_code IS NOT NULL;
  SELECT count(*) INTO v_policies FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('crew_rosters','roster_duties','roster_duty_changes');

  IF v_nosnap > 0 THEN
    RAISE EXCEPTION 'Migration 17: % duties have no published snapshot', v_nosnap;
  END IF;
  IF v_policies <> 9 THEN
    RAISE EXCEPTION 'Migration 17: expected 9 roster policies, found %: %', v_policies,
      (SELECT string_agg(tablename || '.' || policyname, ', ') FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename IN ('crew_rosters','roster_duties','roster_duty_changes'));
  END IF;

  RAISE NOTICE
    'Migration 17 verified: % roster(s), % without an owner, % profile(s) with a crew code, % policies.',
    v_rosters, v_orphans, v_codes, v_policies;
END;
$$;
