-- =============================================================================
-- Migration: 20241101000029_crew_documents_and_leave.sql
-- Description: Crew Directory, phase 2 — licences/qualifications with expiry
--              tracking, and leave & availability.
--
--   crew_documents          – licence, medical, passport, visa, yellow fever,
--                             SEP, first aid, DG, CRM, security, aircraft types
--   crew_leave              – annual/sick/study/... leave, off requests and
--                             unavailable dates, with an approval workflow
--
--   Officers / admins:
--     crew_doc_list / crew_doc_save / crew_doc_delete
--     crew_expiry_overview()      – everything expired or expiring, all crew
--     crew_leave_list / crew_leave_save / crew_leave_set_status
--     crew_leave_overview()       – who is away / has asked to be
--     crew_leave_pending_count()  – the approval queue size
--     crew_leave_balance()        – entitlement, used, pending (annual leave)
--     crew_leave_set_entitlement()
--     crew_dir_flags()            – per-crew badges for the directory list
--     crew_dir_check()            – "should I roster this person on this day?"
--   Crew (own record only):
--     leave_my_list / leave_my_request / leave_my_cancel / leave_my_balance
--     leave_my_unseen_count / leave_my_mark_seen
--
-- Tables have no direct policies; everything goes through the functions above.
-- Requires migrations 26 and 28. Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('crew_directory') IS NULL OR to_regprocedure('crew_dir_log(text,uuid,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Migration 29 requires migration 28.';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
ALTER TABLE crew_directory ADD COLUMN IF NOT EXISTS annual_leave_days int;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'crew_directory_leave_days_check') THEN
    ALTER TABLE crew_directory ADD CONSTRAINT crew_directory_leave_days_check
      CHECK (annual_leave_days IS NULL OR annual_leave_days BETWEEN 0 AND 366);
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS crew_documents (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,
  crew_id     uuid        NOT NULL REFERENCES crew_directory(id) ON DELETE CASCADE,
  doc_type    text        NOT NULL,
  label       text,
  reference   text,
  issued_on   date,
  expires_on  date,
  notes       text,
  created_by  uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crew_documents_type_check CHECK (doc_type IN
    ('licence','medical','passport','visa','yellow_fever','sep','first_aid','dangerous_goods','crm','security','aircraft_type','other')),
  CONSTRAINT crew_documents_dates_check CHECK (expires_on IS NULL OR issued_on IS NULL OR expires_on >= issued_on)
);
CREATE INDEX IF NOT EXISTS crew_documents_crew    ON crew_documents (crew_id);
CREATE INDEX IF NOT EXISTS crew_documents_expires ON crew_documents (tenant_id, expires_on);
ALTER TABLE crew_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON crew_documents FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS crew_leave (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,
  crew_id        uuid        NOT NULL REFERENCES crew_directory(id) ON DELETE CASCADE,
  kind           text        NOT NULL,
  start_date     date        NOT NULL,
  end_date       date        NOT NULL,
  status         text        NOT NULL DEFAULT 'pending',
  reason         text,
  via            text        NOT NULL DEFAULT 'officer',
  requested_by   uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  decided_by     uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  decided_at     timestamptz,
  decision_note  text,
  decision_seen  boolean     NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crew_leave_kind_check CHECK (kind IN
    ('annual','sick','study','maternity','compassionate','unpaid','off_request','unavailable','other')),
  CONSTRAINT crew_leave_status_check CHECK (status IN ('pending','approved','declined','cancelled')),
  CONSTRAINT crew_leave_via_check CHECK (via IN ('crew','officer')),
  CONSTRAINT crew_leave_dates_check CHECK (end_date >= start_date AND end_date - start_date <= 366)
);
CREATE INDEX IF NOT EXISTS crew_leave_crew   ON crew_leave (crew_id, start_date DESC);
CREATE INDEX IF NOT EXISTS crew_leave_window ON crew_leave (tenant_id, status, start_date, end_date);
ALTER TABLE crew_leave ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON crew_leave FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_pretty_date(p date) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT to_char(p, 'DD Mon YYYY'); $$;

