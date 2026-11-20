-- =============================================================================
-- Migration: 20241101000031_calendar_and_push.sql
-- Description: Calendar subscription feed + phone push notifications.
--
--   calendar_tokens   – one secret token per crew member for their private .ics feed
--   push_subscriptions– a phone/browser registered for push
--   push_queue        – outgoing push notifications
--   crew_comm_prefs   – gains push_roster / push_messages / push_leave
--
--   Crew RPCs:     cal_token_get, cal_token_reset, push_sub_save, push_sub_delete, push_my_count,
--                  comm_prefs_get/comm_prefs_set (now 6 switches)
--   Service role:  cal_feed (roster-ics function), push_claim_batch, push_mark, push_sub_drop
--                  (send-push function)
--   Triggers queue a push for officer roster changes, leave decisions and messages.
--   Queueing problems never block the action that caused them.
-- Requires migration 30. Safe to re-run.
-- =============================================================================
DO $$ BEGIN
  IF to_regclass('email_queue') IS NULL THEN RAISE EXCEPTION 'Migration 31 requires migration 30.'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS calendar_tokens (
  user_id    uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  token      text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE calendar_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON calendar_tokens FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  endpoint   text NOT NULL UNIQUE,
  p256dh     text NOT NULL,
  auth       text NOT NULL,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_ok_at timestamptz
);
CREATE INDEX IF NOT EXISTS push_sub_user ON push_subscriptions (user_id);
ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON push_subscriptions FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS push_queue (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL REFERENCES guestora_tenants(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  kind       text NOT NULL CHECK (kind IN ('roster_change','message','leave_decision')),
  title      text NOT NULL,
  body       text NOT NULL,
  state      text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','sending','sent','failed')),
  attempts   int  NOT NULL DEFAULT 0,
  send_after timestamptz NOT NULL DEFAULT now(),
  locked_at  timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_queue_due ON push_queue (state, send_after);
ALTER TABLE push_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON push_queue FROM PUBLIC, anon, authenticated;

ALTER TABLE crew_comm_prefs ADD COLUMN IF NOT EXISTS push_roster   boolean NOT NULL DEFAULT true;
ALTER TABLE crew_comm_prefs ADD COLUMN IF NOT EXISTS push_messages boolean NOT NULL DEFAULT true;
ALTER TABLE crew_comm_prefs ADD COLUMN IF NOT EXISTS push_leave    boolean NOT NULL DEFAULT true;

-- ---------------------------------------------------------------------------
-- Preferences (now email + push)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS comm_prefs_get();
CREATE FUNCTION comm_prefs_get()
RETURNS TABLE (email_roster boolean, email_messages boolean, email_leave boolean,
               push_roster boolean, push_messages boolean, push_leave boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE(c.email_roster, true), COALESCE(c.email_messages, true), COALESCE(c.email_leave, true),
         COALESCE(c.push_roster, true), COALESCE(c.push_messages, true), COALESCE(c.push_leave, true)
    FROM (SELECT 1) x LEFT JOIN crew_comm_prefs c ON c.user_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION comm_prefs_get() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION comm_prefs_get() TO authenticated;

DROP FUNCTION IF EXISTS comm_prefs_set(boolean, boolean, boolean);
CREATE OR REPLACE FUNCTION comm_prefs_set(p_roster boolean, p_messages boolean, p_leave boolean,
                                          p_push_roster boolean DEFAULT true, p_push_messages boolean DEFAULT true,
                                          p_push_leave boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  INSERT INTO crew_comm_prefs (user_id, email_roster, email_messages, email_leave, push_roster, push_messages, push_leave, updated_at)
  VALUES (auth.uid(), COALESCE(p_roster,true), COALESCE(p_messages,true), COALESCE(p_leave,true),
          COALESCE(p_push_roster,true), COALESCE(p_push_messages,true), COALESCE(p_push_leave,true), now())
  ON CONFLICT (user_id) DO UPDATE SET email_roster = EXCLUDED.email_roster, email_messages = EXCLUDED.email_messages,
    email_leave = EXCLUDED.email_leave, push_roster = EXCLUDED.push_roster, push_messages = EXCLUDED.push_messages,
    push_leave = EXCLUDED.push_leave, updated_at = now();
END;
$$;
REVOKE ALL ON FUNCTION comm_prefs_set(boolean,boolean,boolean,boolean,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION comm_prefs_set(boolean,boolean,boolean,boolean,boolean,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION push_pref_allows(p_user uuid, p_kind text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE((SELECT CASE p_kind WHEN 'roster_change' THEN c.push_roster WHEN 'message' THEN c.push_messages
                                      WHEN 'leave_decision' THEN c.push_leave ELSE true END
                     FROM crew_comm_prefs c WHERE c.user_id = p_user), true);
$$;
REVOKE ALL ON FUNCTION push_pref_allows(uuid, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Calendar token
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cal_token_get()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  SELECT token INTO v FROM calendar_tokens WHERE user_id = auth.uid();
  IF v IS NULL THEN
    v := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    INSERT INTO calendar_tokens (user_id, token) VALUES (auth.uid(), v)
      ON CONFLICT (user_id) DO NOTHING;
    SELECT token INTO v FROM calendar_tokens WHERE user_id = auth.uid();
  END IF;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION cal_token_get() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cal_token_get() TO authenticated;

CREATE OR REPLACE FUNCTION cal_token_reset()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  DELETE FROM calendar_tokens WHERE user_id = auth.uid();
  RETURN cal_token_get();
END;
$$;
REVOKE ALL ON FUNCTION cal_token_reset() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cal_token_reset() TO authenticated;

-- Service role only: everything the .ics feed needs for one token
CREATE OR REPLACE FUNCTION cal_feed(p_token text)
RETURNS TABLE (crew_name text, duty_id uuid, duty_date date, duty_type text, flight_number text, origin text,
               destination text, std_local text, std_utc text, sta_local text, sta_utc text, remark text,
               status text, updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE(NULLIF(btrim(p.crew_name), ''), p.full_name), d.id, d.duty_date, d.duty_type, d.flight_number,
         d.origin, d.destination, d.std_local, d.std_utc, d.sta_local, d.sta_utc, d.remark, d.status,
         COALESCE(d.last_changed_at, d.created_at)
    FROM calendar_tokens t
    JOIN profiles p ON p.id = t.user_id AND p.blocked IS NOT TRUE
    JOIN crew_rosters r ON r.crew_user_id = t.user_id
    JOIN roster_duties d ON d.roster_id = r.id
   WHERE t.token = p_token AND length(p_token) >= 20
     AND d.duty_date BETWEEN current_date - 60 AND current_date + 200
   ORDER BY d.duty_date, d.std_local NULLS LAST;
$$;
REVOKE ALL ON FUNCTION cal_feed(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Push subscriptions (crew)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION push_sub_save(p_endpoint text, p_p256dh text, p_auth text, p_ua text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  IF COALESCE(p_endpoint,'') !~ '^https://' OR COALESCE(p_p256dh,'') = '' OR COALESCE(p_auth,'') = '' THEN
    RAISE EXCEPTION 'Invalid push subscription.' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM push_subscriptions WHERE user_id = auth.uid() AND endpoint <> p_endpoint) >= 8 THEN
    DELETE FROM push_subscriptions WHERE id IN
      (SELECT id FROM push_subscriptions WHERE user_id = auth.uid() ORDER BY created_at LIMIT 1);
  END IF;
  INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  VALUES (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_ua, 200))
  ON CONFLICT (endpoint) DO UPDATE SET user_id = auth.uid(), p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
                                       user_agent = EXCLUDED.user_agent;
END;
$$;
REVOKE ALL ON FUNCTION push_sub_save(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION push_sub_save(text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION push_sub_delete(p_endpoint text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$ DELETE FROM push_subscriptions WHERE user_id = auth.uid() AND endpoint = p_endpoint; $$;
REVOKE ALL ON FUNCTION push_sub_delete(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION push_sub_delete(text) TO authenticated;

CREATE OR REPLACE FUNCTION push_my_count()
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$ SELECT count(*)::int FROM push_subscriptions WHERE user_id = auth.uid(); $$;
REVOKE ALL ON FUNCTION push_my_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION push_my_count() TO authenticated;

-- ---------------------------------------------------------------------------
-- Queue triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION push_roster_enqueue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v_owner uuid; v_duty roster_duties;
BEGIN
  IF NEW.source <> 'officer' OR NEW.change_type IN ('completed','diverted') THEN RETURN NULL; END IF;
  BEGIN
    SELECT r.crew_user_id INTO v_owner FROM crew_rosters r WHERE r.id = NEW.roster_id;
    IF v_owner IS NULL OR v_owner IS NOT DISTINCT FROM NEW.changed_by THEN RETURN NULL; END IF;
    IF NOT EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.user_id = v_owner) OR NOT push_pref_allows(v_owner, 'roster_change') THEN RETURN NULL; END IF;
    SELECT * INTO v_duty FROM roster_duties d WHERE d.id = NEW.duty_id;
    INSERT INTO push_queue (tenant_id, user_id, kind, title, body, send_after)
    VALUES (NEW.tenant_id, v_owner, 'roster_change', 'Roster updated',
            initcap(replace(NEW.change_type, '_', ' ')) || ': ' ||
            concat_ws(' ', v_duty.duty_date::text, COALESCE(v_duty.flight_number, v_duty.duty_type),
                      CASE WHEN v_duty.origin IS NOT NULL AND v_duty.destination IS NOT NULL THEN v_duty.origin || '-' || v_duty.destination END),
            now() + interval '1 minute');
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END; $$;
DROP TRIGGER IF EXISTS push_roster_enqueue ON roster_duty_changes;
CREATE TRIGGER push_roster_enqueue AFTER INSERT ON roster_duty_changes FOR EACH ROW EXECUTE FUNCTION push_roster_enqueue();

CREATE OR REPLACE FUNCTION push_leave_enqueue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v_user uuid;
BEGIN
  IF NEW.status NOT IN ('approved','declined','cancelled') OR NEW.decision_seen IS DISTINCT FROM false THEN RETURN NULL; END IF;
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;
  IF TG_OP = 'INSERT' AND NEW.via <> 'officer' THEN RETURN NULL; END IF;
  BEGIN
    SELECT d.user_id INTO v_user FROM crew_directory d WHERE d.id = NEW.crew_id;
    IF v_user IS NULL OR NOT push_pref_allows(v_user, 'leave_decision') THEN RETURN NULL; END IF;
    IF NOT EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.user_id = v_user) THEN RETURN NULL; END IF;
    INSERT INTO push_queue (tenant_id, user_id, kind, title, body)
    VALUES (NEW.tenant_id, v_user, 'leave_decision', 'Leave ' || NEW.status,
            NEW.start_date::text || CASE WHEN NEW.end_date <> NEW.start_date THEN ' to ' || NEW.end_date::text ELSE '' END);
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END; $$;
DROP TRIGGER IF EXISTS push_leave_enqueue ON crew_leave;
CREATE TRIGGER push_leave_enqueue AFTER INSERT OR UPDATE OF status ON crew_leave FOR EACH ROW EXECUTE FUNCTION push_leave_enqueue();

CREATE OR REPLACE FUNCTION push_message_enqueue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v_user uuid; m crew_messages;
BEGIN
  BEGIN
    SELECT d.user_id INTO v_user FROM crew_directory d WHERE d.id = NEW.crew_id;
    IF v_user IS NULL OR NOT push_pref_allows(v_user, 'message')
       OR NOT EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.user_id = v_user) THEN RETURN NULL; END IF;
    SELECT * INTO m FROM crew_messages WHERE id = NEW.message_id;
    INSERT INTO push_queue (tenant_id, user_id, kind, title, body)
    VALUES (m.tenant_id, v_user, 'message', left(m.subject, 80),
            left(m.body, 140) || CASE WHEN m.requires_ack THEN ' (please acknowledge)' ELSE '' END);
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END; $$;
DROP TRIGGER IF EXISTS push_message_enqueue ON crew_message_recipients;
CREATE TRIGGER push_message_enqueue AFTER INSERT ON crew_message_recipients FOR EACH ROW EXECUTE FUNCTION push_message_enqueue();

-- ---------------------------------------------------------------------------
-- Service role: claim / mark for the send-push function
--   Roster changes for one person are merged into a single notification.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION push_claim_batch(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_jobs jsonb := '[]'::jsonb; v_lim int := LEAST(GREATEST(COALESCE(p_limit,50),1),200);
  r record; v_subs jsonb; v_ids uuid[]; v_title text; v_body text; v_n int;
BEGIN
  UPDATE push_queue SET state = 'queued' WHERE state = 'sending' AND locked_at < now() - interval '10 minutes';
  -- anything older than a day is no longer news
  UPDATE push_queue SET state = 'failed', last_error = 'expired' WHERE state = 'queued' AND created_at < now() - interval '1 day';

  FOR r IN
    SELECT q.user_id, (q.kind = 'roster_change') AS merged FROM push_queue q
     WHERE q.state = 'queued' AND q.send_after <= now()
     GROUP BY q.user_id, (q.kind = 'roster_change') ORDER BY min(q.created_at) LIMIT v_lim
  LOOP
    WITH c AS (
      SELECT q.id FROM push_queue q
       WHERE q.user_id = r.user_id AND q.state = 'queued' AND q.send_after <= now() AND ((q.kind = 'roster_change') = r.merged)
       ORDER BY q.created_at FOR UPDATE SKIP LOCKED
    ), u AS (
      UPDATE push_queue q SET state = 'sending', attempts = q.attempts + 1, locked_at = now() FROM c WHERE q.id = c.id RETURNING q.*
    )
    SELECT array_agg(u.id ORDER BY u.created_at), count(*)::int, (array_agg(u.title ORDER BY u.created_at))[1],
           (array_agg(u.body ORDER BY u.created_at DESC))[1]
      INTO v_ids, v_n, v_title, v_body FROM u;
    CONTINUE WHEN v_ids IS NULL;
    IF r.merged AND v_n > 1 THEN v_body := v_n || ' roster updates. Latest: ' || v_body; END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]'::jsonb)
      INTO v_subs FROM push_subscriptions s WHERE s.user_id = r.user_id;
    v_jobs := v_jobs || jsonb_build_object('ids', to_jsonb(v_ids), 'title', v_title, 'body', v_body,
                                           'tag', CASE WHEN r.merged THEN 'roster' ELSE 'msg-' || v_ids[1]::text END, 'subs', v_subs);
  END LOOP;
  RETURN v_jobs;
END; $$;
REVOKE ALL ON FUNCTION push_claim_batch(int) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION push_mark(p_ids uuid[], p_state text, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF p_state = 'sent' THEN
    UPDATE push_queue SET state = 'sent', locked_at = NULL, last_error = NULL WHERE id = ANY(p_ids);
  ELSIF p_state = 'retry' THEN
    UPDATE push_queue SET locked_at = NULL, last_error = left(p_error, 300),
           state = CASE WHEN attempts >= 3 THEN 'failed' ELSE 'queued' END,
           send_after = now() + make_interval(mins => attempts * 2) WHERE id = ANY(p_ids);
  ELSE
    UPDATE push_queue SET state = 'failed', locked_at = NULL, last_error = left(p_error, 300) WHERE id = ANY(p_ids);
  END IF;
END; $$;
REVOKE ALL ON FUNCTION push_mark(uuid[], text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION push_sub_result(p_id uuid, p_gone boolean)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  WITH d AS (DELETE FROM push_subscriptions WHERE id = p_id AND p_gone RETURNING 1)
  UPDATE push_subscriptions SET last_ok_at = now() WHERE id = p_id AND NOT p_gone;
$$;
REVOKE ALL ON FUNCTION push_sub_result(uuid, boolean) FROM PUBLIC, anon, authenticated;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION cal_feed(text) TO service_role;
    GRANT EXECUTE ON FUNCTION push_claim_batch(int) TO service_role;
    GRANT EXECUTE ON FUNCTION push_mark(uuid[], text, text) TO service_role;
    GRANT EXECUTE ON FUNCTION push_sub_result(uuid, boolean) TO service_role;
  END IF;
  IF to_regprocedure('push_claim_batch(int)') IS NULL OR to_regprocedure('cal_feed(text)') IS NULL THEN
    RAISE EXCEPTION 'Migration 31: objects not found';
  END IF;
  RAISE NOTICE 'Migration 31 verified: calendar feed and push notifications ready.';
END $$;
