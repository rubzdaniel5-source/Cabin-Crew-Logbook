-- =============================================================================
-- Migration: 20241101000020_roster_bulk_and_revisions.sql
-- Description: Bulk roster upload support for roster officers
--
-- Requires migrations 17, 18 and 19.
--
--   roster_publish()            – save one roster (header + all duties) as a
--                                 single all-or-nothing transaction
--   roster_apply_revision()     – apply a re-uploaded roster to an existing one:
--                                 the differences are recorded as tracked
--                                 changes; flown duties are never touched
--   roster_assign_owner()       – give an unassigned roster to a crew member
--   profiles trigger            – when an officer sets a crew code, rosters that
--                                 were uploaded for that code and are still
--                                 unassigned attach to that crew member
--   crew_rosters.revision / revised_at
--
-- Unassigned rosters (crew_user_id IS NULL) are visible only to officers.
-- A crew member who types their own code does NOT receive them: an officer
-- must confirm the match, so nobody can read a colleague's roster by
-- guessing a code.
--
-- Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('roster_is_officer()') IS NULL
     OR to_regprocedure('roster_add_duty(uuid,jsonb,text)') IS NULL
     OR to_regprocedure('roster_set_crew_code(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 20 requires migrations 17, 18 and 19.';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Revision bookkeeping on the roster header
-- ---------------------------------------------------------------------------
ALTER TABLE crew_rosters
  ADD COLUMN IF NOT EXISTS revision   int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS revised_at timestamptz;

COMMENT ON COLUMN crew_rosters.revision IS
  'Number of times a revised roster PDF has been applied on top of this roster.';

-- ---------------------------------------------------------------------------
-- 2. Attach unassigned rosters when an OFFICER sets a crew code
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION profiles_attach_pending_rosters()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.crew_code IS NULL OR NEW.crew_code IS NOT DISTINCT FROM OLD.crew_code THEN
    RETURN NULL;
  END IF;
  IF NEW.user_class IS DISTINCT FROM 'airline' OR NEW.tenant_id IS NULL THEN
    RETURN NULL;
  END IF;
  -- A crew member setting their own code does not claim waiting rosters.
  -- (SQL editor / service role have no auth.uid() and are trusted.)
  IF auth.uid() IS NOT NULL AND NOT roster_is_officer() THEN
    RETURN NULL;
  END IF;

  UPDATE crew_rosters r
     SET crew_user_id = NEW.id
   WHERE r.tenant_id = NEW.tenant_id
     AND r.crew_user_id IS NULL
     AND upper(btrim(r.crew_code)) = upper(btrim(NEW.crew_code));
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS profiles_attach_pending_rosters ON profiles;
CREATE TRIGGER profiles_attach_pending_rosters
  AFTER UPDATE OF crew_code ON profiles
  FOR EACH ROW EXECUTE FUNCTION profiles_attach_pending_rosters();

-- ---------------------------------------------------------------------------
-- 3. roster_assign_owner — give an unassigned (or wrongly assigned) roster
--    to a crew member
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_assign_owner(p_roster_id uuid, p_user_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_roster crew_rosters;
  v_code   text;
  v_set    text := NULL;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers can assign a roster.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_roster FROM crew_rosters WHERE id = p_roster_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Roster not found.' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles p
                  WHERE p.id = p_user_id AND p.tenant_id = v_tenant
                    AND p.user_class = 'airline' AND p.blocked IS NOT TRUE) THEN
    RAISE EXCEPTION 'That crew member is not in your airline.' USING ERRCODE = '42501';
  END IF;

  UPDATE crew_rosters SET crew_user_id = p_user_id WHERE id = p_roster_id;

  -- Remember the roster's crew code on the profile when that is unambiguous.
  -- This also attaches any other waiting rosters for the same code.
  v_code := NULLIF(upper(btrim(v_roster.crew_code)), '');
  IF v_code IS NOT NULL
     AND EXISTS (SELECT 1 FROM profiles p WHERE p.id = p_user_id AND p.crew_code IS NULL)
     AND NOT EXISTS (SELECT 1 FROM profiles o
                      WHERE o.tenant_id = v_tenant AND o.user_class = 'airline'
                        AND upper(o.crew_code) = v_code) THEN
    UPDATE profiles SET crew_code = v_code WHERE id = p_user_id;
    v_set := v_code;
  END IF;

  RETURN v_set;
END;
$$;

REVOKE ALL ON FUNCTION roster_assign_owner(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_assign_owner(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. roster_publish — one roster, all or nothing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_publish(
  p_meta          jsonb,
  p_duties        jsonb,
  p_crew_user_id  uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_id uuid;
  v_n  int;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers can publish a roster for someone else.' USING ERRCODE = '42501';
  END IF;
  IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
    RAISE EXCEPTION 'No roster details supplied.';
  END IF;
  IF p_duties IS NULL OR jsonb_typeof(p_duties) <> 'array' THEN
    RAISE EXCEPTION 'No duties supplied.';
  END IF;
  v_n := jsonb_array_length(p_duties);
  IF v_n = 0 OR v_n > 400 THEN
    RAISE EXCEPTION 'A roster must have between 1 and 400 duties (got %).', v_n;
  END IF;
  IF NULLIF(p_meta->>'period_from', '') IS NULL OR NULLIF(p_meta->>'period_to', '') IS NULL THEN
    RAISE EXCEPTION 'The roster period could not be read from the PDF.';
  END IF;

  INSERT INTO crew_rosters
    (crew_name, crew_code, crew_rank, base, period_from, period_to,
     total_est_block_mins, source_filename, raw_text, source, crew_user_id)
  VALUES
    (p_meta->>'crew_name', p_meta->>'crew_code', p_meta->>'crew_rank', p_meta->>'base',
     (p_meta->>'period_from')::date, (p_meta->>'period_to')::date,
     NULLIF(p_meta->>'total_est_block_mins', '')::int,
     p_meta->>'source_filename', p_meta->>'raw_text',
     'officer', p_crew_user_id)
  RETURNING id INTO v_id;

  INSERT INTO roster_duties
    (roster_id, s_no, duty_date, duty_type, flight_number, origin, destination,
     std_local, std_utc, sta_local, sta_utc, block_scheduled_mins, remark, status)
  SELECT v_id, x.s_no, x.duty_date, x.duty_type, NULLIF(btrim(x.flight_number), ''),
         NULLIF(btrim(x.origin), ''), NULLIF(btrim(x.destination), ''),
         NULLIF(btrim(x.std_local), ''), NULLIF(btrim(x.std_utc), ''),
         NULLIF(btrim(x.sta_local), ''), NULLIF(btrim(x.sta_utc), ''),
         x.block_scheduled_mins, NULLIF(btrim(x.remark), ''), 'rostered'
    FROM jsonb_to_recordset(p_duties) AS x(
      s_no int, duty_date date, duty_type text, flight_number text,
      origin text, destination text, std_local text, std_utc text,
      sta_local text, sta_utc text, block_scheduled_mins int, remark text);

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION roster_publish(jsonb, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_publish(jsonb, jsonb, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. roster_apply_revision — apply a re-uploaded roster to an existing one
--
--    Duties are paired up, in this order:
--      1. same date + same duty + same flight           (unchanged / edited)
--      2. same flight number on a different date        (flight moved)
--      3. same date, different content, by position     (e.g. standby -> flight)
--    Unpaired new duties are added; unpaired old duties are marked removed.
--    A duty that has already been flown is never modified.
--    Every change is logged in roster_duty_changes as an officer change.
--    The whole revision is one transaction: it applies completely or not at all.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_apply_revision(
  p_roster_id uuid,
  p_duties    jsonb,
  p_meta      jsonb DEFAULT '{}'::jsonb,
  p_reason    text  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  r            record;
  o            roster_duties;
  j            jsonb;
  v_n          int;
  v_reason     text := COALESCE(NULLIF(btrim(p_reason), ''), 'Roster revised');
  v_changed    int := 0;
  v_added      int := 0;
  v_removed    int := 0;
  v_unchanged  int := 0;
  v_flown      int := 0;
  n_type       text; n_date date; n_flt text; n_org text; n_dst text;
  n_std text; n_stdu text; n_sta text; n_stau text; n_blk int; n_rem text;
  v_type       text;
  v_status     text;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers can revise a roster.' USING ERRCODE = '42501';
  END IF;
  IF p_duties IS NULL OR jsonb_typeof(p_duties) <> 'array' THEN
    RAISE EXCEPTION 'No duties supplied.';
  END IF;
  v_n := jsonb_array_length(p_duties);
  IF v_n = 0 OR v_n > 400 THEN
    RAISE EXCEPTION 'A roster must have between 1 and 400 duties (got %).', v_n;
  END IF;

  -- RLS decides whether the caller can see (and so revise) this roster
  PERFORM 1 FROM crew_rosters WHERE id = p_roster_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Roster not found, or you are not allowed to change it.' USING ERRCODE = '42501';
  END IF;
  PERFORM 1 FROM roster_duties WHERE roster_id = p_roster_id FOR UPDATE;

  FOR r IN
    WITH nrows AS (
      SELECT x.ord::int AS nord,
             (x.e->>'duty_date')::date                  AS d,
             upper(btrim(x.e->>'duty_type'))            AS t,
             NULLIF(btrim(x.e->>'flight_number'), '')   AS f
        FROM jsonb_array_elements(p_duties) WITH ORDINALITY AS x(e, ord)
    ), nk AS (
      SELECT n.*, row_number() OVER (PARTITION BY d, t, COALESCE(f, '') ORDER BY nord) AS rk
        FROM nrows n
    ), orows AS (
      SELECT d0.id AS oid, d0.duty_date AS d, upper(btrim(d0.duty_type)) AS t,
             NULLIF(btrim(d0.flight_number), '') AS f, d0.s_no, d0.created_at,
             row_number() OVER (PARTITION BY d0.duty_date, upper(btrim(d0.duty_type)), COALESCE(btrim(d0.flight_number), '')
                                ORDER BY d0.s_no NULLS LAST, d0.created_at, d0.id) AS rk
        FROM roster_duties d0 WHERE d0.roster_id = p_roster_id
    ), p1 AS (
      SELECT o2.oid, n.nord
        FROM orows o2 JOIN nk n
          ON n.d = o2.d AND n.t = o2.t AND COALESCE(n.f, '') = COALESCE(o2.f, '') AND n.rk = o2.rk
    ), o2 AS (SELECT * FROM orows WHERE oid NOT IN (SELECT oid FROM p1)),
       n2 AS (SELECT * FROM nk    WHERE nord NOT IN (SELECT nord FROM p1)),
    p2 AS (
      SELECT a.oid, b.nord
        FROM (SELECT oid, f, row_number() OVER (PARTITION BY f ORDER BY d, s_no NULLS LAST, oid) AS q
                FROM o2 WHERE t = 'OP' AND f IS NOT NULL) a
        JOIN (SELECT nord, f, row_number() OVER (PARTITION BY f ORDER BY d, nord) AS q
                FROM n2 WHERE t = 'OP' AND f IS NOT NULL) b
          ON a.f = b.f AND a.q = b.q
    ), o3 AS (SELECT * FROM o2 WHERE oid NOT IN (SELECT oid FROM p2)),
       n3 AS (SELECT * FROM n2 WHERE nord NOT IN (SELECT nord FROM p2)),
    p3 AS (
      SELECT a.oid, b.nord
        FROM (SELECT oid, d, row_number() OVER (PARTITION BY d ORDER BY s_no NULLS LAST, created_at, oid) AS q FROM o3) a
        JOIN (SELECT nord, d, row_number() OVER (PARTITION BY d ORDER BY nord) AS q FROM n3) b
          ON a.d = b.d AND a.q = b.q
    )
    SELECT 'pair'::text AS kind, oid, nord FROM p1
    UNION ALL SELECT 'pair', oid, nord FROM p2
    UNION ALL SELECT 'pair', oid, nord FROM p3
    UNION ALL SELECT 'remove', oid, NULL::int FROM o3 WHERE oid NOT IN (SELECT oid FROM p3)
    UNION ALL SELECT 'add', NULL::uuid, nord FROM n3 WHERE nord NOT IN (SELECT nord FROM p3)
  LOOP
    IF r.kind = 'remove' THEN
      SELECT * INTO o FROM roster_duties WHERE id = r.oid;
      IF o.status IN ('completed', 'diverted') THEN
        v_flown := v_flown + 1;
      ELSIF o.status IN ('removed', 'cancelled') THEN
        v_unchanged := v_unchanged + 1;
      ELSE
        PERFORM set_config('roster.change_type',   'removed', true);
        PERFORM set_config('roster.change_reason', v_reason,  true);
        UPDATE roster_duties SET status = 'removed' WHERE id = r.oid;
        PERFORM set_config('roster.change_type',   '', true);
        PERFORM set_config('roster.change_reason', '', true);
        v_removed := v_removed + 1;
      END IF;
      CONTINUE;
    END IF;

    j      := p_duties -> (r.nord - 1);
    n_type := upper(btrim(j->>'duty_type'));
    n_date := (j->>'duty_date')::date;
    n_flt  := NULLIF(btrim(j->>'flight_number'), '');
    n_org  := NULLIF(btrim(j->>'origin'), '');
    n_dst  := NULLIF(btrim(j->>'destination'), '');
    n_std  := NULLIF(btrim(j->>'std_local'), '');
    n_stdu := NULLIF(btrim(j->>'std_utc'), '');
    n_sta  := NULLIF(btrim(j->>'sta_local'), '');
    n_stau := NULLIF(btrim(j->>'sta_utc'), '');
    n_blk  := NULLIF(j->>'block_scheduled_mins', '')::int;
    n_rem  := NULLIF(btrim(j->>'remark'), '');

    IF r.kind = 'add' THEN
      IF n_type IS NULL OR n_date IS NULL THEN
        RAISE EXCEPTION 'Duty % in the revised roster has no date or duty type.', r.nord;
      END IF;
      PERFORM set_config('roster.change_type',   'added',  true);
      PERFORM set_config('roster.change_reason', v_reason, true);
      INSERT INTO roster_duties
        (roster_id, s_no, duty_date, duty_type, flight_number, origin, destination,
         std_local, std_utc, sta_local, sta_utc, block_scheduled_mins, remark)
      VALUES
        (p_roster_id, NULLIF(j->>'s_no', '')::int, n_date, n_type, n_flt, n_org, n_dst,
         n_std, n_stdu, n_sta, n_stau, n_blk, n_rem);
      PERFORM set_config('roster.change_type',   '', true);
      PERFORM set_config('roster.change_reason', '', true);
      v_added := v_added + 1;
      CONTINUE;
    END IF;

    -- kind = 'pair'
    SELECT * INTO o FROM roster_duties WHERE id = r.oid;
    IF o.status IN ('completed', 'diverted') THEN
      v_flown := v_flown + 1;           -- already flown: never modified
      CONTINUE;
    END IF;

    IF (upper(btrim(o.duty_type)), o.duty_date, o.flight_number, o.origin, o.destination,
        o.std_local, o.std_utc, o.sta_local, o.sta_utc, o.block_scheduled_mins, o.remark)
       IS NOT DISTINCT FROM
       (n_type, n_date, n_flt, n_org, n_dst, n_std, n_stdu, n_sta, n_stau, n_blk, n_rem) THEN
      v_unchanged := v_unchanged + 1;
      IF o.s_no IS DISTINCT FROM NULLIF(j->>'s_no', '')::int THEN
        UPDATE roster_duties SET s_no = NULLIF(j->>'s_no', '')::int WHERE id = o.id;
      END IF;
      CONTINUE;
    END IF;

    -- What kind of change is it?
    v_type := CASE
      WHEN upper(btrim(o.duty_type)) IS DISTINCT FROM n_type THEN
        CASE WHEN n_type LIKE 'OP%' AND upper(btrim(o.duty_type)) = 'SBY' THEN 'activated'
             WHEN n_type LIKE 'OP%'                                       THEN 'assigned'
             WHEN upper(btrim(o.duty_type)) LIKE 'OP%'                    THEN 'stood_down'
             ELSE 'type_changed' END
      WHEN o.duty_date IS DISTINCT FROM n_date                                  THEN 'postponed'
      WHEN (o.flight_number, o.origin, o.destination)
           IS DISTINCT FROM (n_flt, n_org, n_dst)                               THEN 'flight_changed'
      WHEN (o.std_local, o.std_utc, o.sta_local, o.sta_utc)
           IS DISTINCT FROM (n_std, n_stdu, n_sta, n_stau)                      THEN 'retimed'
      ELSE 'edited' END;

    -- The revised roster is the new truth for the schedule. A crew-reported
    -- delay is superseded; a different flight/duty starts fresh.
    v_status := CASE
      WHEN o.status = 'delayed' THEN 'rostered'
      WHEN upper(btrim(o.duty_type)) IS DISTINCT FROM n_type
        OR o.flight_number IS DISTINCT FROM n_flt THEN 'rostered'
      ELSE o.status END;

    PERFORM set_config('roster.change_type',   v_type,   true);
    PERFORM set_config('roster.change_reason', v_reason, true);
    UPDATE roster_duties SET
      duty_type = n_type, duty_date = n_date, flight_number = n_flt,
      origin = n_org, destination = n_dst,
      std_local = n_std, std_utc = n_stdu, sta_local = n_sta, sta_utc = n_stau,
      block_scheduled_mins = n_blk, remark = n_rem, status = v_status,
      s_no = COALESCE(NULLIF(j->>'s_no', '')::int, o.s_no)
    WHERE id = o.id;
    PERFORM set_config('roster.change_type',   '', true);
    PERFORM set_config('roster.change_reason', '', true);
    v_changed := v_changed + 1;
  END LOOP;

  IF v_changed + v_added + v_removed > 0 THEN
    UPDATE crew_rosters SET
      revision             = revision + 1,
      revised_at           = now(),
      total_est_block_mins = COALESCE(NULLIF(p_meta->>'total_est_block_mins', '')::int, total_est_block_mins),
      source_filename      = COALESCE(NULLIF(p_meta->>'source_filename', ''), source_filename),
      raw_text             = COALESCE(NULLIF(p_meta->>'raw_text', ''), raw_text)
    WHERE id = p_roster_id;
  END IF;

  RETURN jsonb_build_object(
    'changed', v_changed, 'added', v_added, 'removed', v_removed,
    'unchanged', v_unchanged, 'kept_flown', v_flown);
END;
$$;

REVOKE ALL ON FUNCTION roster_apply_revision(uuid, jsonb, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_apply_revision(uuid, jsonb, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Verification
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('roster_publish(jsonb,jsonb,uuid)') IS NULL
     OR to_regprocedure('roster_apply_revision(uuid,jsonb,jsonb,text)') IS NULL
     OR to_regprocedure('roster_assign_owner(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Migration 20: functions not found';
  END IF;
  RAISE NOTICE 'Migration 20 verified: roster_publish, roster_apply_revision, roster_assign_owner and the attach trigger are in place.';
END;
$$;