CREATE OR REPLACE FUNCTION crew_leave_overlap_msg(p_crew uuid, p_start date, p_end date, p_except uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE r crew_leave;
BEGIN
  SELECT * INTO r FROM crew_leave l
   WHERE l.crew_id = p_crew AND l.status IN ('pending','approved')
     AND l.id IS DISTINCT FROM p_except
     AND l.start_date <= p_end AND l.end_date >= p_start
   ORDER BY l.start_date LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN format('That overlaps an existing %s entry (%s, %s to %s).',
                replace(r.kind, '_', ' '), r.status, crew_pretty_date(r.start_date), crew_pretty_date(r.end_date));
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_overlap_msg(uuid, date, date, uuid) FROM PUBLIC, anon, authenticated;

-- Annual-leave numbers for one crew member and calendar year (calendar days, inclusive)
CREATE OR REPLACE FUNCTION crew_leave_balance_calc(p_crew uuid, p_year int)
RETURNS TABLE (entitlement int, used int, pending int)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  WITH y AS (SELECT make_date(p_year, 1, 1) AS d0, make_date(p_year, 12, 31) AS d1)
  SELECT (SELECT d.annual_leave_days FROM crew_directory d WHERE d.id = p_crew),
         COALESCE((SELECT sum(GREATEST(0, LEAST(l.end_date, y.d1) - GREATEST(l.start_date, y.d0) + 1))
                     FROM crew_leave l, y WHERE l.crew_id = p_crew AND l.kind = 'annual' AND l.status = 'approved'), 0)::int,
         COALESCE((SELECT sum(GREATEST(0, LEAST(l.end_date, y.d1) - GREATEST(l.start_date, y.d0) + 1))
                     FROM crew_leave l, y WHERE l.crew_id = p_crew AND l.kind = 'annual' AND l.status = 'pending'), 0)::int;
$$;
REVOKE ALL ON FUNCTION crew_leave_balance_calc(uuid, int) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Documents
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS crew_doc_list(uuid);
CREATE FUNCTION crew_doc_list(p_crew uuid)
RETURNS TABLE (id uuid, doc_type text, label text, reference text, issued_on date, expires_on date,
               notes text, days_left int)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.id, c.doc_type, c.label, c.reference, c.issued_on, c.expires_on, c.notes,
         CASE WHEN c.expires_on IS NULL THEN NULL ELSE (c.expires_on - current_date)::int END
    FROM crew_documents c
   WHERE c.crew_id = p_crew AND c.tenant_id = v_tenant
   ORDER BY c.expires_on NULLS LAST, c.doc_type;
END;
$$;
REVOKE ALL ON FUNCTION crew_doc_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_doc_list(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION crew_doc_save(p_id uuid, p_crew uuid, p_data jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  d crew_directory;
  o crew_documents%ROWTYPE;
  n_type text; n_label text; n_ref text; n_issued date; n_exp date; n_notes text;
  v_id uuid;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO d FROM crew_directory WHERE id = p_crew AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION 'Nothing to save.' USING ERRCODE = '22023';
  END IF;
  IF p_id IS NOT NULL THEN
    SELECT * INTO o FROM crew_documents WHERE id = p_id AND crew_id = p_crew AND tenant_id = v_tenant FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Document not found.' USING ERRCODE = 'P0002'; END IF;
  END IF;

  n_type  := CASE WHEN p_data ? 'doc_type' THEN NULLIF(btrim(p_data->>'doc_type'), '') ELSE o.doc_type END;
  n_label := CASE WHEN p_data ? 'label'    THEN NULLIF(btrim(p_data->>'label'), '')    ELSE o.label END;
  n_ref   := CASE WHEN p_data ? 'reference' THEN NULLIF(btrim(p_data->>'reference'), '') ELSE o.reference END;
  n_notes := CASE WHEN p_data ? 'notes'    THEN NULLIF(btrim(p_data->>'notes'), '')    ELSE o.notes END;
  BEGIN
    n_issued := CASE WHEN p_data ? 'issued_on'  THEN NULLIF(btrim(p_data->>'issued_on'), '')::date  ELSE o.issued_on END;
    n_exp    := CASE WHEN p_data ? 'expires_on' THEN NULLIF(btrim(p_data->>'expires_on'), '')::date ELSE o.expires_on END;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Dates must look like 2026-03-31.' USING ERRCODE = '22007';
  END;

  IF n_type IS NULL THEN RAISE EXCEPTION 'Choose a document type.' USING ERRCODE = '22023'; END IF;
  IF n_type NOT IN ('licence','medical','passport','visa','yellow_fever','sep','first_aid','dangerous_goods','crm','security','aircraft_type','other') THEN
    RAISE EXCEPTION 'Unknown document type.' USING ERRCODE = '22023';
  END IF;
  IF n_type IN ('aircraft_type','other') AND n_label IS NULL THEN
    RAISE EXCEPTION 'Add a name for this %.', CASE WHEN n_type = 'aircraft_type' THEN 'aircraft type (e.g. A330)' ELSE 'document' END
      USING ERRCODE = '22023';
  END IF;
  IF length(COALESCE(n_label, '')) > 60 OR length(COALESCE(n_ref, '')) > 60 THEN
    RAISE EXCEPTION 'That is too long (60 characters at most).' USING ERRCODE = '22023';
  END IF;
  IF n_exp IS NOT NULL AND n_issued IS NOT NULL AND n_exp < n_issued THEN
    RAISE EXCEPTION 'The expiry date is before the issue date.' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO crew_documents (tenant_id, crew_id, doc_type, label, reference, issued_on, expires_on, notes, created_by)
    VALUES (v_tenant, p_crew, n_type, n_label, n_ref, n_issued, n_exp, n_notes, auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE crew_documents SET doc_type = n_type, label = n_label, reference = n_ref, issued_on = n_issued,
           expires_on = n_exp, notes = n_notes, updated_at = now()
     WHERE id = p_id;
    v_id := p_id;
  END IF;
  PERFORM crew_dir_log('crew_doc_saved', p_crew, d.full_name,
    jsonb_build_object('type', n_type, 'label', n_label, 'expires_on', n_exp, 'new', p_id IS NULL));
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crew_doc_save(uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_doc_save(uuid, uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION crew_doc_delete(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  o crew_documents;
  v_name text;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO o FROM crew_documents WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Document not found.' USING ERRCODE = 'P0002'; END IF;
  SELECT full_name INTO v_name FROM crew_directory WHERE id = o.crew_id;
  DELETE FROM crew_documents WHERE id = p_id;
  PERFORM crew_dir_log('crew_doc_deleted', o.crew_id, v_name,
    jsonb_build_object('type', o.doc_type, 'label', o.label, 'expires_on', o.expires_on));
END;
$$;
REVOKE ALL ON FUNCTION crew_doc_delete(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_doc_delete(uuid) TO authenticated;

-- Everything expired or expiring within p_within days (active, non-archived crew)
DROP FUNCTION IF EXISTS crew_expiry_overview(int);
CREATE FUNCTION crew_expiry_overview(p_within int DEFAULT 90)
RETURNS TABLE (doc_id uuid, crew_id uuid, full_name text, crew_code text, base text,
               doc_type text, label text, reference text, expires_on date, days_left int)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_within int := LEAST(GREATEST(COALESCE(p_within, 90), 0), 730);
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.id, d.id, d.full_name, d.crew_code, d.base, c.doc_type, c.label, c.reference, c.expires_on,
         (c.expires_on - current_date)::int
    FROM crew_documents c
    JOIN crew_directory d ON d.id = c.crew_id
   WHERE c.tenant_id = v_tenant AND d.archived_at IS NULL AND d.status <> 'resigned'
     AND c.expires_on IS NOT NULL AND c.expires_on <= current_date + v_within
   ORDER BY c.expires_on, lower(d.full_name);
END;
$$;
REVOKE ALL ON FUNCTION crew_expiry_overview(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_expiry_overview(int) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Leave — officer side
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS crew_leave_list(uuid);
CREATE FUNCTION crew_leave_list(p_crew uuid)
RETURNS TABLE (id uuid, kind text, start_date date, end_date date, status text, reason text, via text,
               decided_by_name text, decided_at timestamptz, decision_note text, created_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT l.id, l.kind, l.start_date, l.end_date, l.status, l.reason, l.via,
         p.full_name, l.decided_at, l.decision_note, l.created_at
    FROM crew_leave l
    LEFT JOIN profiles p ON p.id = l.decided_by
   WHERE l.crew_id = p_crew AND l.tenant_id = v_tenant
   ORDER BY l.start_date DESC, l.created_at DESC
   LIMIT 200;
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_leave_list(uuid) TO authenticated;

-- Officer records leave directly (approved unless said otherwise), or edits an entry
CREATE OR REPLACE FUNCTION crew_leave_save(p_id uuid, p_crew uuid, p_data jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  d crew_directory;
  o crew_leave%ROWTYPE;
  n_kind text; n_start date; n_end date; n_status text; n_reason text;
  v_msg text; v_id uuid;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO d FROM crew_directory WHERE id = p_crew AND tenant_id = v_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION 'Nothing to save.' USING ERRCODE = '22023';
  END IF;
  IF p_id IS NOT NULL THEN
    SELECT * INTO o FROM crew_leave WHERE id = p_id AND crew_id = p_crew AND tenant_id = v_tenant FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Entry not found.' USING ERRCODE = 'P0002'; END IF;
  END IF;

  n_kind   := CASE WHEN p_data ? 'kind'   THEN NULLIF(btrim(p_data->>'kind'), '')   ELSE o.kind END;
  n_status := CASE WHEN p_data ? 'status' THEN NULLIF(btrim(p_data->>'status'), '') ELSE COALESCE(o.status, 'approved') END;
  n_reason := CASE WHEN p_data ? 'reason' THEN NULLIF(btrim(p_data->>'reason'), '') ELSE o.reason END;
  BEGIN
    n_start := CASE WHEN p_data ? 'start_date' THEN NULLIF(btrim(p_data->>'start_date'), '')::date ELSE o.start_date END;
    n_end   := CASE WHEN p_data ? 'end_date'   THEN NULLIF(btrim(p_data->>'end_date'), '')::date   ELSE o.end_date END;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Dates must look like 2026-03-31.' USING ERRCODE = '22007';
  END;
  n_end := COALESCE(n_end, n_start);

  IF n_kind IS NULL OR n_kind NOT IN ('annual','sick','study','maternity','compassionate','unpaid','off_request','unavailable','other') THEN
    RAISE EXCEPTION 'Choose a leave type.' USING ERRCODE = '22023';
  END IF;
  IF n_status NOT IN ('pending','approved','declined','cancelled') THEN
    RAISE EXCEPTION 'Unknown status.' USING ERRCODE = '22023';
  END IF;
  IF n_start IS NULL THEN RAISE EXCEPTION 'Choose a start date.' USING ERRCODE = '22023'; END IF;
  IF n_end < n_start THEN RAISE EXCEPTION 'The end date is before the start date.' USING ERRCODE = '22023'; END IF;
  IF n_end - n_start > 366 THEN RAISE EXCEPTION 'That is longer than a year.' USING ERRCODE = '22023'; END IF;
  IF length(COALESCE(n_reason, '')) > 300 THEN RAISE EXCEPTION 'The note is too long (300 characters).' USING ERRCODE = '22023'; END IF;

  IF n_status IN ('pending','approved') THEN
    v_msg := crew_leave_overlap_msg(p_crew, n_start, n_end, p_id);
    IF v_msg IS NOT NULL THEN RAISE EXCEPTION '%', v_msg USING ERRCODE = '23P01'; END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO crew_leave (tenant_id, crew_id, kind, start_date, end_date, status, reason, via, requested_by,
                            decided_by, decided_at, decision_seen)
    VALUES (v_tenant, p_crew, n_kind, n_start, n_end, n_status, n_reason, 'officer', auth.uid(),
            CASE WHEN n_status <> 'pending' THEN auth.uid() END,
            CASE WHEN n_status <> 'pending' THEN now() END,
            d.user_id IS NULL)            -- an account holder is told; nobody else needs a badge
    RETURNING id INTO v_id;
  ELSE
    UPDATE crew_leave SET kind = n_kind, start_date = n_start, end_date = n_end, status = n_status, reason = n_reason,
           decided_by = CASE WHEN n_status <> o.status AND n_status <> 'pending' THEN auth.uid() ELSE decided_by END,
           decided_at = CASE WHEN n_status <> o.status AND n_status <> 'pending' THEN now() ELSE decided_at END,
           decision_seen = CASE WHEN d.user_id IS NOT NULL THEN false ELSE true END,
           updated_at = now()
     WHERE id = p_id;
    v_id := p_id;
  END IF;
  PERFORM crew_dir_log('leave_saved', p_crew, d.full_name,
    jsonb_build_object('kind', n_kind, 'from', n_start, 'to', n_end, 'status', n_status, 'new', p_id IS NULL));
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_save(uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_leave_save(uuid, uuid, jsonb) TO authenticated;

-- Approve / decline / cancel one entry (the approval queue)
CREATE OR REPLACE FUNCTION crew_leave_set_status(p_id uuid, p_status text, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  l crew_leave;
  d crew_directory;
  v_msg text;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('approved','declined','cancelled') THEN
    RAISE EXCEPTION 'Unknown status.' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO l FROM crew_leave WHERE id = p_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Entry not found.' USING ERRCODE = 'P0002'; END IF;
  IF l.status = p_status THEN RETURN; END IF;
  IF length(COALESCE(p_note, '')) > 300 THEN RAISE EXCEPTION 'The note is too long (300 characters).' USING ERRCODE = '22023'; END IF;
  SELECT * INTO d FROM crew_directory WHERE id = l.crew_id;

  IF p_status = 'approved' THEN
    v_msg := crew_leave_overlap_msg(l.crew_id, l.start_date, l.end_date, p_id);
    IF v_msg IS NOT NULL THEN RAISE EXCEPTION '%', v_msg USING ERRCODE = '23P01'; END IF;
  END IF;

  UPDATE crew_leave SET status = p_status, decided_by = auth.uid(), decided_at = now(),
         decision_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
         decision_seen = (d.user_id IS NULL), updated_at = now()
   WHERE id = p_id;
  PERFORM crew_dir_log('leave_decided', l.crew_id, d.full_name,
    jsonb_build_object('kind', l.kind, 'from', l.start_date, 'to', l.end_date, 'status', p_status));
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_set_status(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_leave_set_status(uuid, text, text) TO authenticated;

-- Pending requests and anything approved that overlaps the window (default: next 60 days)
DROP FUNCTION IF EXISTS crew_leave_overview(date, date);
CREATE FUNCTION crew_leave_overview(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE (leave_id uuid, crew_id uuid, full_name text, crew_code text, base text, kind text,
               start_date date, end_date date, status text, reason text, via text, created_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_from date := COALESCE(p_from, current_date);
  v_to   date := COALESCE(p_to, current_date + 60);
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT l.id, d.id, d.full_name, d.crew_code, d.base, l.kind, l.start_date, l.end_date, l.status,
         l.reason, l.via, l.created_at
    FROM crew_leave l
    JOIN crew_directory d ON d.id = l.crew_id
   WHERE l.tenant_id = v_tenant AND d.archived_at IS NULL
     AND ( l.status = 'pending'
           OR (l.status = 'approved' AND l.start_date <= v_to AND l.end_date >= v_from) )
   ORDER BY (l.status = 'pending') DESC, l.start_date, lower(d.full_name)
   LIMIT 500;
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_overview(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_leave_overview(date, date) TO authenticated;

CREATE OR REPLACE FUNCTION crew_leave_pending_count()
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NULL OR NOT roster_is_officer() THEN RETURN 0; END IF;
  SELECT count(*) INTO v_n FROM crew_leave l
   WHERE l.tenant_id = guestora_resolve_tenant_id() AND l.status = 'pending';
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_pending_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_leave_pending_count() TO authenticated;

DROP FUNCTION IF EXISTS crew_leave_balance(uuid, int);
CREATE FUNCTION crew_leave_balance(p_crew uuid, p_year int DEFAULT NULL)
RETURNS TABLE (entitlement int, used int, pending int)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM crew_directory d WHERE d.id = p_crew AND d.tenant_id = guestora_resolve_tenant_id()) THEN
    RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002';
  END IF;
  RETURN QUERY SELECT * FROM crew_leave_balance_calc(p_crew, COALESCE(p_year, extract(year FROM current_date)::int));
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_balance(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_leave_balance(uuid, int) TO authenticated;

CREATE OR REPLACE FUNCTION crew_leave_set_entitlement(p_crew uuid, p_days int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  d crew_directory;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF p_days IS NOT NULL AND (p_days < 0 OR p_days > 366) THEN
    RAISE EXCEPTION 'Annual leave is between 0 and 366 days.' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO d FROM crew_directory WHERE id = p_crew AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  IF d.annual_leave_days IS NOT DISTINCT FROM p_days THEN RETURN; END IF;
  UPDATE crew_directory SET annual_leave_days = p_days, updated_at = now() WHERE id = p_crew;
  PERFORM crew_dir_log('crew_updated', p_crew, d.full_name,
    jsonb_build_object('fields', to_jsonb(ARRAY['annual leave entitlement'])));
END;
$$;
REVOKE ALL ON FUNCTION crew_leave_set_entitlement(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_leave_set_entitlement(uuid, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Directory badges and the assignment check
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS crew_dir_flags();
CREATE FUNCTION crew_dir_flags()
RETURNS TABLE (crew_id uuid, docs_expired int, docs_soon int, leave_pending int, away_now boolean)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
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
   WHERE d.tenant_id = v_tenant AND d.archived_at IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_flags() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_flags() TO authenticated;

-- Before rostering someone: is there a reason not to? (informational — never blocks)
DROP FUNCTION IF EXISTS crew_dir_check(uuid, date);
CREATE FUNCTION crew_dir_check(p_user_id uuid, p_date date)
RETURNS TABLE (kind text, message text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  d crew_directory;
  r record;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO d FROM crew_directory WHERE user_id = p_user_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN RETURN; END IF;

  IF d.status IN ('suspended','resigned','on_leave') THEN
    kind := 'status'; message := format('%s is marked %s.', d.full_name, replace(d.status, '_', ' '));
    RETURN NEXT;
  END IF;

  FOR r IN
    SELECT l.kind AS k, l.start_date AS s, l.end_date AS e
      FROM crew_leave l
     WHERE l.crew_id = d.id AND l.status = 'approved' AND l.start_date <= p_date AND l.end_date >= p_date
  LOOP
    kind := 'leave';
    message := format('%s has approved %s from %s to %s.', d.full_name,
                      CASE r.k WHEN 'off_request' THEN 'time off' WHEN 'unavailable' THEN 'unavailable dates'
                               ELSE replace(r.k, '_', ' ') || ' leave' END,
                      crew_pretty_date(r.s), crew_pretty_date(r.e));
    RETURN NEXT;
  END LOOP;

  FOR r IN
    SELECT c.doc_type AS t, max(c.expires_on) AS e
      FROM crew_documents c
     WHERE c.crew_id = d.id AND c.doc_type IN ('licence','medical','sep') AND c.expires_on IS NOT NULL
     GROUP BY c.doc_type
    HAVING max(c.expires_on) < p_date
  LOOP
    kind := 'document';
    message := format('%s: %s expires %s, before this duty.', d.full_name,
                      CASE r.t WHEN 'licence' THEN 'crew licence' WHEN 'medical' THEN 'medical certificate'
                               ELSE 'SEP training' END,
                      crew_pretty_date(r.e));
    RETURN NEXT;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_check(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_check(uuid, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Leave — crew self-service (the signed-in crew member's own record only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION leave_my_crew_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$ SELECT d.id FROM crew_directory d WHERE d.user_id = auth.uid(); $$;
REVOKE ALL ON FUNCTION leave_my_crew_id() FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS leave_my_list();
CREATE FUNCTION leave_my_list()
RETURNS TABLE (id uuid, kind text, start_date date, end_date date, status text, reason text, via text,
               decision_note text, decision_seen boolean, created_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_crew uuid := leave_my_crew_id();
BEGIN
  IF v_crew IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT l.id, l.kind, l.start_date, l.end_date, l.status, l.reason, l.via, l.decision_note, l.decision_seen, l.created_at
    FROM crew_leave l
   WHERE l.crew_id = v_crew
   ORDER BY l.start_date DESC, l.created_at DESC
   LIMIT 100;
END;
$$;
REVOKE ALL ON FUNCTION leave_my_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leave_my_list() TO authenticated;

DROP FUNCTION IF EXISTS leave_my_balance(int);
CREATE FUNCTION leave_my_balance(p_year int DEFAULT NULL)
RETURNS TABLE (entitlement int, used int, pending int)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_crew uuid := leave_my_crew_id();
BEGIN
  IF v_crew IS NULL THEN RETURN; END IF;
  RETURN QUERY SELECT * FROM crew_leave_balance_calc(v_crew, COALESCE(p_year, extract(year FROM current_date)::int));
END;
$$;
REVOKE ALL ON FUNCTION leave_my_balance(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leave_my_balance(int) TO authenticated;

CREATE OR REPLACE FUNCTION leave_my_request(p_kind text, p_start date, p_end date, p_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_crew  uuid;
  v_tenant uuid;
  v_end   date := COALESCE(p_end, p_start);
  v_msg   text;
  v_id    uuid;
  v_floor date;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = '42501'; END IF;
  v_crew := leave_my_crew_id();
  IF v_crew IS NULL THEN v_crew := crew_dir_claim_self(); END IF;
  IF v_crew IS NULL THEN
    RAISE EXCEPTION 'Leave requests are for airline crew accounts.' USING ERRCODE = '42501';
  END IF;
  SELECT d.tenant_id INTO v_tenant FROM crew_directory d WHERE d.id = v_crew;

  IF p_kind IS NULL OR p_kind NOT IN ('annual','sick','study','maternity','compassionate','unpaid','off_request','unavailable','other') THEN
    RAISE EXCEPTION 'Choose what you are asking for.' USING ERRCODE = '22023';
  END IF;
  IF p_start IS NULL THEN RAISE EXCEPTION 'Choose a start date.' USING ERRCODE = '22023'; END IF;
  IF v_end < p_start THEN RAISE EXCEPTION 'The end date is before the start date.' USING ERRCODE = '22023'; END IF;
  IF v_end - p_start > 120 THEN RAISE EXCEPTION 'Requests can cover at most 120 days.' USING ERRCODE = '22023'; END IF;
  v_floor := current_date - (CASE WHEN p_kind = 'sick' THEN 30 ELSE 0 END);   -- sickness may be reported afterwards
  IF p_start < v_floor THEN
    RAISE EXCEPTION 'That start date has already passed.' USING ERRCODE = '22023';
  END IF;
  IF length(COALESCE(p_reason, '')) > 300 THEN RAISE EXCEPTION 'The note is too long (300 characters).' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM crew_leave l WHERE l.crew_id = v_crew AND l.status = 'pending') >= 20 THEN
    RAISE EXCEPTION 'You already have 20 requests waiting. Wait for a decision or cancel some.' USING ERRCODE = '54000';
  END IF;
  v_msg := crew_leave_overlap_msg(v_crew, p_start, v_end, NULL);
  IF v_msg IS NOT NULL THEN RAISE EXCEPTION '%', v_msg USING ERRCODE = '23P01'; END IF;

  INSERT INTO crew_leave (tenant_id, crew_id, kind, start_date, end_date, status, reason, via, requested_by, decision_seen)
  VALUES (v_tenant, v_crew, p_kind, p_start, v_end, 'pending', NULLIF(btrim(COALESCE(p_reason, '')), ''), 'crew', v_uid, true)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION leave_my_request(text, date, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leave_my_request(text, date, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION leave_my_cancel(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_crew uuid := leave_my_crew_id();
  l crew_leave;
BEGIN
  IF v_crew IS NULL THEN RAISE EXCEPTION 'Not found.' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO l FROM crew_leave WHERE id = p_id AND crew_id = v_crew FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not found.' USING ERRCODE = 'P0002'; END IF;
  IF l.status = 'cancelled' THEN RETURN; END IF;
  IF l.status = 'declined' THEN RAISE EXCEPTION 'That request was already declined.' USING ERRCODE = '22023'; END IF;
  IF l.status = 'approved' AND l.start_date <= current_date THEN
    RAISE EXCEPTION 'Leave that has started can only be changed by your roster officer.' USING ERRCODE = '22023';
  END IF;
  UPDATE crew_leave SET status = 'cancelled', decision_seen = true, updated_at = now() WHERE id = p_id;
END;
$$;
REVOKE ALL ON FUNCTION leave_my_cancel(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leave_my_cancel(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION leave_my_unseen_count()
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT count(*)::int FROM crew_leave l WHERE l.crew_id = leave_my_crew_id() AND l.decision_seen IS FALSE;
$$;
REVOKE ALL ON FUNCTION leave_my_unseen_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leave_my_unseen_count() TO authenticated;

CREATE OR REPLACE FUNCTION leave_my_mark_seen()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  UPDATE crew_leave SET decision_seen = true WHERE crew_id = leave_my_crew_id() AND decision_seen IS FALSE;
$$;
REVOKE ALL ON FUNCTION leave_my_mark_seen() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leave_my_mark_seen() TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Verification
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('crew_documents') IS NULL OR to_regclass('crew_leave') IS NULL
     OR to_regprocedure('crew_expiry_overview(int)') IS NULL
     OR to_regprocedure('leave_my_request(text,date,date,text)') IS NULL
     OR to_regprocedure('crew_dir_check(uuid,date)') IS NULL THEN
    RAISE EXCEPTION 'Migration 29: objects not found';
  END IF;
  RAISE NOTICE 'Migration 29 verified: documents, expiries, leave and availability ready.';
END;
$$;
