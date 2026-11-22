-- 34: Base-scoped Roster Desk.
-- A roster officer with a base (profiles.base, plus optional extra bases in
-- profiles.base_scope) only sees and edits crew of those bases. Officers with
-- no base, and administrators, stay unscoped. Crew with no base are visible to
-- every officer. Enforced in the database: reads via RPC predicates, writes
-- via BEFORE triggers (also catches the SECURITY DEFINER write functions).

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS base_scope text[] NOT NULL DEFAULT '{}';

-- ---------- helpers ----------
-- NULL = unscoped; otherwise the list of bases the caller may work with.
CREATE OR REPLACE FUNCTION officer_scope() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT CASE
           WHEN p.is_admin IS TRUE OR p.role = 'admin' THEN NULL
           WHEN p.base IS NULL AND COALESCE(cardinality(p.base_scope), 0) = 0 THEN NULL
           ELSE array_remove(ARRAY[p.base] || COALESCE(p.base_scope, '{}'), NULL)
         END
    FROM profiles p WHERE p.id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION officer_base_ok(p_base text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT s IS NULL OR p_base IS NULL OR upper(p_base) = ANY (s) FROM (SELECT officer_scope() AS s) x;
$$;

CREATE OR REPLACE FUNCTION officer_user_ok(p_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT p_user IS NULL OR p_user = auth.uid()
         OR officer_base_ok((SELECT p.base FROM profiles p WHERE p.id = p_user));
$$;

CREATE OR REPLACE FUNCTION officer_crew_ok(p_crew uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT officer_base_ok((SELECT d.base FROM crew_directory d WHERE d.id = p_crew));
$$;

-- ---------- admin: assign bases ----------
CREATE OR REPLACE FUNCTION profiles_guard_base() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF (NEW.base IS NOT DISTINCT FROM OLD.base AND NEW.base_scope IS NOT DISTINCT FROM OLD.base_scope)
     OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF NOT COALESCE((SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false) THEN
    RAISE EXCEPTION 'Only an administrator can change a base assignment.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS profiles_guard_base_trg ON profiles;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'profiles'::regclass AND tgname = 'profiles_guard_base') THEN
    DROP TRIGGER profiles_guard_base ON profiles;
  END IF;
  CREATE TRIGGER profiles_guard_base BEFORE UPDATE ON profiles
    FOR EACH ROW EXECUTE FUNCTION profiles_guard_base();
END $$;

CREATE OR REPLACE FUNCTION admin_set_base_scope(p_user_id uuid, p_bases text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_new text[]; v_old text[]; v_label text; v_actor text; b text;
BEGIN
  IF NOT COALESCE((SELECT (p.is_admin IS TRUE OR p.role = 'admin') AND p.blocked IS NOT TRUE
                     FROM profiles p WHERE p.id = auth.uid()), false) THEN
    RAISE EXCEPTION 'Administrators only.' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(array_agg(DISTINCT u ORDER BY u), '{}') INTO v_new
    FROM (SELECT upper(btrim(x)) AS u FROM unnest(COALESCE(p_bases, '{}')) x) q WHERE u <> '';
  FOREACH b IN ARRAY v_new LOOP
    IF b !~ '^[A-Z]{3}$' THEN
      RAISE EXCEPTION 'A base is a 3-letter station code, e.g. EBB.' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF cardinality(v_new) > 10 THEN RAISE EXCEPTION 'At most 10 extra bases.' USING ERRCODE = '22023'; END IF;

  SELECT base_scope, COALESCE(full_name, email, id::text) INTO v_old, v_label
    FROM profiles WHERE id = p_user_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Account not found.' USING ERRCODE = 'P0002'; END IF;
  IF v_old IS NOT DISTINCT FROM v_new THEN RETURN; END IF;

  UPDATE profiles SET base_scope = v_new WHERE id = p_user_id;
  SELECT full_name INTO v_actor FROM profiles WHERE id = auth.uid();
  INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label, details)
  VALUES (v_tenant, auth.uid(), v_actor, 'base_scope_changed', p_user_id, v_label,
          jsonb_build_object('from', to_jsonb(v_old), 'to', to_jsonb(v_new)));
END $$;

-- the caller's own scope, for the UI badge
CREATE OR REPLACE FUNCTION my_officer_scope() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT CASE WHEN roster_is_officer() THEN officer_scope() END;
$$;

-- ---------- read paths ----------
CREATE OR REPLACE FUNCTION roster_can_access(p_roster_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT EXISTS (
    SELECT 1 FROM crew_rosters r
     WHERE r.id = p_roster_id
       AND r.tenant_id = guestora_resolve_tenant_id()
       AND (r.crew_user_id = auth.uid() OR (roster_is_officer() AND officer_user_ok(r.crew_user_id))));
$$;

CREATE OR REPLACE FUNCTION msg_resolve(p_tenant uuid, p_aud jsonb) RETURNS SETOF crew_directory
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT d.* FROM crew_directory d
   WHERE d.tenant_id = p_tenant AND d.archived_at IS NULL AND d.status <> 'resigned'
     AND officer_base_ok(d.base)
     AND ( COALESCE(p_aud->>'mode', 'all') <> 'crew'
           OR d.id IN (SELECT e::uuid FROM jsonb_array_elements_text(COALESCE(p_aud->'crew_ids', '[]'::jsonb)) e) )
     AND ( NULLIF(p_aud->>'base', '') IS NULL OR d.base = upper(p_aud->>'base') )
     AND ( NULLIF(p_aud->>'rank', '') IS NULL OR d.rank = p_aud->>'rank' )
     AND ( COALESCE((p_aud->>'only_accounts')::boolean, false) = false OR d.user_id IS NOT NULL );
$$;

CREATE OR REPLACE FUNCTION roster_desk_crew()
RETURNS TABLE(user_id uuid, display_name text, crew_position text, crew_code text, roster_count integer, latest_from date, latest_to date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Roster desk is for roster officers only.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT p.id,
         COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), 'Unnamed crew'),
         p.position, p.crew_code, COALESCE(r.cnt, 0)::int, r.latest_from, r.latest_to
    FROM profiles p
    LEFT JOIN LATERAL (
      SELECT count(*) AS cnt,
             (array_agg(cr.period_from ORDER BY cr.period_to DESC NULLS LAST))[1] AS latest_from,
             max(cr.period_to) AS latest_to
        FROM crew_rosters cr WHERE cr.crew_user_id = p.id AND cr.tenant_id = v_tenant
    ) r ON true
   WHERE p.tenant_id = v_tenant AND p.user_class = 'airline' AND p.blocked IS NOT TRUE
     AND officer_user_ok(p.id)
   ORDER BY 2;
END $$;

CREATE OR REPLACE FUNCTION roster_desk_duties(p_from date, p_to date)
RETURNS TABLE(duty_id uuid, roster_id uuid, crew_user_id uuid, crew_name text, crew_code text, duty_date date, duty_type text, flight_number text, origin text, destination text, std_local text, sta_local text, status text, officer_locked boolean, last_change_type text, unacked boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Roster desk is for roster officers only.' USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 31 THEN
    RAISE EXCEPTION 'Choose a date window of up to 31 days.';
  END IF;
  RETURN QUERY
  SELECT d.id, d.roster_id, r.crew_user_id,
         COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), r.crew_name, 'Unknown'),
         COALESCE(r.crew_code, p.crew_code),
         d.duty_date, d.duty_type, d.flight_number, d.origin, d.destination,
         d.std_local, d.sta_local, d.status, d.officer_locked, d.last_change_type,
         EXISTS (SELECT 1 FROM roster_duty_changes c
                  WHERE c.duty_id = d.id AND c.source = 'officer' AND c.acknowledged_at IS NULL)
    FROM roster_duties d
    JOIN crew_rosters r ON r.id = d.roster_id AND r.tenant_id = v_tenant
    LEFT JOIN profiles p ON p.id = r.crew_user_id
   WHERE d.tenant_id = v_tenant
     AND d.duty_date BETWEEN p_from AND p_to
     AND officer_user_ok(r.crew_user_id)
   ORDER BY d.duty_date, d.flight_number NULLS LAST, 4;
END $$;

CREATE OR REPLACE FUNCTION roster_activity_count() RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id(); v_seen timestamptz; v_n int;
BEGIN
  IF auth.uid() IS NULL OR NOT roster_is_officer() THEN RETURN 0; END IF;
  SELECT s.seen_at INTO v_seen FROM roster_officer_seen s WHERE s.user_id = auth.uid();
  SELECT count(*) INTO v_n
    FROM roster_duty_changes c
    JOIN crew_rosters r ON r.id = c.roster_id
   WHERE c.tenant_id = v_tenant AND c.source = 'crew'
     AND c.change_type NOT IN ('completed','diverted')
     AND c.changed_at > COALESCE(v_seen, now() - interval '7 days')
     AND c.changed_by IS DISTINCT FROM auth.uid()
     AND officer_user_ok(r.crew_user_id);
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION roster_activity(p_limit integer DEFAULT 80)
RETURNS TABLE(change_id uuid, changed_at timestamptz, source text, change_type text, reason text, old_values jsonb, new_values jsonb, acknowledged_at timestamptz, roster_id uuid, duty_id uuid, crew_user_id uuid, crew_name text, crew_code text, duty_date date, flight_number text, is_new boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id(); v_seen timestamptz;
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
   WHERE c.tenant_id = v_tenant AND c.change_type NOT IN ('completed','diverted')
     AND officer_user_ok(r.crew_user_id)
   ORDER BY c.changed_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 80), 1), 200);
END $$;

CREATE OR REPLACE FUNCTION crew_dir_list(p_include_archived boolean DEFAULT false)
RETURNS TABLE(id uuid, crew_code text, full_name text, staff_number text, rank text, base text, status text, join_date date, seniority_no integer, email text, phone text, emergency_name text, emergency_phone text, languages text, nationality text, notes text, user_id uuid, archived_at timestamptz, account_state text, last_seen_at timestamptz, roster_count integer, latest_to date, waiting_rosters integer, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can open the crew directory.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT d.id, d.crew_code, d.full_name, d.staff_number, d.rank, d.base, d.status,
         d.join_date, d.seniority_no, d.email, d.phone, d.emergency_name, d.emergency_phone,
         d.languages, d.nationality, d.notes, d.user_id, d.archived_at,
         CASE WHEN d.user_id IS NULL THEN 'none' WHEN p.blocked IS TRUE THEN 'blocked' ELSE 'active' END,
         p.last_seen_at, COALESCE(r.cnt, 0)::int, r.latest_to, COALESCE(w.cnt, 0)::int, d.created_at
    FROM crew_directory d
    LEFT JOIN profiles p ON p.id = d.user_id
    LEFT JOIN LATERAL (
      SELECT count(*) AS cnt, max(cr.period_to) AS latest_to FROM crew_rosters cr
       WHERE cr.tenant_id = v_tenant AND d.user_id IS NOT NULL AND cr.crew_user_id = d.user_id
    ) r ON true
    LEFT JOIN LATERAL (
      SELECT count(*) AS cnt FROM crew_rosters cr
       WHERE cr.tenant_id = v_tenant AND cr.crew_user_id IS NULL AND d.crew_code IS NOT NULL
         AND upper(btrim(cr.crew_code)) = upper(d.crew_code)
    ) w ON true
   WHERE d.tenant_id = v_tenant
     AND (p_include_archived OR d.archived_at IS NULL)
     AND officer_base_ok(d.base)
   ORDER BY lower(d.full_name);
END $$;

CREATE OR REPLACE FUNCTION crew_doc_list(p_crew uuid)
RETURNS TABLE(id uuid, doc_type text, label text, reference text, issued_on date, expires_on date, notes text, days_left integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF NOT officer_crew_ok(p_crew) THEN
    RAISE EXCEPTION 'This crew member is outside your base.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.id, c.doc_type, c.label, c.reference, c.issued_on, c.expires_on, c.notes,
         CASE WHEN c.expires_on IS NULL THEN NULL ELSE (c.expires_on - current_date)::int END
    FROM crew_documents c WHERE c.crew_id = p_crew AND c.tenant_id = v_tenant
   ORDER BY c.expires_on NULLS LAST, c.doc_type;
END $$;

CREATE OR REPLACE FUNCTION crew_expiry_overview(p_within integer DEFAULT 90)
RETURNS TABLE(doc_id uuid, crew_id uuid, full_name text, crew_code text, base text, doc_type text, label text, reference text, expires_on date, days_left integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
        v_within int := LEAST(GREATEST(COALESCE(p_within, 90), 0), 730);
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.id, d.id, d.full_name, d.crew_code, d.base, c.doc_type, c.label, c.reference, c.expires_on,
         (c.expires_on - current_date)::int
    FROM crew_documents c JOIN crew_directory d ON d.id = c.crew_id
   WHERE c.tenant_id = v_tenant AND d.archived_at IS NULL AND d.status <> 'resigned'
     AND c.expires_on IS NOT NULL AND c.expires_on <= current_date + v_within
     AND officer_base_ok(d.base)
   ORDER BY c.expires_on, lower(d.full_name);
END $$;

CREATE OR REPLACE FUNCTION crew_leave_list(p_crew uuid)
RETURNS TABLE(id uuid, kind text, start_date date, end_date date, status text, reason text, via text, decided_by_name text, decided_at timestamptz, decision_note text, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF NOT officer_crew_ok(p_crew) THEN
    RAISE EXCEPTION 'This crew member is outside your base.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT l.id, l.kind, l.start_date, l.end_date, l.status, l.reason, l.via,
         p.full_name, l.decided_at, l.decision_note, l.created_at
    FROM crew_leave l LEFT JOIN profiles p ON p.id = l.decided_by
   WHERE l.crew_id = p_crew AND l.tenant_id = v_tenant
   ORDER BY l.start_date DESC, l.created_at DESC LIMIT 200;
END $$;

CREATE OR REPLACE FUNCTION crew_leave_overview(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE(leave_id uuid, crew_id uuid, full_name text, crew_code text, base text, kind text, start_date date, end_date date, status text, reason text, via text, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
        v_from date := COALESCE(p_from, current_date);
        v_to   date := COALESCE(p_to, current_date + 60);
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT l.id, d.id, d.full_name, d.crew_code, d.base, l.kind, l.start_date, l.end_date, l.status,
         l.reason, l.via, l.created_at
    FROM crew_leave l JOIN crew_directory d ON d.id = l.crew_id
   WHERE l.tenant_id = v_tenant AND d.archived_at IS NULL AND officer_base_ok(d.base)
     AND ( l.status = 'pending' OR (l.status = 'approved' AND l.start_date <= v_to AND l.end_date >= v_from) )
   ORDER BY (l.status = 'pending') DESC, l.start_date, lower(d.full_name)
   LIMIT 500;
END $$;

CREATE OR REPLACE FUNCTION crew_leave_pending_count() RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NULL OR NOT roster_is_officer() THEN RETURN 0; END IF;
  SELECT count(*) INTO v_n FROM crew_leave l JOIN crew_directory d ON d.id = l.crew_id
   WHERE l.tenant_id = guestora_resolve_tenant_id() AND l.status = 'pending' AND officer_base_ok(d.base);
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION crew_leave_balance(p_crew uuid, p_year integer DEFAULT NULL)
RETURNS TABLE(entitlement integer, used integer, pending integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM crew_directory d WHERE d.id = p_crew AND d.tenant_id = guestora_resolve_tenant_id()) THEN
    RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002';
  END IF;
  IF NOT officer_crew_ok(p_crew) THEN
    RAISE EXCEPTION 'This crew member is outside your base.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM crew_leave_balance_calc(p_crew, COALESCE(p_year, extract(year FROM current_date)::int));
END $$;

CREATE OR REPLACE FUNCTION crew_dir_flags()
RETURNS TABLE(crew_id uuid, docs_expired integer, docs_soon integer, leave_pending integer, away_now boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT d.id,
         (SELECT count(*) FROM crew_documents c WHERE c.crew_id = d.id AND c.expires_on < current_date)::int,
         (SELECT count(*) FROM crew_documents c WHERE c.crew_id = d.id
             AND c.expires_on >= current_date AND c.expires_on <= current_date + 60)::int,
         (SELECT count(*) FROM crew_leave l WHERE l.crew_id = d.id AND l.status = 'pending')::int,
         EXISTS (SELECT 1 FROM crew_leave l WHERE l.crew_id = d.id AND l.status = 'approved'
                    AND l.start_date <= current_date AND l.end_date >= current_date)
    FROM crew_directory d
   WHERE d.tenant_id = v_tenant AND d.archived_at IS NULL AND officer_base_ok(d.base);
END $$;

-- crew_dir_check: out-of-scope crew return no warnings (they can't be rostered by this officer anyway)
ALTER FUNCTION crew_dir_check(uuid, date) RENAME TO crew_dir_check_unscoped;
REVOKE ALL ON FUNCTION crew_dir_check_unscoped(uuid, date) FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION crew_dir_check(p_user_id uuid, p_date date)
RETURNS TABLE(kind text, message text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF NOT officer_user_ok(p_user_id) THEN RETURN; END IF;
  RETURN QUERY SELECT * FROM crew_dir_check_unscoped(p_user_id, p_date);
END $$;

-- ---------- write guards ----------
-- Fires for any caller who is a scoped officer; crew writing their own data and
-- unscoped officers/admins pass straight through.
CREATE OR REPLACE FUNCTION scope_guard_dir() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE sc text[];
BEGIN
  IF auth.uid() IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
  sc := officer_scope();
  IF sc IS NULL OR NOT roster_is_officer() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF TG_OP <> 'INSERT' AND NOT officer_base_ok(OLD.base) THEN
    RAISE EXCEPTION 'This crew member is outside your base.' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF NEW.base IS NULL AND TG_OP = 'INSERT' THEN NEW.base := sc[1]; END IF;
  IF NOT officer_base_ok(NEW.base) THEN
    RAISE EXCEPTION 'You can only work with crew of your own base (%).', array_to_string(sc, ', ') USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS scope_guard ON crew_directory;
CREATE TRIGGER scope_guard BEFORE INSERT OR UPDATE OR DELETE ON crew_directory
  FOR EACH ROW EXECUTE FUNCTION scope_guard_dir();

CREATE OR REPLACE FUNCTION scope_guard_crew_child() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_crew uuid;
BEGIN
  IF auth.uid() IS NULL OR officer_scope() IS NULL OR NOT roster_is_officer() THEN RETURN COALESCE(NEW, OLD); END IF;
  v_crew := CASE WHEN TG_OP = 'DELETE' THEN OLD.crew_id ELSE NEW.crew_id END;
  IF NOT officer_crew_ok(v_crew) THEN
    RAISE EXCEPTION 'This crew member is outside your base.' USING ERRCODE = '42501';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS scope_guard ON crew_documents;
CREATE TRIGGER scope_guard BEFORE INSERT OR UPDATE OR DELETE ON crew_documents
  FOR EACH ROW EXECUTE FUNCTION scope_guard_crew_child();
DROP TRIGGER IF EXISTS scope_guard ON crew_leave;
CREATE TRIGGER scope_guard BEFORE INSERT OR UPDATE OR DELETE ON crew_leave
  FOR EACH ROW EXECUTE FUNCTION scope_guard_crew_child();

CREATE OR REPLACE FUNCTION scope_guard_roster() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_user uuid;
BEGIN
  IF auth.uid() IS NULL OR officer_scope() IS NULL OR NOT roster_is_officer() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF TG_TABLE_NAME = 'crew_rosters' THEN
    v_user := CASE WHEN TG_OP = 'DELETE' THEN OLD.crew_user_id ELSE NEW.crew_user_id END;
  ELSE
    SELECT r.crew_user_id INTO v_user FROM crew_rosters r
     WHERE r.id = CASE WHEN TG_OP = 'DELETE' THEN OLD.roster_id ELSE NEW.roster_id END;
  END IF;
  IF NOT officer_user_ok(v_user) THEN
    RAISE EXCEPTION 'This crew member is outside your base.' USING ERRCODE = '42501';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS scope_guard ON crew_rosters;
CREATE TRIGGER scope_guard BEFORE INSERT OR UPDATE OR DELETE ON crew_rosters
  FOR EACH ROW EXECUTE FUNCTION scope_guard_roster();
DROP TRIGGER IF EXISTS scope_guard ON roster_duties;
CREATE TRIGGER scope_guard BEFORE INSERT OR UPDATE OR DELETE ON roster_duties
  FOR EACH ROW EXECUTE FUNCTION scope_guard_roster();

-- crew code / position edits on a profile
CREATE OR REPLACE FUNCTION scope_guard_profile() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
  IF auth.uid() IS NULL OR NEW.id = auth.uid() OR officer_scope() IS NULL OR NOT roster_is_officer() THEN RETURN NEW; END IF;
  IF (NEW.crew_code IS DISTINCT FROM OLD.crew_code OR NEW.position IS DISTINCT FROM OLD.position)
     AND NOT officer_base_ok(OLD.base) THEN
    RAISE EXCEPTION 'This crew member is outside your base.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS scope_guard ON profiles;
CREATE TRIGGER scope_guard BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION scope_guard_profile();

-- ---------- grants ----------
REVOKE ALL ON FUNCTION officer_scope(), officer_base_ok(text), officer_user_ok(uuid), officer_crew_ok(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION admin_set_base_scope(uuid, text[]), my_officer_scope() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_set_base_scope(uuid, text[]), my_officer_scope() TO authenticated;

DO $$ BEGIN RAISE NOTICE 'Migration 34 verified: base-scoped Roster Desk ready.'; END $$;

-- admin screen: every account's extra bases
CREATE OR REPLACE FUNCTION admin_base_scopes() RETURNS TABLE(user_id uuid, base_scope text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT p.id, p.base_scope FROM profiles p
   WHERE p.tenant_id = guestora_resolve_tenant_id()
     AND COALESCE(cardinality(p.base_scope), 0) > 0
     AND COALESCE((SELECT (a.is_admin IS TRUE OR a.role = 'admin') AND a.blocked IS NOT TRUE FROM profiles a WHERE a.id = auth.uid()), false);
$$;
REVOKE ALL ON FUNCTION admin_base_scopes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_base_scopes() TO authenticated;
