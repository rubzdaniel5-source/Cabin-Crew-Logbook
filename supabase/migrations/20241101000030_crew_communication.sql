-- =============================================================================
-- Migration: 20241101000030_crew_communication.sql
-- Description: Crew Directory, phase 3a — communication.
--
--   crew_comm_prefs         – each crew member's email preferences
--   crew_messages           – a message from an officer to one crew member or a group
--   crew_message_recipients – who it reached, who read it, who acknowledged it
--   email_queue             – outgoing email (roster changes, messages, leave decisions)
--
--   Officers / admins:  msg_audience_count, msg_send, msg_list, msg_detail
--   Crew (own only):    msg_my_list, msg_my_unread_count, msg_my_mark_read, msg_my_ack,
--                       comm_prefs_get, comm_prefs_set
--   Service role only:  email_claim_batch, email_mark   (used by the send-emails Edge Function)
--
--   Triggers queue an email when
--     • a roster OFFICER changes a crew member's duty (batched into one digest, ~5 min),
--     • an officer decides / records leave for a crew member with an account.
--   A queueing problem never blocks the roster change itself.
--
-- Nothing is sent until the send-emails Edge Function is deployed and scheduled
-- (see supabase/functions/send-emails/README.md). Until then mail simply waits.
-- Requires migrations 17, 28 and 29. Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('crew_leave') IS NULL OR to_regclass('roster_duty_changes') IS NULL
     OR to_regprocedure('leave_my_crew_id()') IS NULL THEN
    RAISE EXCEPTION 'Migration 30 requires migrations 17, 28 and 29.';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crew_comm_prefs (
  user_id         uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  email_roster    boolean NOT NULL DEFAULT true,
  email_messages  boolean NOT NULL DEFAULT true,
  email_leave     boolean NOT NULL DEFAULT true,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE crew_comm_prefs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON crew_comm_prefs FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS email_queue (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE CASCADE,
  kind        text        NOT NULL CHECK (kind IN ('roster_change','message','leave_decision')),
  user_id     uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  to_email    text        NOT NULL,
  to_name     text,
  payload     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  state       text        NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','sending','sent','failed')),
  attempts    int         NOT NULL DEFAULT 0,
  send_after  timestamptz NOT NULL DEFAULT now(),
  locked_at   timestamptz,
  last_error  text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz
);
CREATE INDEX IF NOT EXISTS email_queue_due ON email_queue (state, send_after);
CREATE INDEX IF NOT EXISTS email_queue_to  ON email_queue (kind, to_email) WHERE state = 'queued';
ALTER TABLE email_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON email_queue FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS crew_messages (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE CASCADE,
  sender_id     uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  sender_name   text,
  subject       text        NOT NULL,
  body          text        NOT NULL,
  audience      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  audience_label text,
  requires_ack  boolean     NOT NULL DEFAULT false,
  send_email    boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS crew_messages_tenant ON crew_messages (tenant_id, created_at DESC);
ALTER TABLE crew_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON crew_messages FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS crew_message_recipients (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id  uuid        NOT NULL REFERENCES crew_messages(id) ON DELETE CASCADE,
  crew_id     uuid        NOT NULL REFERENCES crew_directory(id) ON DELETE CASCADE,
  email_to    text,
  queue_id    uuid        REFERENCES email_queue(id) ON DELETE SET NULL,
  read_at     timestamptz,
  ack_at      timestamptz,
  UNIQUE (message_id, crew_id)
);
CREATE INDEX IF NOT EXISTS crew_msg_rcpt_crew ON crew_message_recipients (crew_id, message_id);
ALTER TABLE crew_message_recipients ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON crew_message_recipients FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers
-- ---------------------------------------------------------------------------
-- Email address we would use for a crew member: the account's (verified) address first
CREATE OR REPLACE FUNCTION crew_effective_email(p_crew uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE(NULLIF(btrim(p.email), ''), NULLIF(btrim(d.email), ''))
    FROM crew_directory d LEFT JOIN profiles p ON p.id = d.user_id
   WHERE d.id = p_crew;
$$;
REVOKE ALL ON FUNCTION crew_effective_email(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION crew_pref_allows(p_user uuid, p_kind text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE((SELECT CASE p_kind WHEN 'roster' THEN c.email_roster WHEN 'messages' THEN c.email_messages
                                       WHEN 'leave' THEN c.email_leave ELSE true END
                     FROM crew_comm_prefs c WHERE c.user_id = p_user), true);
$$;
REVOKE ALL ON FUNCTION crew_pref_allows(uuid, text) FROM PUBLIC, anon, authenticated;

-- Who an audience description reaches. Never archived or resigned crew.
--   {"mode":"all"|"crew", "crew_ids":[uuid…], "base":"EBB", "rank":"SCCM", "only_accounts":true}
CREATE OR REPLACE FUNCTION msg_resolve(p_tenant uuid, p_aud jsonb)
RETURNS SETOF crew_directory
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT d.* FROM crew_directory d
   WHERE d.tenant_id = p_tenant AND d.archived_at IS NULL AND d.status <> 'resigned'
     AND ( COALESCE(p_aud->>'mode', 'all') <> 'crew'
           OR d.id IN (SELECT e::uuid FROM jsonb_array_elements_text(COALESCE(p_aud->'crew_ids', '[]'::jsonb)) e) )
     AND ( NULLIF(p_aud->>'base', '') IS NULL OR d.base = upper(p_aud->>'base') )
     AND ( NULLIF(p_aud->>'rank', '') IS NULL OR d.rank = p_aud->>'rank' )
     AND ( COALESCE((p_aud->>'only_accounts')::boolean, false) = false OR d.user_id IS NOT NULL );
$$;
REVOKE ALL ON FUNCTION msg_resolve(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Crew email preferences
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS comm_prefs_get();
CREATE FUNCTION comm_prefs_get()
RETURNS TABLE (email_roster boolean, email_messages boolean, email_leave boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE(c.email_roster, true), COALESCE(c.email_messages, true), COALESCE(c.email_leave, true)
    FROM (SELECT 1) x LEFT JOIN crew_comm_prefs c ON c.user_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION comm_prefs_get() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION comm_prefs_get() TO authenticated;

CREATE OR REPLACE FUNCTION comm_prefs_set(p_roster boolean, p_messages boolean, p_leave boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  INSERT INTO crew_comm_prefs (user_id, email_roster, email_messages, email_leave, updated_at)
  VALUES (auth.uid(), COALESCE(p_roster, true), COALESCE(p_messages, true), COALESCE(p_leave, true), now())
  ON CONFLICT (user_id) DO UPDATE
    SET email_roster = EXCLUDED.email_roster, email_messages = EXCLUDED.email_messages,
        email_leave = EXCLUDED.email_leave, updated_at = now();
END;
$$;
REVOKE ALL ON FUNCTION comm_prefs_set(boolean, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION comm_prefs_set(boolean, boolean, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Officer side: audience preview, send, history, detail
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS msg_audience_count(jsonb);
CREATE FUNCTION msg_audience_count(p_audience jsonb)
RETURNS TABLE (total int, with_account int, with_email int)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can send messages.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT count(*)::int,
         count(*) FILTER (WHERE a.user_id IS NOT NULL)::int,
         count(*) FILTER (WHERE crew_effective_email(a.id) IS NOT NULL)::int
    FROM msg_resolve(v_tenant, COALESCE(p_audience, '{}'::jsonb)) a;
END;
$$;
REVOKE ALL ON FUNCTION msg_audience_count(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_audience_count(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION msg_send(p_subject text, p_body text, p_audience jsonb,
                                    p_requires_ack boolean DEFAULT false, p_email boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_subject text := btrim(COALESCE(p_subject, ''));
  v_body    text := btrim(COALESCE(p_body, ''));
  v_aud     jsonb := COALESCE(p_audience, '{}'::jsonb);
  v_sender  text;
  v_label   text;
  v_msg     uuid;
  v_n int := 0; v_acct int := 0; v_mail int := 0;
  d crew_directory;
  v_email text;
  v_q uuid;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can send messages.' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(v_aud) <> 'object' THEN RAISE EXCEPTION 'Choose who the message is for.' USING ERRCODE = '22023'; END IF;
  IF v_subject = '' OR length(v_subject) > 120 THEN RAISE EXCEPTION 'Add a subject (up to 120 characters).' USING ERRCODE = '22023'; END IF;
  IF v_body = '' OR length(v_body) > 4000 THEN RAISE EXCEPTION 'Write the message (up to 4000 characters).' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM msg_resolve(v_tenant, v_aud)) = 0 THEN
    RAISE EXCEPTION 'Nobody matches that audience.' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM msg_resolve(v_tenant, v_aud)) > 500 THEN
    RAISE EXCEPTION 'A message can reach at most 500 crew. Narrow the audience.' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM crew_messages m WHERE m.sender_id = auth.uid() AND m.created_at > now() - interval '1 hour') >= 20 THEN
    RAISE EXCEPTION 'That is a lot of messages in an hour. Please wait a little.' USING ERRCODE = '54000';
  END IF;

  SELECT full_name INTO v_sender FROM profiles WHERE id = auth.uid();
  v_label := CASE
    WHEN COALESCE(v_aud->>'mode', 'all') = 'crew' THEN
      CASE WHEN jsonb_array_length(COALESCE(v_aud->'crew_ids', '[]'::jsonb)) = 1
           THEN (SELECT x.full_name FROM crew_directory x WHERE x.id = (v_aud->'crew_ids'->>0)::uuid)
           ELSE jsonb_array_length(COALESCE(v_aud->'crew_ids', '[]'::jsonb)) || ' selected crew' END
    ELSE concat_ws(' · ', 'All crew', NULLIF('base ' || COALESCE(v_aud->>'base', ''), 'base '),
                   NULLIF('rank ' || COALESCE(v_aud->>'rank', ''), 'rank '),
                   CASE WHEN COALESCE((v_aud->>'only_accounts')::boolean, false) THEN 'with accounts' END) END;

  INSERT INTO crew_messages (tenant_id, sender_id, sender_name, subject, body, audience, audience_label, requires_ack, send_email)
  VALUES (v_tenant, auth.uid(), v_sender, v_subject, v_body, v_aud, v_label, COALESCE(p_requires_ack, false), COALESCE(p_email, true))
  RETURNING id INTO v_msg;

  FOR d IN SELECT * FROM msg_resolve(v_tenant, v_aud) LOOP
    v_n := v_n + 1; v_q := NULL;
    IF d.user_id IS NOT NULL THEN v_acct := v_acct + 1; END IF;
    v_email := crew_effective_email(d.id);
    IF COALESCE(p_email, true) AND v_email IS NOT NULL
       AND (d.user_id IS NULL OR crew_pref_allows(d.user_id, 'messages')) THEN
      INSERT INTO email_queue (tenant_id, kind, user_id, to_email, to_name, payload)
      VALUES (v_tenant, 'message', d.user_id, v_email, d.full_name,
              jsonb_build_object('subject', v_subject, 'body', v_body, 'sender_name', v_sender,
                                 'requires_ack', COALESCE(p_requires_ack, false), 'message_id', v_msg,
                                 'has_account', d.user_id IS NOT NULL))
      RETURNING id INTO v_q;
      v_mail := v_mail + 1;
    END IF;
    INSERT INTO crew_message_recipients (message_id, crew_id, email_to, queue_id)
    VALUES (v_msg, d.id, v_email, v_q);
  END LOOP;

  PERFORM crew_dir_log('message_sent', v_msg, v_subject,
    jsonb_build_object('audience', v_label, 'recipients', v_n, 'emails', v_mail, 'requires_ack', COALESCE(p_requires_ack, false)));
  RETURN jsonb_build_object('id', v_msg, 'recipients', v_n, 'with_account', v_acct, 'emails_queued', v_mail);
END;
$$;
REVOKE ALL ON FUNCTION msg_send(text, text, jsonb, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_send(text, text, jsonb, boolean, boolean) TO authenticated;

DROP FUNCTION IF EXISTS msg_list(int);
CREATE FUNCTION msg_list(p_limit int DEFAULT 30)
RETURNS TABLE (id uuid, subject text, body text, sender_name text, audience_label text, requires_ack boolean,
               send_email boolean, created_at timestamptz, recipients int, with_account int,
               read_count int, ack_count int, emails_sent int, emails_failed int)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can send messages.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT m.id, m.subject, m.body, m.sender_name, m.audience_label, m.requires_ack, m.send_email, m.created_at,
         count(r.id)::int,
         count(r.id) FILTER (WHERE d.user_id IS NOT NULL)::int,
         count(r.read_at)::int,
         count(r.ack_at)::int,
         count(q.id) FILTER (WHERE q.state = 'sent')::int,
         count(q.id) FILTER (WHERE q.state = 'failed')::int
    FROM crew_messages m
    LEFT JOIN crew_message_recipients r ON r.message_id = m.id
    LEFT JOIN crew_directory d ON d.id = r.crew_id
    LEFT JOIN email_queue q ON q.id = r.queue_id
   WHERE m.tenant_id = v_tenant
   GROUP BY m.id
   ORDER BY m.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
END;
$$;
REVOKE ALL ON FUNCTION msg_list(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_list(int) TO authenticated;

DROP FUNCTION IF EXISTS msg_detail(uuid);
CREATE FUNCTION msg_detail(p_id uuid)
RETURNS TABLE (crew_id uuid, full_name text, crew_code text, has_account boolean, email_to text,
               email_state text, read_at timestamptz, ack_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can send messages.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM crew_messages m WHERE m.id = p_id AND m.tenant_id = v_tenant) THEN
    RAISE EXCEPTION 'Message not found.' USING ERRCODE = 'P0002';
  END IF;
  RETURN QUERY
  SELECT d.id, d.full_name, d.crew_code, d.user_id IS NOT NULL, r.email_to,
         COALESCE(q.state, CASE WHEN r.email_to IS NULL THEN 'no email' ELSE 'not sent' END),
         r.read_at, r.ack_at
    FROM crew_message_recipients r
    JOIN crew_directory d ON d.id = r.crew_id
    LEFT JOIN email_queue q ON q.id = r.queue_id
   WHERE r.message_id = p_id
   ORDER BY (r.ack_at IS NULL), (r.read_at IS NULL), lower(d.full_name);
END;
$$;
REVOKE ALL ON FUNCTION msg_detail(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_detail(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Crew side: inbox
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS msg_my_list();
CREATE FUNCTION msg_my_list()
RETURNS TABLE (id uuid, subject text, body text, sender_name text, created_at timestamptz,
               requires_ack boolean, read_at timestamptz, ack_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_crew uuid := leave_my_crew_id();
BEGIN
  IF v_crew IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT r.id, m.subject, m.body, m.sender_name, m.created_at, m.requires_ack, r.read_at, r.ack_at
    FROM crew_message_recipients r JOIN crew_messages m ON m.id = r.message_id
   WHERE r.crew_id = v_crew
   ORDER BY m.created_at DESC
   LIMIT 50;
END;
$$;
REVOKE ALL ON FUNCTION msg_my_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_my_list() TO authenticated;

CREATE OR REPLACE FUNCTION msg_my_unread_count()
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT count(*)::int FROM crew_message_recipients r
   WHERE r.crew_id = leave_my_crew_id() AND r.read_at IS NULL;
$$;
REVOKE ALL ON FUNCTION msg_my_unread_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_my_unread_count() TO authenticated;

CREATE OR REPLACE FUNCTION msg_my_mark_read(p_ids uuid[])
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  UPDATE crew_message_recipients SET read_at = now()
   WHERE crew_id = leave_my_crew_id() AND read_at IS NULL AND id = ANY(COALESCE(p_ids, ARRAY[]::uuid[]));
$$;
REVOKE ALL ON FUNCTION msg_my_mark_read(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_my_mark_read(uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION msg_my_ack(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_crew uuid := leave_my_crew_id();
BEGIN
  IF v_crew IS NULL OR NOT EXISTS (SELECT 1 FROM crew_message_recipients r WHERE r.id = p_id AND r.crew_id = v_crew) THEN
    RAISE EXCEPTION 'Not found.' USING ERRCODE = 'P0002';
  END IF;
  UPDATE crew_message_recipients SET ack_at = COALESCE(ack_at, now()), read_at = COALESCE(read_at, now()) WHERE id = p_id;
END;
$$;
REVOKE ALL ON FUNCTION msg_my_ack(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION msg_my_ack(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Queue triggers — never allowed to break the action that caused them
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_change_enqueue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_owner uuid; v_email text; v_name text; v_blocked boolean; v_duty roster_duties;
BEGIN
  IF NEW.source <> 'officer' OR NEW.change_type IN ('completed', 'diverted') THEN RETURN NULL; END IF;
  BEGIN
    SELECT r.crew_user_id INTO v_owner FROM crew_rosters r WHERE r.id = NEW.roster_id;
    IF v_owner IS NULL OR v_owner IS NOT DISTINCT FROM NEW.changed_by THEN RETURN NULL; END IF;
    SELECT NULLIF(btrim(p.email), ''), COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), '')), p.blocked IS TRUE
      INTO v_email, v_name, v_blocked FROM profiles p WHERE p.id = v_owner;
    IF v_email IS NULL OR v_blocked OR NOT crew_pref_allows(v_owner, 'roster') THEN RETURN NULL; END IF;
    SELECT * INTO v_duty FROM roster_duties d WHERE d.id = NEW.duty_id;
    INSERT INTO email_queue (tenant_id, kind, user_id, to_email, to_name, payload, send_after)
    VALUES (NEW.tenant_id, 'roster_change', v_owner, v_email, v_name,
            jsonb_build_object('change_type', NEW.change_type, 'reason', NEW.reason, 'old', NEW.old_values, 'new', NEW.new_values,
                               'duty_date', v_duty.duty_date, 'duty_type', v_duty.duty_type, 'flight', v_duty.flight_number,
                               'origin', v_duty.origin, 'destination', v_duty.destination, 'std_local', v_duty.std_local,
                               'changed_at', NEW.changed_at),
            now() + interval '5 minutes');
  EXCEPTION WHEN others THEN
    NULL;
  END;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS roster_change_enqueue ON roster_duty_changes;
CREATE TRIGGER roster_change_enqueue
  AFTER INSERT ON roster_duty_changes
  FOR EACH ROW EXECUTE FUNCTION roster_change_enqueue();

CREATE OR REPLACE FUNCTION leave_decision_enqueue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  d crew_directory; v_email text;
BEGIN
  IF NEW.status NOT IN ('approved', 'declined', 'cancelled') OR NEW.decision_seen IS DISTINCT FROM false THEN RETURN NULL; END IF;
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;
  IF TG_OP = 'INSERT' AND NEW.via <> 'officer' THEN RETURN NULL; END IF;
  BEGIN
    SELECT * INTO d FROM crew_directory x WHERE x.id = NEW.crew_id;
    IF d.user_id IS NULL OR NOT crew_pref_allows(d.user_id, 'leave') THEN RETURN NULL; END IF;
    v_email := crew_effective_email(d.id);
    IF v_email IS NULL THEN RETURN NULL; END IF;
    INSERT INTO email_queue (tenant_id, kind, user_id, to_email, to_name, payload)
    VALUES (NEW.tenant_id, 'leave_decision', d.user_id, v_email, d.full_name,
            jsonb_build_object('kind', NEW.kind, 'from', NEW.start_date, 'to', NEW.end_date, 'status', NEW.status,
                               'note', NEW.decision_note, 'recorded_by_officer', NEW.via = 'officer'));
  EXCEPTION WHEN others THEN
    NULL;
  END;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS leave_decision_enqueue ON crew_leave;
CREATE TRIGGER leave_decision_enqueue
  AFTER INSERT OR UPDATE OF status ON crew_leave
  FOR EACH ROW EXECUTE FUNCTION leave_decision_enqueue();

-- ---------------------------------------------------------------------------
-- 7. Service-role functions for the send-emails Edge Function
--    email_claim_batch: roster changes are merged into ONE digest per person
--    (once the oldest has waited out its 5-minute window); everything else is one email each.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION email_claim_batch(p_limit int DEFAULT 25)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_jobs jsonb := '[]'::jsonb;
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_left  int;
  r record;
  v_ids uuid[];
BEGIN
  -- a worker that died mid-send: let its rows be tried again
  UPDATE email_queue SET state = 'queued' WHERE state = 'sending' AND locked_at < now() - interval '10 minutes';

  FOR r IN
    SELECT q.to_email FROM email_queue q
     WHERE q.kind = 'roster_change' AND q.state = 'queued' AND q.send_after <= now()
     GROUP BY q.to_email ORDER BY min(q.send_after) LIMIT v_limit
  LOOP
    WITH c AS (
      SELECT q.id FROM email_queue q
       WHERE q.kind = 'roster_change' AND q.state = 'queued' AND q.to_email = r.to_email
       ORDER BY q.created_at FOR UPDATE SKIP LOCKED
    ), u AS (
      UPDATE email_queue q SET state = 'sending', attempts = q.attempts + 1, locked_at = now()
        FROM c WHERE q.id = c.id RETURNING q.*
    )
    SELECT array_agg(u.id ORDER BY u.created_at) INTO v_ids FROM u;
    IF v_ids IS NOT NULL THEN
      v_jobs := v_jobs || (
        SELECT jsonb_build_object('kind', 'roster_change', 'ids', to_jsonb(v_ids), 'to_email', min(q.to_email), 'to_name', min(q.to_name),
                                  'items', jsonb_agg(q.payload ORDER BY q.created_at))
          FROM email_queue q WHERE q.id = ANY(v_ids));
    END IF;
  END LOOP;

  v_left := v_limit - jsonb_array_length(v_jobs);
  IF v_left > 0 THEN
    FOR r IN
      WITH c AS (
        SELECT q.id FROM email_queue q
         WHERE q.kind <> 'roster_change' AND q.state = 'queued' AND q.send_after <= now()
         ORDER BY q.created_at LIMIT v_left FOR UPDATE SKIP LOCKED
      ), u AS (
        UPDATE email_queue q SET state = 'sending', attempts = q.attempts + 1, locked_at = now()
          FROM c WHERE q.id = c.id RETURNING q.*
      )
      SELECT * FROM u ORDER BY u.created_at
    LOOP
      v_jobs := v_jobs || jsonb_build_object('kind', r.kind, 'ids', jsonb_build_array(r.id), 'to_email', r.to_email,
                                             'to_name', r.to_name, 'items', jsonb_build_array(r.payload));
    END LOOP;
  END IF;
  RETURN v_jobs;
END;
$$;
REVOKE ALL ON FUNCTION email_claim_batch(int) FROM PUBLIC, anon, authenticated;

-- state: 'sent' | 'retry' (try again later, up to 3 attempts) | 'failed' (give up now)
CREATE OR REPLACE FUNCTION email_mark(p_ids uuid[], p_state text, p_error text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF p_state = 'sent' THEN
    UPDATE email_queue SET state = 'sent', sent_at = now(), last_error = NULL, locked_at = NULL WHERE id = ANY(p_ids);
  ELSIF p_state = 'retry' THEN
    UPDATE email_queue SET locked_at = NULL, last_error = left(p_error, 500),
           state = CASE WHEN attempts >= 3 THEN 'failed' ELSE 'queued' END,
           send_after = now() + make_interval(mins => attempts * 10)
     WHERE id = ANY(p_ids);
  ELSE
    UPDATE email_queue SET state = 'failed', locked_at = NULL, last_error = left(p_error, 500) WHERE id = ANY(p_ids);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION email_mark(uuid[], text, text) FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION email_claim_batch(int) TO service_role;
    GRANT EXECUTE ON FUNCTION email_mark(uuid[], text, text) TO service_role;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Verification
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('email_queue') IS NULL OR to_regprocedure('msg_send(text,text,jsonb,boolean,boolean)') IS NULL
     OR to_regprocedure('email_claim_batch(int)') IS NULL OR to_regprocedure('msg_my_ack(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Migration 30: objects not found';
  END IF;
  RAISE NOTICE 'Migration 30 verified: messages, inbox, email preferences and email queue ready.';
END;
$$;
