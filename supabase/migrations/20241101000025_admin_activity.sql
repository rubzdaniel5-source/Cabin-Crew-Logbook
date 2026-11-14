-- =============================================================================
-- Migration: 20241101000025_admin_activity.sql
-- Description: Activity overview for administrators
--
--   profiles.last_seen_at     – last time the user opened the app (throttled)
--   touch_last_seen()         – called by the app at login / resume
--   admin_activity_overview() – one JSON document: users, activity, roster work
--
-- Requires migration 24 (admin check pattern) and 17 (roster_duty_changes).
-- Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('roster_duty_changes') IS NULL THEN
    RAISE EXCEPTION 'Migration 25 requires migration 17.';
  END IF;
END;
$$;

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;

CREATE OR REPLACE FUNCTION touch_last_seen()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  UPDATE profiles SET last_seen_at = now()
   WHERE id = auth.uid()
     AND (last_seen_at IS NULL OR last_seen_at < now() - interval '5 minutes');
$$;
REVOKE ALL ON FUNCTION touch_last_seen() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION touch_last_seen() TO authenticated;

DROP FUNCTION IF EXISTS admin_activity_overview(int);
CREATE FUNCTION admin_activity_overview(p_days int DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_days   int  := LEAST(GREATEST(COALESCE(p_days, 7), 1), 90);
  v_since  timestamptz;
  r        jsonb;
BEGIN
  IF NOT COALESCE((SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false) THEN
    RAISE EXCEPTION 'Administrators only.' USING ERRCODE = '42501';
  END IF;
  v_since := now() - make_interval(days => v_days);

  SELECT jsonb_build_object(
    'period_days', v_days,
    'generated_at', now(),

    'users', (SELECT jsonb_build_object(
        'total',        count(*),
        'blocked',      count(*) FILTER (WHERE blocked IS TRUE),
        'active_24h',   count(*) FILTER (WHERE last_seen_at >= now() - interval '24 hours'),
        'active_period',count(*) FILTER (WHERE last_seen_at >= v_since),
        'never_seen',   count(*) FILTER (WHERE last_seen_at IS NULL),
        'new_period',   count(*) FILTER (WHERE created_at >= v_since),
        'by_role', COALESCE((SELECT jsonb_object_agg(role, n) FROM (
                     SELECT COALESCE(role,'crew') AS role, count(*) AS n
                       FROM profiles WHERE tenant_id = v_tenant GROUP BY 1) x), '{}'::jsonb))
        FROM profiles WHERE tenant_id = v_tenant),

    'recent_users', COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (
        SELECT id AS user_id, full_name, COALESCE(role,'crew') AS role, last_seen_at
          FROM profiles
         WHERE tenant_id = v_tenant AND last_seen_at IS NOT NULL
         ORDER BY last_seen_at DESC LIMIT 15) t), '[]'::jsonb),

    'roster', jsonb_build_object(
        'uploads', (SELECT count(*) FROM crew_rosters
                     WHERE tenant_id = v_tenant AND created_at >= v_since),
        'changes', (SELECT count(*) FROM roster_duty_changes
                     WHERE tenant_id = v_tenant AND changed_at >= v_since),
        'by_source', COALESCE((SELECT jsonb_object_agg(source, n) FROM (
                     SELECT source, count(*) AS n FROM roster_duty_changes
                      WHERE tenant_id = v_tenant AND changed_at >= v_since GROUP BY 1) x), '{}'::jsonb),
        'by_type', COALESCE((SELECT jsonb_object_agg(change_type, n) FROM (
                     SELECT change_type, count(*) AS n FROM roster_duty_changes
                      WHERE tenant_id = v_tenant AND changed_at >= v_since AND source = 'officer'
                      GROUP BY 1) x), '{}'::jsonb),
        'unacknowledged', (SELECT count(*) FROM roster_duty_changes
                     WHERE tenant_id = v_tenant AND source = 'officer' AND acknowledged_at IS NULL)),

    'officers', COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (
        SELECT p.id AS user_id, p.full_name,
               (SELECT count(*) FROM roster_duty_changes c
                 WHERE c.changed_by = p.id AND c.source = 'officer' AND c.changed_at >= v_since) AS changes,
               (SELECT count(*) FROM crew_rosters u
                 WHERE u.uploaded_by = p.id AND u.created_at >= v_since) AS uploads
          FROM profiles p
         WHERE p.tenant_id = v_tenant AND (p.role = 'roster_officer' OR p.is_admin IS TRUE)
         ORDER BY changes DESC, uploads DESC LIMIT 10) t), '[]'::jsonb),

    'daily', COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.day) FROM (
        SELECT d::date AS day,
               (SELECT count(*) FROM roster_duty_changes c
                 WHERE c.tenant_id = v_tenant AND c.changed_at::date = d::date) AS changes,
               (SELECT count(*) FROM crew_rosters u
                 WHERE u.tenant_id = v_tenant AND u.created_at::date = d::date) AS uploads,
               (SELECT count(*) FROM profiles q
                 WHERE q.tenant_id = v_tenant AND q.created_at::date = d::date) AS signups
          FROM generate_series((now() - make_interval(days => v_days - 1))::date, now()::date, interval '1 day') d) t),
      '[]'::jsonb)
  ) INTO r;
  RETURN r;
END;
$$;
REVOKE ALL ON FUNCTION admin_activity_overview(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_activity_overview(int) TO authenticated;

DO $$
BEGIN
  IF to_regprocedure('admin_activity_overview(int)') IS NULL OR to_regprocedure('touch_last_seen()') IS NULL THEN
    RAISE EXCEPTION 'Migration 25 verification failed.';
  END IF;
  RAISE NOTICE 'Migration 25 OK';
END;
$$;
