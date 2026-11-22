-- =============================================================================
-- Migration: 20241101000033_passenger_feedback_backend.sql
-- Description: Passenger Feedback — server side for the passenger PWA (ug-feedback)
--   * passenger_feedback table (created if missing, extended if it exists)
--   * Anonymous submissions go through feedback_submit() — validated and rate limited
--     (the old direct insert keeps working and passes through the same checks)
--   * Every submission is emailed (via the email queue) to the recipients configured in
--     Passenger Feedback → Recipients: operations/cabin crew manager always, plus
--     complaints → catering, safety, engineering, HR; compliments → marketing;
--     suggestions → quality; urgent (complaint rated 1–2★) → senior management
--   * Urgent complaints also push-notify admins and ops managers
--   * Reading goes through feedback_list(): managers (admin, ops manager) see everything;
--     crew see only feedback for their own flights, with the passenger's email hidden
--   * feedback_set_status() / feedback_stats() for managers
--   * Direct SELECT on the table is revoked from the browser roles
-- Requires migrations 30, 31 and 32. Safe to re-run.
-- =============================================================================
DO $$ BEGIN
  IF to_regclass('email_queue') IS NULL OR to_regclass('push_queue') IS NULL THEN
    RAISE EXCEPTION 'Migration 33 requires migrations 30 and 31.';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS passenger_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  flight_number text, flight_date date, route text,
  passenger_name text, passenger_email text, seat_number text,
  feedback_type text, overall_rating int,
  rating_crew int, rating_food int, rating_comfort int, rating_cleanliness int,
  rating_entertainment int, rating_ground int,
  comments text, device_id text
);
ALTER TABLE passenger_feedback ADD COLUMN IF NOT EXISTS tenant_id     uuid REFERENCES guestora_tenants(id);
ALTER TABLE passenger_feedback ADD COLUMN IF NOT EXISTS flight_key    text;
ALTER TABLE passenger_feedback ADD COLUMN IF NOT EXISTS is_urgent     boolean NOT NULL DEFAULT false;
ALTER TABLE passenger_feedback ADD COLUMN IF NOT EXISTS status        text NOT NULL DEFAULT 'new';
ALTER TABLE passenger_feedback ADD COLUMN IF NOT EXISTS internal_note text;
ALTER TABLE passenger_feedback ADD COLUMN IF NOT EXISTS handled_by    uuid REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE passenger_feedback ADD COLUMN IF NOT EXISTS handled_at    timestamptz;
CREATE INDEX IF NOT EXISTS pf_flight_key ON passenger_feedback (flight_key, flight_date);
CREATE INDEX IF NOT EXISTS pf_created    ON passenger_feedback (created_at DESC);
CREATE INDEX IF NOT EXISTS pf_device     ON passenger_feedback (device_id, created_at) WHERE device_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS pf_email      ON passenger_feedback (passenger_email, created_at);

ALTER TABLE passenger_feedback ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pf_insert_any ON passenger_feedback;
CREATE POLICY pf_insert_any ON passenger_feedback FOR INSERT TO anon, authenticated WITH CHECK (true);
GRANT INSERT ON passenger_feedback TO anon, authenticated;
-- Reading happens only through feedback_list() (role-aware, hides passenger emails from crew)
REVOKE SELECT, UPDATE, DELETE ON passenger_feedback FROM anon, authenticated;

