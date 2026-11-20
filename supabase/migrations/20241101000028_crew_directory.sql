-- =============================================================================
-- Migration: 20241101000028_crew_directory.sql
-- Description: Crew Directory — crew exist as records BEFORE they have an
--              account or a roster.
--
--   crew_directory            – one row per crew member (code, name, rank,
--                               base, status, contacts, notes, link to account)
--   crew_dir_list()           – the directory, with account + roster summary
--   crew_dir_save()           – create / edit one crew member (audited)
--   crew_dir_archive()        – archive / restore (nobody is ever deleted)
--   crew_dir_merge()          – fold a duplicate record into another
--   crew_dir_link/unlink()    – tie a record to a signed-up account
--   crew_dir_accounts()       – accounts that are not linked to a record yet
--   crew_dir_import()         – bulk create / update from CSV rows
--   crew_dir_claim_self()     – called by the app at sign-in: links the
--                               signed-in crew member to their record
--                               (confirmed-email match) or creates one
--
-- Access: roster officers and administrators of the same airline only. The
-- table has no direct policies — everything goes through the functions.
-- Existing airline crew accounts are backfilled into the directory.
-- Requires migrations 17, 24 and 26. Safe to re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('roster_is_officer()') IS NULL
     OR to_regprocedure('is_staff_role(text)') IS NULL
     OR to_regclass('admin_audit_log') IS NULL THEN
    RAISE EXCEPTION 'Migration 28 requires migrations 17, 24 and 26.';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crew_directory (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,
  crew_code       text,
  full_name       text        NOT NULL,
  staff_number    text,
  rank            text,
  base            text,
  status          text        NOT NULL DEFAULT 'active',
  join_date       date,
  seniority_no    int,
  email           text,
  phone           text,
  emergency_name  text,
  emergency_phone text,
  languages       text,
  nationality     text,
  notes           text,
  user_id         uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  archived_at     timestamptz,
  created_by      uuid        REFERENCES profiles(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crew_directory_status_check CHECK (status IN ('active','on_leave','probation','suspended','resigned')),
  CONSTRAINT crew_directory_base_check   CHECK (base IS NULL OR base ~ '^[A-Z]{3}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS crew_directory_code_uniq
  ON crew_directory (tenant_id, upper(crew_code)) WHERE crew_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS crew_directory_user_uniq
  ON crew_directory (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS crew_directory_tenant_name
  ON crew_directory (tenant_id, lower(full_name));

ALTER TABLE crew_directory ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON crew_directory FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (not callable by the app)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_dir_log(p_action text, p_target uuid, p_label text, p_details jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label, details)
  VALUES (guestora_resolve_tenant_id(), auth.uid(),
          (SELECT full_name FROM profiles WHERE id = auth.uid()),
          p_action, p_target, p_label, COALESCE(p_details, '{}'::jsonb));
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_log(text, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;

-- The roster guard (migration 17) stops non-officers re-assigning a roster.
-- A crew member's own record link hands over rosters waiting for their code,
-- so the guard honours a transaction-local flag that only the link function sets.
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
    IF COALESCE(current_setting('ccl.dir_attach', true), '0') = '1'
       AND OLD.crew_user_id IS NULL THEN
      NEW.source      := OLD.source;
      NEW.uploaded_by := OLD.uploaded_by;
    ELSE
      NEW.crew_user_id := OLD.crew_user_id;
      NEW.source       := OLD.source;
      NEW.uploaded_by  := OLD.uploaded_by;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Tie a record to an account, copy what the account lacks, hand over any rosters
-- that were waiting for the record's code.
CREATE OR REPLACE FUNCTION crew_dir_apply_link(p_dir uuid, p_user uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  d crew_directory;
  p profiles;
BEGIN
  SELECT * INTO d FROM crew_directory WHERE id = p_dir FOR UPDATE;
  SELECT * INTO p FROM profiles WHERE id = p_user;

  UPDATE crew_directory SET user_id = p_user, updated_at = now() WHERE id = p_dir;

  PERFORM set_config('ccl.dir_sync', '1', true);
  IF d.crew_code IS NOT NULL
     AND p.crew_code IS DISTINCT FROM d.crew_code
     AND NOT EXISTS (SELECT 1 FROM profiles o
                      WHERE o.tenant_id = d.tenant_id AND o.user_class = 'airline'
                        AND upper(o.crew_code) = upper(d.crew_code) AND o.id <> p_user) THEN
    UPDATE profiles SET crew_code = d.crew_code WHERE id = p_user;
  END IF;
  IF d.rank IS NOT NULL AND NULLIF(btrim(COALESCE(p.position, '')), '') IS NULL THEN
    UPDATE profiles SET position = d.rank WHERE id = p_user;
  END IF;
  PERFORM set_config('ccl.dir_sync', '0', true);

  IF d.crew_code IS NOT NULL THEN
    PERFORM set_config('ccl.dir_attach', '1', true);
    UPDATE crew_rosters r SET crew_user_id = p_user
     WHERE r.tenant_id = d.tenant_id AND r.crew_user_id IS NULL
       AND upper(btrim(r.crew_code)) = upper(d.crew_code);
    PERFORM set_config('ccl.dir_attach', '0', true);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_apply_link(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. crew_dir_save — create or edit (only the keys present are changed)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_dir_save_internal(p_id uuid, p_data jsonb, p_audit boolean)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_new    boolean := (p_id IS NULL);
  o        crew_directory%ROWTYPE;   -- current values (all null for a new record)
  n_name text; n_code text; n_staff text; n_rank text; n_base text; n_status text;
  n_join date; n_sen int; n_email text; n_phone text; n_en text; n_ep text;
  n_lang text; n_nat text; n_notes text;
  v_other text;
  v_changed text[] := ARRAY[]::text[];
  v_id uuid;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION 'Nothing to save.' USING ERRCODE = '22023';
  END IF;

  IF NOT v_new THEN
    SELECT * INTO o FROM crew_directory WHERE id = p_id AND tenant_id = v_tenant FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  END IF;

  n_name  := CASE WHEN p_data ? 'full_name'       THEN NULLIF(btrim(p_data->>'full_name'), '')       ELSE o.full_name END;
  n_code  := CASE WHEN p_data ? 'crew_code'       THEN NULLIF(upper(btrim(p_data->>'crew_code')), '') ELSE o.crew_code END;
  n_staff := CASE WHEN p_data ? 'staff_number'    THEN NULLIF(btrim(p_data->>'staff_number'), '')    ELSE o.staff_number END;
  n_rank  := CASE WHEN p_data ? 'rank'            THEN NULLIF(btrim(p_data->>'rank'), '')            ELSE o.rank END;
  n_base  := CASE WHEN p_data ? 'base'            THEN NULLIF(upper(btrim(p_data->>'base')), '')     ELSE o.base END;
  n_status:= CASE WHEN p_data ? 'status'          THEN COALESCE(NULLIF(btrim(p_data->>'status'), ''), 'active')
                  ELSE COALESCE(o.status, 'active') END;
  n_email := CASE WHEN p_data ? 'email'           THEN NULLIF(lower(btrim(p_data->>'email')), '')    ELSE o.email END;
  n_phone := CASE WHEN p_data ? 'phone'           THEN NULLIF(btrim(p_data->>'phone'), '')           ELSE o.phone END;
  n_en    := CASE WHEN p_data ? 'emergency_name'  THEN NULLIF(btrim(p_data->>'emergency_name'), '')  ELSE o.emergency_name END;
  n_ep    := CASE WHEN p_data ? 'emergency_phone' THEN NULLIF(btrim(p_data->>'emergency_phone'), '') ELSE o.emergency_phone END;
  n_lang  := CASE WHEN p_data ? 'languages'       THEN NULLIF(btrim(p_data->>'languages'), '')       ELSE o.languages END;
  n_nat   := CASE WHEN p_data ? 'nationality'     THEN NULLIF(btrim(p_data->>'nationality'), '')     ELSE o.nationality END;
  n_notes := CASE WHEN p_data ? 'notes'           THEN NULLIF(btrim(p_data->>'notes'), '')           ELSE o.notes END;

  BEGIN
    n_join := CASE WHEN p_data ? 'join_date' THEN NULLIF(btrim(p_data->>'join_date'), '')::date ELSE o.join_date END;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Join date must look like 2025-03-31.' USING ERRCODE = '22007';
  END;
  BEGIN
    n_sen := CASE WHEN p_data ? 'seniority_no' THEN NULLIF(btrim(p_data->>'seniority_no'), '')::int ELSE o.seniority_no END;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Seniority number must be a whole number.' USING ERRCODE = '22023';
  END;

  IF n_name IS NULL THEN RAISE EXCEPTION 'A name is required.' USING ERRCODE = '22023'; END IF;
  IF length(n_name) > 120 THEN RAISE EXCEPTION 'That name is too long.' USING ERRCODE = '22023'; END IF;
  IF n_code IS NOT NULL AND n_code !~ '^[A-Z0-9][A-Z0-9._-]{0,19}$' THEN
    RAISE EXCEPTION 'A crew code can contain letters, numbers, dot, dash and underscore (max 20).' USING ERRCODE = '22023';
  END IF;
  IF n_base IS NOT NULL AND n_base !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'A base is a 3-letter station code, e.g. EBB.' USING ERRCODE = '22023';
  END IF;
  IF n_status NOT IN ('active','on_leave','probation','suspended','resigned') THEN
    RAISE EXCEPTION 'Unknown status.' USING ERRCODE = '22023';
  END IF;
  IF n_email IS NOT NULL AND n_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'That email address does not look right.' USING ERRCODE = '22023';
  END IF;

  IF n_code IS NOT NULL THEN
    SELECT d.full_name INTO v_other FROM crew_directory d
     WHERE d.tenant_id = v_tenant AND upper(d.crew_code) = n_code AND d.id IS DISTINCT FROM p_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION '% is already used by %.', n_code, v_other USING ERRCODE = '23505'; END IF;
    SELECT COALESCE(NULLIF(btrim(x.crew_name), ''), NULLIF(btrim(x.full_name), ''), 'another account') INTO v_other
      FROM profiles x
     WHERE x.tenant_id = v_tenant AND x.user_class = 'airline' AND upper(x.crew_code) = n_code
       AND x.id IS DISTINCT FROM o.user_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION '% is already on the account of % — link that account to this record instead.', n_code, v_other
        USING ERRCODE = '23505';
    END IF;
  END IF;
  IF n_email IS NOT NULL THEN
    SELECT d.full_name INTO v_other FROM crew_directory d
     WHERE d.tenant_id = v_tenant AND lower(d.email) = n_email AND d.archived_at IS NULL
       AND d.id IS DISTINCT FROM p_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'The email % is already on the record of %.', n_email, v_other USING ERRCODE = '23505'; END IF;
  END IF;

  IF v_new THEN
    INSERT INTO crew_directory (tenant_id, crew_code, full_name, staff_number, rank, base, status, join_date,
                                seniority_no, email, phone, emergency_name, emergency_phone, languages,
                                nationality, notes, created_by)
    VALUES (v_tenant, n_code, n_name, n_staff, n_rank, n_base, n_status, n_join, n_sen, n_email, n_phone,
            n_en, n_ep, n_lang, n_nat, n_notes, auth.uid())
    RETURNING id INTO v_id;
    IF p_audit THEN
      PERFORM crew_dir_log('crew_added', v_id, n_name, jsonb_build_object('code', n_code));
    END IF;
    RETURN v_id;
  END IF;

  IF n_name   IS DISTINCT FROM o.full_name       THEN v_changed := array_append(v_changed, 'name'); END IF;
  IF n_code   IS DISTINCT FROM o.crew_code       THEN v_changed := array_append(v_changed, 'code'); END IF;
  IF n_staff  IS DISTINCT FROM o.staff_number    THEN v_changed := array_append(v_changed, 'staff number'); END IF;
  IF n_rank   IS DISTINCT FROM o.rank            THEN v_changed := array_append(v_changed, 'rank'); END IF;
  IF n_base   IS DISTINCT FROM o.base            THEN v_changed := array_append(v_changed, 'base'); END IF;
  IF n_status IS DISTINCT FROM o.status          THEN v_changed := array_append(v_changed, 'status'); END IF;
  IF n_join   IS DISTINCT FROM o.join_date       THEN v_changed := array_append(v_changed, 'join date'); END IF;
  IF n_sen    IS DISTINCT FROM o.seniority_no    THEN v_changed := array_append(v_changed, 'seniority'); END IF;
  IF n_email  IS DISTINCT FROM o.email           THEN v_changed := array_append(v_changed, 'email'); END IF;
  IF n_phone  IS DISTINCT FROM o.phone           THEN v_changed := array_append(v_changed, 'phone'); END IF;
  IF n_en IS DISTINCT FROM o.emergency_name OR n_ep IS DISTINCT FROM o.emergency_phone
                                                 THEN v_changed := array_append(v_changed, 'emergency contact'); END IF;
  IF n_lang   IS DISTINCT FROM o.languages       THEN v_changed := array_append(v_changed, 'languages'); END IF;
  IF n_nat    IS DISTINCT FROM o.nationality     THEN v_changed := array_append(v_changed, 'nationality'); END IF;
  IF n_notes  IS DISTINCT FROM o.notes           THEN v_changed := array_append(v_changed, 'notes'); END IF;

  IF cardinality(v_changed) = 0 THEN RETURN p_id; END IF;

  UPDATE crew_directory SET
         full_name = n_name, crew_code = n_code, staff_number = n_staff, rank = n_rank, base = n_base,
         status = n_status, join_date = n_join, seniority_no = n_sen, email = n_email, phone = n_phone,
         emergency_name = n_en, emergency_phone = n_ep, languages = n_lang, nationality = n_nat,
         notes = n_notes, updated_at = now()
   WHERE id = p_id;

  -- Keep a linked account in step: the roster system matches on the profile's code.
  IF o.user_id IS NOT NULL THEN
    PERFORM set_config('ccl.dir_sync', '1', true);
    IF n_code IS DISTINCT FROM o.crew_code THEN
      UPDATE profiles SET crew_code = n_code WHERE id = o.user_id;
      IF n_code IS NOT NULL THEN
        UPDATE crew_rosters r SET crew_user_id = o.user_id
         WHERE r.tenant_id = v_tenant AND r.crew_user_id IS NULL
           AND upper(btrim(r.crew_code)) = n_code;
      END IF;
    END IF;
    IF n_rank IS DISTINCT FROM o.rank THEN
      UPDATE profiles SET position = n_rank WHERE id = o.user_id;
    END IF;
    PERFORM set_config('ccl.dir_sync', '0', true);
  END IF;

  IF p_audit THEN
    -- A linked account's code change is already logged by the profile trigger.
    IF n_code IS DISTINCT FROM o.crew_code AND o.user_id IS NULL THEN
      PERFORM crew_dir_log('crew_code_changed', p_id, n_name, jsonb_build_object('from', o.crew_code, 'to', n_code));
    END IF;
    IF cardinality(array_remove(v_changed, 'code')) > 0 THEN
      PERFORM crew_dir_log('crew_updated', p_id, n_name,
        jsonb_build_object('fields', to_jsonb(array_remove(v_changed, 'code')))
        || CASE WHEN n_status IS DISTINCT FROM o.status
                THEN jsonb_build_object('status_from', o.status, 'status_to', n_status) ELSE '{}'::jsonb END);
    END IF;
  END IF;
  RETURN p_id;
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_save_internal(uuid, jsonb, boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION crew_dir_save(p_id uuid, p_data jsonb)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$ SELECT crew_dir_save_internal(p_id, p_data, true); $$;
REVOKE ALL ON FUNCTION crew_dir_save(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_save(uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. crew_dir_list
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS crew_dir_list(boolean);
CREATE FUNCTION crew_dir_list(p_include_archived boolean DEFAULT false)
RETURNS TABLE (
  id uuid, crew_code text, full_name text, staff_number text, rank text, base text, status text,
  join_date date, seniority_no int, email text, phone text, emergency_name text, emergency_phone text,
  languages text, nationality text, notes text, user_id uuid, archived_at timestamptz,
  account_state text, last_seen_at timestamptz, roster_count int, latest_to date, waiting_rosters int,
  created_at timestamptz
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
    RAISE EXCEPTION 'Only roster officers and administrators can open the crew directory.' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT d.id, d.crew_code, d.full_name, d.staff_number, d.rank, d.base, d.status,
         d.join_date, d.seniority_no, d.email, d.phone, d.emergency_name, d.emergency_phone,
         d.languages, d.nationality, d.notes, d.user_id, d.archived_at,
         CASE WHEN d.user_id IS NULL THEN 'none'
              WHEN p.blocked IS TRUE THEN 'blocked' ELSE 'active' END,
         p.last_seen_at,
         COALESCE(r.cnt, 0)::int, r.latest_to,
         COALESCE(w.cnt, 0)::int,
         d.created_at
    FROM crew_directory d
    LEFT JOIN profiles p ON p.id = d.user_id
    LEFT JOIN LATERAL (
      SELECT count(*) AS cnt, max(cr.period_to) AS latest_to
        FROM crew_rosters cr
       WHERE cr.tenant_id = v_tenant AND d.user_id IS NOT NULL AND cr.crew_user_id = d.user_id
    ) r ON true
    LEFT JOIN LATERAL (
      SELECT count(*) AS cnt
        FROM crew_rosters cr
       WHERE cr.tenant_id = v_tenant AND cr.crew_user_id IS NULL AND d.crew_code IS NOT NULL
         AND upper(btrim(cr.crew_code)) = upper(d.crew_code)
    ) w ON true
   WHERE d.tenant_id = v_tenant
     AND (p_include_archived OR d.archived_at IS NULL)
   ORDER BY lower(d.full_name);
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_list(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_list(boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. archive / restore
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_dir_archive(p_id uuid, p_archive boolean DEFAULT true)
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
  SELECT * INTO d FROM crew_directory WHERE id = p_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  IF (d.archived_at IS NOT NULL) = COALESCE(p_archive, true) THEN RETURN; END IF;

  UPDATE crew_directory
     SET archived_at = CASE WHEN COALESCE(p_archive, true) THEN now() ELSE NULL END, updated_at = now()
   WHERE id = p_id;
  PERFORM crew_dir_log(CASE WHEN COALESCE(p_archive, true) THEN 'crew_archived' ELSE 'crew_restored' END,
                       p_id, d.full_name, '{}'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_archive(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_archive(uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. accounts that are not in the directory link yet
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS crew_dir_accounts();
CREATE FUNCTION crew_dir_accounts()
RETURNS TABLE (user_id uuid, display_name text, email text, crew_code text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT p.id, COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), 'Unnamed'),
         p.email, p.crew_code
    FROM profiles p
   WHERE p.tenant_id = v_tenant AND p.user_class = 'airline' AND NOT is_staff_role(p.role)
     AND NOT EXISTS (SELECT 1 FROM crew_directory d WHERE d.user_id = p.id)
   ORDER BY 2;
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_accounts() TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. link / unlink an account
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_dir_link(p_id uuid, p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  d crew_directory;
  v_label text;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO d FROM crew_directory WHERE id = p_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  IF d.user_id IS NOT NULL THEN
    RAISE EXCEPTION '% already has an account linked. Unlink it first.', d.full_name USING ERRCODE = '23505';
  END IF;
  SELECT COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), p.email) INTO v_label
    FROM profiles p
   WHERE p.id = p_user_id AND p.tenant_id = v_tenant AND p.user_class = 'airline' AND NOT is_staff_role(p.role);
  IF NOT FOUND THEN RAISE EXCEPTION 'That account is not a crew account in your airline.' USING ERRCODE = '42501'; END IF;
  IF EXISTS (SELECT 1 FROM crew_directory x WHERE x.user_id = p_user_id) THEN
    RAISE EXCEPTION 'That account is already linked to another crew record.' USING ERRCODE = '23505';
  END IF;

  PERFORM crew_dir_apply_link(p_id, p_user_id);
  PERFORM crew_dir_log('crew_linked', p_id, d.full_name, jsonb_build_object('account', v_label));
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_link(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_link(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION crew_dir_unlink(p_id uuid)
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
  SELECT * INTO d FROM crew_directory WHERE id = p_id AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  IF d.user_id IS NULL THEN RETURN; END IF;
  UPDATE crew_directory SET user_id = NULL, updated_at = now() WHERE id = p_id;
  PERFORM crew_dir_log('crew_unlinked', p_id, d.full_name, '{}'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_unlink(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_unlink(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. merge a duplicate (p_drop) into the record to keep (p_keep)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_dir_merge(p_keep uuid, p_drop uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  k crew_directory;
  d crew_directory;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF p_keep = p_drop THEN RAISE EXCEPTION 'Pick two different records.' USING ERRCODE = '22023'; END IF;
  SELECT * INTO k FROM crew_directory WHERE id = p_keep AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO d FROM crew_directory WHERE id = p_drop AND tenant_id = v_tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Crew member not found.' USING ERRCODE = 'P0002'; END IF;
  IF k.user_id IS NOT NULL AND d.user_id IS NOT NULL THEN
    RAISE EXCEPTION 'Both records have their own account, so they cannot be merged.' USING ERRCODE = '23505';
  END IF;

  -- Free the unique keys first, then fill the survivor's blanks from the duplicate.
  UPDATE crew_directory SET crew_code = NULL, email = NULL, user_id = NULL WHERE id = p_drop;
  UPDATE crew_directory SET
         crew_code       = COALESCE(k.crew_code, d.crew_code),
         staff_number    = COALESCE(k.staff_number, d.staff_number),
         rank            = COALESCE(k.rank, d.rank),
         base            = COALESCE(k.base, d.base),
         join_date       = COALESCE(k.join_date, d.join_date),
         seniority_no    = COALESCE(k.seniority_no, d.seniority_no),
         email           = COALESCE(k.email, d.email),
         phone           = COALESCE(k.phone, d.phone),
         emergency_name  = COALESCE(k.emergency_name, d.emergency_name),
         emergency_phone = COALESCE(k.emergency_phone, d.emergency_phone),
         languages       = COALESCE(k.languages, d.languages),
         nationality     = COALESCE(k.nationality, d.nationality),
         notes           = CASE WHEN k.notes IS NOT NULL AND d.notes IS NOT NULL AND k.notes <> d.notes
                                THEN k.notes || E'\n' || d.notes ELSE COALESCE(k.notes, d.notes) END,
         updated_at      = now()
   WHERE id = p_keep;

  IF k.user_id IS NULL AND d.user_id IS NOT NULL THEN
    PERFORM crew_dir_apply_link(p_keep, d.user_id);
  END IF;

  -- Rosters waiting under the duplicate's old code now wait under the survivor's code.
  IF d.crew_code IS NOT NULL AND COALESCE(k.crew_code, d.crew_code) IS DISTINCT FROM d.crew_code THEN
    UPDATE crew_rosters r
       SET crew_code = COALESCE(k.crew_code, d.crew_code)
     WHERE r.tenant_id = v_tenant AND r.crew_user_id IS NULL
       AND upper(btrim(r.crew_code)) = upper(d.crew_code);
  END IF;

  DELETE FROM crew_directory WHERE id = p_drop;
  PERFORM crew_dir_log('crew_merged', p_keep, k.full_name, jsonb_build_object('merged', d.full_name, 'merged_code', d.crew_code));
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_merge(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_merge(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 9. bulk import — one result per row; a bad row never stops the others
--    Match order: crew code, then email. Only the fields given are changed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_dir_import(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_tenant uuid := guestora_resolve_tenant_id();
  v_out    jsonb := '[]'::jsonb;
  v_row    jsonb;
  v_i      int := 0;
  v_id     uuid;
  v_code   text;
  v_email  text;
  v_new    int := 0;
  v_upd    int := 0;
BEGIN
  IF NOT roster_is_officer() THEN
    RAISE EXCEPTION 'Only roster officers and administrators can manage crew.' USING ERRCODE = '42501';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'Nothing to import.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_rows) > 500 THEN
    RAISE EXCEPTION 'Import at most 500 crew at a time.' USING ERRCODE = '22023';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_i := v_i + 1;
    BEGIN
      v_id := NULL;
      v_code  := NULLIF(upper(btrim(COALESCE(v_row->>'crew_code', ''))), '');
      v_email := NULLIF(lower(btrim(COALESCE(v_row->>'email', ''))), '');
      IF v_code IS NOT NULL THEN
        SELECT d.id INTO v_id FROM crew_directory d WHERE d.tenant_id = v_tenant AND upper(d.crew_code) = v_code;
      END IF;
      IF v_id IS NULL AND v_email IS NOT NULL THEN
        SELECT d.id INTO v_id FROM crew_directory d
         WHERE d.tenant_id = v_tenant AND lower(d.email) = v_email AND d.archived_at IS NULL LIMIT 1;
      END IF;

      IF v_id IS NULL THEN
        IF NULLIF(btrim(COALESCE(v_row->>'full_name', '')), '') IS NULL THEN
          RAISE EXCEPTION 'A name is required for a new crew member.';
        END IF;
        PERFORM crew_dir_save_internal(NULL, v_row, false);
        v_new := v_new + 1;
        v_out := v_out || jsonb_build_object('row', v_i, 'result', 'created');
      ELSE
        -- Blank cells must not wipe existing data on an update.
        PERFORM crew_dir_save_internal(v_id,
          (SELECT COALESCE(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
             FROM jsonb_each(v_row) e WHERE NULLIF(btrim(e.value #>> '{}'), '') IS NOT NULL),
          false);
        v_upd := v_upd + 1;
        v_out := v_out || jsonb_build_object('row', v_i, 'result', 'updated');
      END IF;
    EXCEPTION WHEN others THEN
      v_out := v_out || jsonb_build_object('row', v_i, 'result', 'error', 'message', SQLERRM);
    END;
  END LOOP;

  PERFORM crew_dir_log('crew_imported', NULL, 'Crew directory import',
                       jsonb_build_object('created', v_new, 'updated', v_upd,
                                          'failed', v_i - v_new - v_upd));
  RETURN v_out;
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_import(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_import(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 10. crew_dir_claim_self — the signed-in crew member's record
--     Linked by a CONFIRMED email match only (never by typing a crew code).
--     No record at all → one is created so every crew member is in the list.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_dir_claim_self()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  p       profiles;
  v_id    uuid;
  v_conf  boolean := false;
  v_email text;
  v_code  text;
BEGIN
  IF v_uid IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO p FROM profiles WHERE id = v_uid;
  IF NOT FOUND OR p.user_class IS DISTINCT FROM 'airline' OR p.tenant_id IS NULL
     OR is_staff_role(p.role) THEN
    RETURN NULL;
  END IF;

  SELECT d.id INTO v_id FROM crew_directory d WHERE d.user_id = v_uid;
  IF FOUND THEN RETURN v_id; END IF;

  SELECT (u.email_confirmed_at IS NOT NULL), lower(u.email) INTO v_conf, v_email
    FROM auth.users u WHERE u.id = v_uid;

  IF COALESCE(v_conf, false) AND v_email IS NOT NULL THEN
    SELECT d.id INTO v_id FROM crew_directory d
     WHERE d.tenant_id = p.tenant_id AND d.user_id IS NULL AND d.archived_at IS NULL
       AND lower(d.email) = v_email
     ORDER BY d.created_at LIMIT 1;
    IF FOUND THEN
      PERFORM crew_dir_apply_link(v_id, v_uid);
      INSERT INTO admin_audit_log (tenant_id, actor_id, actor_name, action, target_id, target_label, details)
      SELECT p.tenant_id, v_uid, COALESCE(p.full_name, v_email), 'crew_linked', d.id, d.full_name,
             jsonb_build_object('account', COALESCE(p.full_name, v_email), 'by', 'email match')
        FROM crew_directory d WHERE d.id = v_id;
      RETURN v_id;
    END IF;
  END IF;

  -- No record yet: create one from the account. A code someone else already
  -- holds is left off, so the officer sees the person and can link them.
  v_code := NULLIF(upper(btrim(COALESCE(p.crew_code, ''))), '');
  IF v_code IS NOT NULL AND EXISTS (SELECT 1 FROM crew_directory d
                                     WHERE d.tenant_id = p.tenant_id AND upper(d.crew_code) = v_code) THEN
    v_code := NULL;
  END IF;
  INSERT INTO crew_directory (tenant_id, crew_code, full_name, rank, email, phone, user_id)
  VALUES (p.tenant_id, v_code,
          COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), v_email, 'Unnamed crew'),
          NULLIF(btrim(COALESCE(p.position, '')), ''), v_email, p.phone, v_uid)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION crew_dir_claim_self() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION crew_dir_claim_self() TO authenticated;

-- ---------------------------------------------------------------------------
-- 11. Keep the directory code in step when an officer edits it on a profile
--     (for example from the Roster Desk)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION profiles_sync_directory_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF COALESCE(current_setting('ccl.dir_sync', true), '0') = '1' THEN RETURN NULL; END IF;
  IF NEW.crew_code IS NOT DISTINCT FROM OLD.crew_code THEN RETURN NULL; END IF;
  UPDATE crew_directory d
     SET crew_code = NULLIF(upper(btrim(COALESCE(NEW.crew_code, ''))), ''), updated_at = now()
   WHERE d.user_id = NEW.id
     AND NOT EXISTS (SELECT 1 FROM crew_directory o
                      WHERE o.tenant_id = d.tenant_id AND o.id <> d.id
                        AND upper(o.crew_code) = upper(NEW.crew_code));
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS profiles_sync_directory_code ON profiles;
CREATE TRIGGER profiles_sync_directory_code
  AFTER UPDATE OF crew_code ON profiles
  FOR EACH ROW EXECUTE FUNCTION profiles_sync_directory_code();

-- ---------------------------------------------------------------------------
-- 12. Backfill: every existing airline crew account gets a record
-- ---------------------------------------------------------------------------
INSERT INTO crew_directory (tenant_id, crew_code, full_name, rank, base, status, email, phone, user_id)
SELECT p.tenant_id,
       NULLIF(upper(btrim(COALESCE(p.crew_code, ''))), ''),
       COALESCE(NULLIF(btrim(p.crew_name), ''), NULLIF(btrim(p.full_name), ''), NULLIF(lower(btrim(COALESCE(p.email,''))), ''), 'Unnamed crew'),
       NULLIF(btrim(COALESCE(p.position, '')), ''),
       p.base,
       CASE WHEN p.blocked IS TRUE THEN 'suspended' ELSE 'active' END,
       NULLIF(lower(btrim(COALESCE(p.email, ''))), ''),
       p.phone,
       p.id
  FROM profiles p
 WHERE p.user_class = 'airline' AND p.tenant_id IS NOT NULL AND NOT is_staff_role(p.role)
   AND NOT EXISTS (SELECT 1 FROM crew_directory d WHERE d.user_id = p.id)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 13. Verification
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('crew_directory') IS NULL
     OR to_regprocedure('crew_dir_list(boolean)') IS NULL
     OR to_regprocedure('crew_dir_save(uuid,jsonb)') IS NULL
     OR to_regprocedure('crew_dir_claim_self()') IS NULL THEN
    RAISE EXCEPTION 'Migration 28: objects not found';
  END IF;
  RAISE NOTICE 'Migration 28 verified: crew directory ready (% records).', (SELECT count(*) FROM crew_directory);
END;
$$;
