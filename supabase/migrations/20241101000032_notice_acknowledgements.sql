-- =============================================================================
-- Migration: 20241101000032_notice_acknowledgements.sql
-- Description: Cabin Notices — "must acknowledge" notices.
--   cabin_notices.requires_ack   – set when a notice is posted
--   notice_acks                  – who acknowledged which notice, and when
--   notice_reminders             – throttle for "remind the people who haven't"
--   Crew:    notice_ack, notice_my_pending, notice_my_acks
--   Posters (admin / ops manager): notice_ack_counts, notice_ack_report, notice_remind
--   A push notification goes out when a must-acknowledge notice is posted.
-- Requires migrations 30 and 31. notice ids are handled as text so this works
-- whatever type cabin_notices.id has. Safe to re-run.
-- =============================================================================
DO $$ BEGIN
  IF to_regclass('cabin_notices') IS NULL OR to_regclass('push_queue') IS NULL THEN
    RAISE EXCEPTION 'Migration 32 requires the cabin_notices table and migration 31.';
  END IF;
END $$;

ALTER TABLE cabin_notices ADD COLUMN IF NOT EXISTS requires_ack boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS notice_acks (
  notice_id text NOT NULL,
  user_id   uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  acked_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (notice_id, user_id)
);
ALTER TABLE notice_acks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON notice_acks FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS notice_reminders (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notice_id text NOT NULL,
  sent_by   uuid REFERENCES profiles(id) ON DELETE SET NULL,
  sent_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notice_reminders_n ON notice_reminders (notice_id, sent_at DESC);
ALTER TABLE notice_reminders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON notice_reminders FROM PUBLIC, anon, authenticated;

-- Clean up acknowledgements when a notice is deleted
CREATE OR REPLACE FUNCTION notice_acks_cleanup() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$ BEGIN DELETE FROM notice_acks WHERE notice_id = OLD.id::text; DELETE FROM notice_reminders WHERE notice_id = OLD.id::text; RETURN NULL; END; $$;
DROP TRIGGER IF EXISTS notice_acks_cleanup ON cabin_notices;
CREATE TRIGGER notice_acks_cleanup AFTER DELETE ON cabin_notices FOR EACH ROW EXECUTE FUNCTION notice_acks_cleanup();

-- push_queue gains the 'notice' kind; notices follow the "messages" push switch
ALTER TABLE push_queue DROP CONSTRAINT IF EXISTS push_queue_kind_check;
ALTER TABLE push_queue ADD CONSTRAINT push_queue_kind_check CHECK (kind IN ('roster_change','message','leave_decision','notice'));
CREATE OR REPLACE FUNCTION push_pref_allows(p_user uuid, p_kind text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE((SELECT CASE p_kind WHEN 'roster_change' THEN c.push_roster WHEN 'message' THEN c.push_messages
                                      WHEN 'notice' THEN c.push_messages WHEN 'leave_decision' THEN c.push_leave ELSE true END
                     FROM crew_comm_prefs c WHERE c.user_id = p_user), true);
$$;
REVOKE ALL ON FUNCTION push_pref_allows(uuid, text) FROM PUBLIC, anon, authenticated;

-- Who may post / see the report
CREATE OR REPLACE FUNCTION notice_is_poster() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE((SELECT (p.is_admin IS TRUE OR p.role IN ('admin','ops_manager')) AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false);
$$;
REVOKE ALL ON FUNCTION notice_is_poster() FROM PUBLIC, anon, authenticated;

-- Everyone in the tenant who is expected to read a notice (not admins, not blocked)
CREATE OR REPLACE FUNCTION notice_audience(p_tenant uuid)
RETURNS TABLE (user_id uuid, full_name text, crew_code text, role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT p.id, COALESCE(NULLIF(btrim(p.crew_name), ''), p.full_name), p.crew_code, COALESCE(p.role, 'crew')
    FROM profiles p
   WHERE p.tenant_id = p_tenant AND p.blocked IS NOT TRUE AND p.is_admin IS NOT TRUE AND COALESCE(p.role, 'crew') <> 'admin';
$$;
REVOKE ALL ON FUNCTION notice_audience(uuid) FROM PUBLIC, anon, authenticated;

-- A notice belongs to the tenant of the person who posted it
CREATE OR REPLACE FUNCTION notice_tenant(p_id text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT p.tenant_id FROM cabin_notices n JOIN profiles p ON p.id = n.uploaded_by WHERE n.id::text = p_id;
$$;
REVOKE ALL ON FUNCTION notice_tenant(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Crew
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notice_ack(p_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  IF notice_tenant(p_id) IS DISTINCT FROM guestora_resolve_tenant_id() THEN
    RAISE EXCEPTION 'Notice not found.' USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO notice_acks (notice_id, user_id) VALUES (p_id, auth.uid()) ON CONFLICT DO NOTHING;
END; $$;
REVOKE ALL ON FUNCTION notice_ack(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION notice_ack(text) TO authenticated;

CREATE OR REPLACE FUNCTION notice_my_acks() RETURNS TABLE (notice_id text, acked_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$ SELECT a.notice_id, a.acked_at FROM notice_acks a WHERE a.user_id = auth.uid(); $$;
REVOKE ALL ON FUNCTION notice_my_acks() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION notice_my_acks() TO authenticated;

-- Notices I must still acknowledge (own tenant, flagged, not yet acknowledged, not posted by me)
CREATE OR REPLACE FUNCTION notice_my_pending() RETURNS TABLE (notice_id text, title text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT n.id::text, n.title, n.created_at
    FROM cabin_notices n JOIN profiles up ON up.id = n.uploaded_by
   WHERE n.requires_ack AND up.tenant_id = guestora_resolve_tenant_id() AND n.uploaded_by <> auth.uid()
     AND NOT EXISTS (SELECT 1 FROM notice_acks a WHERE a.notice_id = n.id::text AND a.user_id = auth.uid())
     AND EXISTS (SELECT 1 FROM profiles me WHERE me.id = auth.uid() AND me.is_admin IS NOT TRUE AND COALESCE(me.role,'crew') <> 'admin')
   ORDER BY n.created_at DESC;
$$;
REVOKE ALL ON FUNCTION notice_my_pending() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION notice_my_pending() TO authenticated;

-- ---------------------------------------------------------------------------
-- Posters: counts, who has / hasn't, reminders
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notice_ack_counts() RETURNS TABLE (notice_id text, total int, acked int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v_t uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT notice_is_poster() THEN RAISE EXCEPTION 'Not allowed.' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT n.id::text, (SELECT count(*)::int FROM notice_audience(v_t)),
         (SELECT count(*)::int FROM notice_acks a JOIN notice_audience(v_t) au ON au.user_id = a.user_id WHERE a.notice_id = n.id::text)
    FROM cabin_notices n JOIN profiles up ON up.id = n.uploaded_by
   WHERE n.requires_ack AND up.tenant_id = v_t;
END; $$;
REVOKE ALL ON FUNCTION notice_ack_counts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION notice_ack_counts() TO authenticated;

CREATE OR REPLACE FUNCTION notice_ack_report(p_id text)
RETURNS TABLE (user_id uuid, full_name text, crew_code text, role text, acked_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v_t uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT notice_is_poster() THEN RAISE EXCEPTION 'Not allowed.' USING ERRCODE = '42501'; END IF;
  IF notice_tenant(p_id) IS DISTINCT FROM v_t THEN RAISE EXCEPTION 'Notice not found.' USING ERRCODE = 'P0002'; END IF;
  RETURN QUERY
  SELECT au.user_id, au.full_name, au.crew_code, au.role, a.acked_at
    FROM notice_audience(v_t) au LEFT JOIN notice_acks a ON a.user_id = au.user_id AND a.notice_id = p_id
   ORDER BY (a.acked_at IS NOT NULL), lower(au.full_name);
END; $$;
REVOKE ALL ON FUNCTION notice_ack_report(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION notice_ack_report(text) TO authenticated;

-- Push a reminder to everyone who has not acknowledged (at most one every 3 hours per notice)
CREATE OR REPLACE FUNCTION notice_remind(p_id text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v_t uuid := guestora_resolve_tenant_id(); v_title text; v_n int;
BEGIN
  IF NOT notice_is_poster() THEN RAISE EXCEPTION 'Not allowed.' USING ERRCODE = '42501'; END IF;
  IF notice_tenant(p_id) IS DISTINCT FROM v_t THEN RAISE EXCEPTION 'Notice not found.' USING ERRCODE = 'P0002'; END IF;
  IF EXISTS (SELECT 1 FROM notice_reminders r WHERE r.notice_id = p_id AND r.sent_at > now() - interval '3 hours') THEN
    RAISE EXCEPTION 'A reminder was sent recently. Please wait a few hours.' USING ERRCODE = '54000';
  END IF;
  SELECT n.title INTO v_title FROM cabin_notices n WHERE n.id::text = p_id AND n.requires_ack;
  IF v_title IS NULL THEN RAISE EXCEPTION 'That notice does not need acknowledgement.' USING ERRCODE = '22023'; END IF;
  INSERT INTO push_queue (tenant_id, user_id, kind, title, body)
  SELECT v_t, au.user_id, 'notice', 'Reminder: please acknowledge', left(v_title, 120)
    FROM notice_audience(v_t) au
   WHERE NOT EXISTS (SELECT 1 FROM notice_acks a WHERE a.notice_id = p_id AND a.user_id = au.user_id)
     AND EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.user_id = au.user_id)
     AND push_pref_allows(au.user_id, 'notice');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO notice_reminders (notice_id, sent_by) VALUES (p_id, auth.uid());
  RETURN v_n;
END; $$;
REVOKE ALL ON FUNCTION notice_remind(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION notice_remind(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Push when a must-acknowledge notice is posted
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION notice_push_enqueue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v_t uuid;
BEGIN
  IF NOT NEW.requires_ack THEN RETURN NULL; END IF;
  BEGIN
    SELECT tenant_id INTO v_t FROM profiles WHERE id = NEW.uploaded_by;
    IF v_t IS NULL THEN RETURN NULL; END IF;
    INSERT INTO push_queue (tenant_id, user_id, kind, title, body)
    SELECT v_t, au.user_id, 'notice', 'New notice: acknowledgement needed', left(NEW.title, 120)
      FROM notice_audience(v_t) au
     WHERE au.user_id <> NEW.uploaded_by
       AND EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.user_id = au.user_id)
       AND push_pref_allows(au.user_id, 'notice');
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END; $$;
DROP TRIGGER IF EXISTS notice_push_enqueue ON cabin_notices;
CREATE TRIGGER notice_push_enqueue AFTER INSERT ON cabin_notices FOR EACH ROW EXECUTE FUNCTION notice_push_enqueue();

DO $$ BEGIN
  IF to_regprocedure('notice_ack(text)') IS NULL OR to_regprocedure('notice_ack_report(text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 32: objects not found';
  END IF;
  RAISE NOTICE 'Migration 32 verified: notice acknowledgements ready.';
END $$;