-- Email kind for the queue
ALTER TABLE email_queue DROP CONSTRAINT IF EXISTS email_queue_kind_check;
ALTER TABLE email_queue ADD CONSTRAINT email_queue_kind_check
  CHECK (kind IN ('roster_change','message','leave_decision','feedback'));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pf_flight_key(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(split_part(upper(regexp_replace(COALESCE(p, ''), '\s', '', 'g')), '/', 1), '');
$$;

CREATE OR REPLACE FUNCTION pf_is_manager() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
  SELECT COALESCE((SELECT (p.is_admin IS TRUE OR p.role IN ('admin','ops_manager')) AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false);
$$;
REVOKE ALL ON FUNCTION pf_is_manager() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION pf_default_tenant() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$ SELECT id FROM guestora_tenants WHERE slug = 'uganda-airlines' LIMIT 1; $$;
REVOKE ALL ON FUNCTION pf_default_tenant() FROM PUBLIC, anon, authenticated;

-- The recipients JSON saved by the app (stored as text or jsonb, possibly double encoded)
CREATE OR REPLACE FUNCTION pf_recipients() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE v text; j jsonb;
BEGIN
  BEGIN
    EXECUTE 'SELECT value::text FROM app_config WHERE key = $1 LIMIT 1' INTO v USING 'feedback_recipients';
    IF v IS NULL THEN RETURN '{}'::jsonb; END IF;
    j := v::jsonb;
    IF jsonb_typeof(j) = 'string' THEN j := (j #>> '{}')::jsonb; END IF;
    IF jsonb_typeof(j) <> 'object' THEN RETURN '{}'::jsonb; END IF;
    RETURN j;
  EXCEPTION WHEN others THEN
    RETURN '{}'::jsonb;
  END;
END;
$$;
REVOKE ALL ON FUNCTION pf_recipients() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- BEFORE INSERT: tidy, validate, rate limit, classify
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pf_before_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE c int;
BEGIN
  NEW.passenger_name  := left(btrim(COALESCE(NEW.passenger_name, '')), 120);
  NEW.passenger_email := left(lower(btrim(COALESCE(NEW.passenger_email, ''))), 200);
  NEW.seat_number     := NULLIF(left(upper(btrim(COALESCE(NEW.seat_number, ''))), 6), '');
  NEW.flight_number   := NULLIF(left(upper(regexp_replace(COALESCE(NEW.flight_number, ''), '\s', '', 'g')), 12), '');
  NEW.route           := NULLIF(left(btrim(COALESCE(NEW.route, '')), 40), '');
  NEW.comments        := NULLIF(left(btrim(COALESCE(NEW.comments, '')), 4000), '');
  NEW.device_id       := NULLIF(left(COALESCE(NEW.device_id, ''), 60), '');

  IF NEW.passenger_name = '' THEN RAISE EXCEPTION 'Please enter your name.' USING ERRCODE = '22023'; END IF;
  IF NEW.passenger_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'Please enter a valid email address.' USING ERRCODE = '22023'; END IF;
  IF NEW.feedback_type IS NULL OR NEW.feedback_type NOT IN ('compliment','complaint','suggestion') THEN
    RAISE EXCEPTION 'Please choose a type of feedback.' USING ERRCODE = '22023';
  END IF;
  IF NEW.overall_rating IS NULL OR NEW.overall_rating NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION 'Please rate your overall experience.' USING ERRCODE = '22023';
  END IF;
  IF NEW.rating_crew NOT BETWEEN 1 AND 5 THEN NEW.rating_crew := NULL; END IF;
  IF NEW.rating_food NOT BETWEEN 1 AND 5 THEN NEW.rating_food := NULL; END IF;
  IF NEW.rating_comfort NOT BETWEEN 1 AND 5 THEN NEW.rating_comfort := NULL; END IF;
  IF NEW.rating_cleanliness NOT BETWEEN 1 AND 5 THEN NEW.rating_cleanliness := NULL; END IF;
  IF NEW.rating_entertainment NOT BETWEEN 1 AND 5 THEN NEW.rating_entertainment := NULL; END IF;
  IF NEW.rating_ground NOT BETWEEN 1 AND 5 THEN NEW.rating_ground := NULL; END IF;
  IF NEW.flight_date IS NOT NULL AND (NEW.flight_date < current_date - 120 OR NEW.flight_date > current_date + 2) THEN
    NEW.flight_date := NULL;
  END IF;

  -- Flood protection: per device and per email address
  IF NEW.device_id IS NOT NULL THEN
    SELECT count(*) INTO c FROM passenger_feedback WHERE device_id = NEW.device_id AND created_at > now() - interval '1 hour';
    IF c >= 5 THEN RAISE EXCEPTION 'You have sent several messages already. Please try again later.' USING ERRCODE = '54000'; END IF;
  END IF;
  SELECT count(*) INTO c FROM passenger_feedback WHERE passenger_email = NEW.passenger_email AND created_at > now() - interval '1 hour';
  IF c >= 5 THEN RAISE EXCEPTION 'You have sent several messages already. Please try again later.' USING ERRCODE = '54000'; END IF;

  NEW.flight_key := pf_flight_key(NEW.flight_number);
  NEW.is_urgent  := NEW.feedback_type = 'complaint' AND NEW.overall_rating <= 2;
  NEW.status     := 'new';
  NEW.handled_by := NULL; NEW.handled_at := NULL; NEW.internal_note := NULL;
  NEW.tenant_id  := COALESCE(NEW.tenant_id, pf_default_tenant());
  NEW.created_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS pf_before_insert ON passenger_feedback;
CREATE TRIGGER pf_before_insert BEFORE INSERT ON passenger_feedback FOR EACH ROW EXECUTE FUNCTION pf_before_insert();

-- Existing rows
UPDATE passenger_feedback SET tenant_id = pf_default_tenant() WHERE tenant_id IS NULL;
UPDATE passenger_feedback SET flight_key = pf_flight_key(flight_number) WHERE flight_key IS NULL AND flight_number IS NOT NULL;
UPDATE passenger_feedback SET is_urgent = (feedback_type = 'complaint' AND overall_rating <= 2) WHERE is_urgent = false;

-- ---------------------------------------------------------------------------
-- AFTER INSERT: email the right departments; push the managers if urgent
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pf_after_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE
  r jsonb := pf_recipients();
  v_keys text[] := ARRAY['ops'];
  k text; v_addr text; v_seen text[] := ARRAY[]::text[];
  v_payload jsonb;
  v_dept jsonb := '{"ops":"Operations / Cabin Crew Manager","catering":"Catering","safety":"Safety","engineering":"Engineering","hr":"Human Resources","marketing":"Marketing","qa":"Quality Assurance","senior":"Senior Management"}';
BEGIN
  BEGIN
    IF NEW.feedback_type = 'complaint' THEN v_keys := v_keys || ARRAY['catering','safety','engineering','hr'];
    ELSIF NEW.feedback_type = 'compliment' THEN v_keys := v_keys || ARRAY['marketing'];
    ELSE v_keys := v_keys || ARRAY['qa'];
    END IF;
    IF NEW.is_urgent THEN v_keys := v_keys || ARRAY['senior']; END IF;

    v_payload := jsonb_build_object(
      'feedback_id', NEW.id, 'type', NEW.feedback_type, 'urgent', NEW.is_urgent, 'overall', NEW.overall_rating,
      'flight', NEW.flight_number, 'flight_date', NEW.flight_date, 'route', NEW.route, 'seat', NEW.seat_number,
      'name', NEW.passenger_name, 'email', NEW.passenger_email, 'comments', NEW.comments,
      'ratings', jsonb_build_object('Cabin crew', NEW.rating_crew, 'Food & beverages', NEW.rating_food, 'Cabin comfort', NEW.rating_comfort,
                                    'Cleanliness', NEW.rating_cleanliness, 'Entertainment', NEW.rating_entertainment, 'Ground service', NEW.rating_ground),
      'reply_to', NEW.passenger_email);

    FOREACH k IN ARRAY v_keys LOOP
      v_addr := lower(btrim(COALESCE(r->>k, '')));
      CONTINUE WHEN v_addr = '' OR v_addr !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR v_addr = ANY(v_seen);
      v_seen := v_seen || v_addr;
      INSERT INTO email_queue (tenant_id, kind, to_email, to_name, payload)
      VALUES (NEW.tenant_id, 'feedback', v_addr, v_dept->>k, v_payload || jsonb_build_object('department', v_dept->>k));
    END LOOP;
  EXCEPTION WHEN others THEN NULL;
  END;

  IF NEW.is_urgent THEN
    BEGIN
      INSERT INTO push_queue (tenant_id, user_id, kind, title, body)
      SELECT NEW.tenant_id, p.id, 'notice', '⚠ Urgent passenger complaint',
             left(concat_ws(' · ', NEW.flight_number, NEW.overall_rating || '★', left(COALESCE(NEW.comments, ''), 90)), 140)
        FROM profiles p
       WHERE p.tenant_id = NEW.tenant_id AND p.blocked IS NOT TRUE AND (p.is_admin IS TRUE OR p.role IN ('admin','ops_manager'))
         AND EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.user_id = p.id)
         AND push_pref_allows(p.id, 'notice');
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS pf_after_insert ON passenger_feedback;
CREATE TRIGGER pf_after_insert AFTER INSERT ON passenger_feedback FOR EACH ROW EXECUTE FUNCTION pf_after_insert();

-- ---------------------------------------------------------------------------
-- Public entry point for the passenger PWA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION feedback_submit(p jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE
  i  int := 0;
  fd date;
  n  text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RAISE EXCEPTION 'Invalid feedback.' USING ERRCODE = '22023'; END IF;
  -- Honeypot: real people never fill the hidden "website" field. Pretend it worked.
  IF COALESCE(btrim(p->>'website'), '') <> '' THEN RETURN 'ok'; END IF;
  BEGIN
    fd := NULLIF(p->>'flight_date', '')::date;
  EXCEPTION WHEN others THEN fd := NULL;
  END;
  BEGIN
    INSERT INTO passenger_feedback (flight_number, flight_date, route, passenger_name, passenger_email, seat_number, feedback_type,
        overall_rating, rating_crew, rating_food, rating_comfort, rating_cleanliness, rating_entertainment, rating_ground, comments, device_id)
    VALUES (p->>'flight_number', fd, p->>'route', p->>'passenger_name', p->>'passenger_email', p->>'seat_number', p->>'feedback_type',
        NULLIF(p->>'overall_rating','')::int, NULLIF(p->>'rating_crew','')::int, NULLIF(p->>'rating_food','')::int,
        NULLIF(p->>'rating_comfort','')::int, NULLIF(p->>'rating_cleanliness','')::int, NULLIF(p->>'rating_entertainment','')::int,
        NULLIF(p->>'rating_ground','')::int, p->>'comments', p->>'device_id');
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'Some answers were not understood. Please check the form.' USING ERRCODE = '22023';
  END;
  RETURN 'ok';
END;
$$;
REVOKE ALL ON FUNCTION feedback_submit(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION feedback_submit(jsonb) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reading (crew app)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS feedback_list(text, text, text, text[], int);
CREATE FUNCTION feedback_list(p_type text DEFAULT NULL, p_rating text DEFAULT NULL, p_status text DEFAULT NULL,
                              p_flights text[] DEFAULT NULL, p_limit int DEFAULT 100)
RETURNS TABLE (id uuid, created_at timestamptz, flight_number text, flight_date date, route text, passenger_name text,
               passenger_email text, seat_number text, feedback_type text, overall_rating int,
               rating_crew int, rating_food int, rating_comfort int, rating_cleanliness int, rating_entertainment int,
               rating_ground int, comments text, is_urgent boolean, status text, internal_note text, handled_at timestamptz,
               can_manage boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_mgr boolean := pf_is_manager();
  v_t uuid := guestora_resolve_tenant_id();
  v_keys text[];
BEGIN
  IF auth.uid() IS NULL OR v_t IS NULL THEN RETURN; END IF;
  IF NOT v_mgr AND COALESCE((SELECT p.role FROM profiles p WHERE p.id = auth.uid()), 'crew') IN ('check_in_agent', 'roster_officer') THEN RETURN; END IF;
  IF NOT v_mgr THEN
    v_keys := ARRAY(
      SELECT DISTINCT pf_flight_key(d.flight_number)
        FROM crew_rosters r JOIN roster_duties d ON d.roster_id = r.id
       WHERE r.crew_user_id = auth.uid() AND d.flight_number IS NOT NULL AND d.duty_date > current_date - 180
      UNION
      SELECT DISTINCT pf_flight_key(f) FROM unnest(COALESCE(p_flights, ARRAY[]::text[])) f WHERE pf_flight_key(f) IS NOT NULL);
  END IF;
  RETURN QUERY
  SELECT f.id, f.created_at, f.flight_number, f.flight_date, f.route,
         CASE WHEN v_mgr THEN f.passenger_name ELSE split_part(f.passenger_name, ' ', 1) END,
         CASE WHEN v_mgr THEN f.passenger_email ELSE NULL END,
         f.seat_number, f.feedback_type, f.overall_rating, f.rating_crew, f.rating_food, f.rating_comfort,
         f.rating_cleanliness, f.rating_entertainment, f.rating_ground, f.comments, f.is_urgent,
         f.status, CASE WHEN v_mgr THEN f.internal_note ELSE NULL END, f.handled_at, v_mgr
    FROM passenger_feedback f
   WHERE f.tenant_id = v_t
     AND (v_mgr OR f.flight_key = ANY(v_keys))
     AND (NULLIF(p_type, '') IS NULL OR f.feedback_type = p_type)
     AND (NULLIF(p_status, '') IS NULL OR f.status = p_status)
     AND (NULLIF(p_rating, '') IS NULL
          OR (p_rating = 'low' AND f.overall_rating < 3)
          OR (p_rating ~ '^[1-5]$' AND f.overall_rating >= p_rating::int))
   ORDER BY f.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
END;
$$;
REVOKE ALL ON FUNCTION feedback_list(text, text, text, text[], int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION feedback_list(text, text, text, text[], int) TO authenticated;

CREATE OR REPLACE FUNCTION feedback_set_status(p_id uuid, p_status text, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NOT pf_is_manager() THEN RAISE EXCEPTION 'Not allowed.' USING ERRCODE = '42501'; END IF;
  IF p_status NOT IN ('new','acknowledged','resolved') THEN RAISE EXCEPTION 'Unknown status.' USING ERRCODE = '22023'; END IF;
  UPDATE passenger_feedback SET status = p_status, handled_by = auth.uid(), handled_at = now(),
         internal_note = CASE WHEN p_note IS NULL THEN internal_note ELSE NULLIF(left(btrim(p_note), 1000), '') END
   WHERE passenger_feedback.id = p_id AND tenant_id = guestora_resolve_tenant_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Feedback not found.' USING ERRCODE = 'P0002'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION feedback_set_status(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION feedback_set_status(uuid, text, text) TO authenticated;

DROP FUNCTION IF EXISTS feedback_stats(int);
CREATE FUNCTION feedback_stats(p_days int DEFAULT 30)
RETURNS TABLE (total int, compliments int, complaints int, suggestions int, urgent_open int, new_count int,
               avg_overall numeric, avg_crew numeric, avg_food numeric, avg_comfort numeric, avg_cleanliness numeric,
               avg_entertainment numeric, avg_ground numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NOT pf_is_manager() THEN RAISE EXCEPTION 'Not allowed.' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT count(*)::int,
         count(*) FILTER (WHERE f.feedback_type = 'compliment')::int,
         count(*) FILTER (WHERE f.feedback_type = 'complaint')::int,
         count(*) FILTER (WHERE f.feedback_type = 'suggestion')::int,
         count(*) FILTER (WHERE f.is_urgent AND f.status <> 'resolved')::int,
         count(*) FILTER (WHERE f.status = 'new')::int,
         round(avg(f.overall_rating), 2), round(avg(f.rating_crew), 2), round(avg(f.rating_food), 2),
         round(avg(f.rating_comfort), 2), round(avg(f.rating_cleanliness), 2), round(avg(f.rating_entertainment), 2),
         round(avg(f.rating_ground), 2)
    FROM passenger_feedback f
   WHERE f.tenant_id = guestora_resolve_tenant_id() AND f.created_at > now() - make_interval(days => LEAST(GREATEST(COALESCE(p_days, 30), 1), 3650));
END;
$$;
REVOKE ALL ON FUNCTION feedback_stats(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION feedback_stats(int) TO authenticated;

DO $$ BEGIN
  IF to_regprocedure('feedback_submit(jsonb)') IS NULL OR to_regprocedure('feedback_stats(int)') IS NULL THEN
    RAISE EXCEPTION 'Migration 33: objects not found';
  END IF;
  RAISE NOTICE 'Migration 33 verified: passenger feedback backend ready.';
END $$;
