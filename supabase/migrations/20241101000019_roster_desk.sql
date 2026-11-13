-- =============================================================================
-- Migration: 20241101000019_roster_desk.sql
-- Description: Roster Desk support for roster officers
--
-- Requires migration 17.
--
--   roster_desk_crew()                 – the crew list for the officer's airline,
--                                        with roster counts (officer-only)
--   roster_set_crew_code(user, code)   – set a crew member's roster code
--                                        (officer-only; profiles RLS lets users
--                                        edit only their own row)
--
-- Both return only what the desk needs — no emails or phone numbers — and
-- never cross an airline boundary.
--
-- Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('roster_is_officer()') IS NULL THEN
    RAISE EXCEPTION 'Migration 19 requires migration 17 (roster_is_officer not found).';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Crew list for the desk
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS roster_desk_crew();

CREATE FUNCTION roster_desk_crew()
RETURNS TABLE (
  user_id          uuid,
  display_name     text,
  crew_position    text,
  crew_code        text,
  roster_count     int,
  latest_from      date,
  latest_to        date
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

  RETURN QUERY
  SELECT p.id,
         COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), 'Unnamed crew'),
         p.position,
         p.crew_code,
         COALESCE(r.cnt, 0)::int,
         r.latest_from,
         r.latest_to
    FROM profiles p
    LEFT JOIN LATERAL (
      SELECT count(*)         AS cnt,
             (array_agg(cr.period_from ORDER BY cr.period_to DESC NULLS LAST))[1] AS latest_from,
             max(cr.period_to) AS latest_to
        FROM crew_rosters cr
       WHERE cr.crew_user_id = p.id
         AND cr.tenant_id    = v_tenant
    ) r ON true
   WHERE p.tenant_id  = v_tenant
     AND p.user_class = 'airline'
     AND p.blocked IS NOT TRUE
   ORDER BY 2;
END;
$$;

REVOKE ALL ON FUNCTION roster_desk_crew() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_desk_crew() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Set a crew member's roster code
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_set_crew_code(p_user_id uuid, p_code text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_code   text := NULLIF(upper(btrim(p_code)), '');
  v_other  text;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers can set a crew code.' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles p
                  WHERE p.id = p_user_id AND p.tenant_id = v_tenant
                    AND p.user_class = 'airline') THEN
    RAISE EXCEPTION 'That crew member is not in your airline.' USING ERRCODE = '42501';
  END IF;

  IF v_code IS NOT NULL AND v_code !~ '^[A-Z0-9][A-Z0-9._-]{0,19}$' THEN
    RAISE EXCEPTION 'A crew code can contain letters, numbers, dot, dash and underscore (max 20).';
  END IF;

  IF v_code IS NOT NULL THEN
    SELECT COALESCE(NULLIF(btrim(o.crew_name), ''), NULLIF(btrim(o.full_name), ''), 'another crew member')
      INTO v_other
      FROM profiles o
     WHERE o.tenant_id = v_tenant AND o.user_class = 'airline'
       AND upper(o.crew_code) = v_code AND o.id <> p_user_id
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION '% is already used by %.', v_code, v_other;
    END IF;
  END IF;

  UPDATE profiles SET crew_code = v_code WHERE id = p_user_id;
  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION roster_set_crew_code(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roster_set_crew_code(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Verification
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('roster_desk_crew()') IS NULL
     OR to_regprocedure('roster_set_crew_code(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 19: desk functions not found';
  END IF;
  RAISE NOTICE 'Migration 19 verified: roster_desk_crew() and roster_set_crew_code() present.';
END;
$$;
