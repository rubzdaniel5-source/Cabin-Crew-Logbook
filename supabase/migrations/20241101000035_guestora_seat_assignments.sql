-- 35: Guestora manual seat assignment.
-- Cabin crew can seat passengers who have no seat on the manifest, move a
-- passenger to another seat, swap two passengers, unseat, and add walk-up /
-- standby passengers. Stored as an OVERLAY on top of the uploaded manifest, so a
-- re-upload by a check-in agent never wipes crew's manual work. Any crew on the
-- same flight + date can read and change it (same eligibility as orders).

CREATE TABLE IF NOT EXISTS guestora_seat_assignments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES guestora_tenants(id) ON DELETE RESTRICT,
  flight_number    text NOT NULL,
  flight_date      date NOT NULL,
  pax_key          text NOT NULL,                  -- 'm:<NAME>' for a manifest passenger, 'x:<id>' for a walk-up
  pax_name         text NOT NULL,
  cabin            text,
  kind             text NOT NULL DEFAULT 'manifest' CHECK (kind IN ('manifest','walkup')),
  seat             text CHECK (seat IS NULL OR seat ~ '^[0-9]{1,2}[A-Z]$'),   -- NULL = deliberately unseated
  assigned_by      uuid REFERENCES profiles(id) ON DELETE SET NULL,
  assigned_by_name text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gs_seat_pax_unique UNIQUE (tenant_id, flight_number, flight_date, pax_key)
);
-- one passenger per seat among overrides
CREATE UNIQUE INDEX IF NOT EXISTS gs_seat_seat_unique
  ON guestora_seat_assignments (tenant_id, flight_number, flight_date, seat) WHERE seat IS NOT NULL;

ALTER TABLE guestora_seat_assignments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON guestora_seat_assignments FROM anon, authenticated;   -- reached only through the functions below

-- ---------- helpers ----------
CREATE OR REPLACE FUNCTION gs_pax_key(p_name text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT 'm:' || upper(regexp_replace(btrim(COALESCE(p_name,'')), '\s+', ' ', 'g')) $$;

CREATE OR REPLACE FUNCTION gs_norm_seat(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT NULLIF(regexp_replace(upper(btrim(COALESCE(p,''))), '^0+(?=[0-9])', ''), '') $$;

-- manifest passengers merged with overrides: who really sits where
CREATE OR REPLACE FUNCTION gs_seat_effective(p_tenant uuid, p_flight text, p_date date)
RETURNS TABLE(pax_key text, pax_name text, cabin text, seat text, kind text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  WITH mf AS (
    SELECT gs_pax_key(e->>'name') AS k, btrim(e->>'name') AS n, e->>'cabin' AS c, gs_norm_seat(e->>'seat') AS s
      FROM (SELECT passengers FROM passenger_manifests
             WHERE tenant_id = p_tenant AND flight_number = p_flight AND flight_date = p_date
             ORDER BY created_at DESC LIMIT 1) m,
           LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(m.passengers) = 'array' THEN m.passengers ELSE '[]'::jsonb END) e
     WHERE btrim(COALESCE(e->>'name','')) <> ''
  ), ov AS (
    SELECT * FROM guestora_seat_assignments WHERE tenant_id = p_tenant AND flight_number = p_flight AND flight_date = p_date
  )
  SELECT COALESCE(ov.pax_key, mf.k), COALESCE(ov.pax_name, mf.n), COALESCE(ov.cabin, mf.c),
         CASE WHEN ov.id IS NOT NULL THEN ov.seat ELSE mf.s END,
         COALESCE(ov.kind, 'manifest')
    FROM mf FULL JOIN ov ON ov.pax_key = mf.k;
$$;

CREATE OR REPLACE FUNCTION gs_seat_guard(p_flight text, p_date date) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_t uuid := guestora_resolve_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_t IS NULL OR NOT guestora_check_flight_eligibility(p_flight, p_date) THEN
    RAISE EXCEPTION 'You are not rostered on this flight.' USING ERRCODE = '42501';
  END IF;
  RETURN v_t;
END $$;

-- ---------- read ----------
CREATE OR REPLACE FUNCTION gs_seat_list(p_flight text, p_date date)
RETURNS TABLE(pax_key text, pax_name text, cabin text, seat text, kind text, assigned_by_name text, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_f text := upper(btrim(p_flight)); v_t uuid;
BEGIN
  v_t := gs_seat_guard(v_f, p_date);
  RETURN QUERY
  SELECT a.pax_key, a.pax_name, a.cabin, a.seat, a.kind, a.assigned_by_name, a.updated_at
    FROM guestora_seat_assignments a
   WHERE a.tenant_id = v_t AND a.flight_number = v_f AND a.flight_date = p_date
   ORDER BY a.updated_at;
END $$;

-- ---------- write ----------
-- Seat (or unseat, when p_seat is NULL) one passenger. If the seat is taken the call fails with
-- SEAT_TAKEN unless p_swap is true, in which case the two passengers trade places.
CREATE OR REPLACE FUNCTION gs_seat_set(p_flight text, p_date date, p_key text, p_name text, p_cabin text,
                                       p_kind text, p_seat text, p_swap boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE
  v_f text := upper(btrim(p_flight)); v_t uuid; v_seat text := gs_norm_seat(p_seat);
  v_actor text; v_name text := left(btrim(COALESCE(p_name,'')), 80);
  v_key text := btrim(COALESCE(p_key,''));
  v_kind text := COALESCE(NULLIF(p_kind,''), 'manifest');
  occ record; v_old text; v_status text; v_swapped text;
BEGIN
  v_t := gs_seat_guard(v_f, p_date);
  SELECT status INTO v_status FROM guestora_sessions
   WHERE tenant_id = v_t AND flight_number = v_f AND flight_date = p_date;
  IF v_status = 'closed' THEN RAISE EXCEPTION 'This flight''s session is closed.' USING ERRCODE = 'P0001'; END IF;
  IF v_kind NOT IN ('manifest','walkup') THEN RAISE EXCEPTION 'Bad passenger kind.' USING ERRCODE = '22023'; END IF;
  IF v_key = '' OR length(v_key) > 100 OR (v_kind = 'walkup' AND v_key !~ '^x:') OR (v_kind = 'manifest' AND v_key !~ '^m:') THEN
    RAISE EXCEPTION 'Bad passenger reference.' USING ERRCODE = '22023';
  END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'A passenger name is needed.' USING ERRCODE = '22023'; END IF;
  IF p_seat IS NOT NULL AND btrim(p_seat) <> '' AND (v_seat IS NULL OR v_seat !~ '^[0-9]{1,2}[A-Z]$') THEN
    RAISE EXCEPTION 'Seat must look like 12C.' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_t::text || v_f || p_date::text));
  SELECT full_name INTO v_actor FROM profiles WHERE id = auth.uid();

  -- a manifest passenger must really be on the manifest
  IF v_kind = 'manifest' AND NOT EXISTS (SELECT 1 FROM gs_seat_effective(v_t, v_f, p_date) e WHERE e.pax_key = v_key) THEN
    RAISE EXCEPTION 'That passenger is not on the manifest.' USING ERRCODE = 'P0002';
  END IF;

  SELECT e.seat INTO v_old FROM gs_seat_effective(v_t, v_f, p_date) e WHERE e.pax_key = v_key;

  IF v_seat IS NOT NULL THEN
    SELECT * INTO occ FROM gs_seat_effective(v_t, v_f, p_date) e WHERE e.seat = v_seat AND e.pax_key <> v_key LIMIT 1;
    IF FOUND THEN
      IF NOT p_swap THEN
        RAISE EXCEPTION 'SEAT_TAKEN: % is taken by %.', v_seat, occ.pax_name USING ERRCODE = 'P0001';
      END IF;
      v_swapped := occ.pax_name;
      -- occupant takes the mover's old seat (or is left unseated)
      UPDATE guestora_seat_assignments SET seat = NULL WHERE tenant_id = v_t AND flight_number = v_f
         AND flight_date = p_date AND pax_key = occ.pax_key;
      INSERT INTO guestora_seat_assignments (tenant_id, flight_number, flight_date, pax_key, pax_name, cabin, kind, seat, assigned_by, assigned_by_name)
      VALUES (v_t, v_f, p_date, occ.pax_key, occ.pax_name, occ.cabin, occ.kind, NULL, auth.uid(), v_actor)
      ON CONFLICT (tenant_id, flight_number, flight_date, pax_key) DO UPDATE SET seat = NULL, updated_at = now();
      -- free the mover's row first so the unique seat index is never violated
      INSERT INTO guestora_seat_assignments (tenant_id, flight_number, flight_date, pax_key, pax_name, cabin, kind, seat, assigned_by, assigned_by_name)
      VALUES (v_t, v_f, p_date, v_key, v_name, NULLIF(p_cabin,''), v_kind, NULL, auth.uid(), v_actor)
      ON CONFLICT (tenant_id, flight_number, flight_date, pax_key) DO UPDATE SET seat = NULL, updated_at = now();
      UPDATE guestora_seat_assignments SET seat = v_old, assigned_by = auth.uid(), assigned_by_name = v_actor, updated_at = now()
       WHERE tenant_id = v_t AND flight_number = v_f AND flight_date = p_date AND pax_key = occ.pax_key;
    END IF;
  END IF;

  INSERT INTO guestora_seat_assignments (tenant_id, flight_number, flight_date, pax_key, pax_name, cabin, kind, seat, assigned_by, assigned_by_name)
  VALUES (v_t, v_f, p_date, v_key, v_name, NULLIF(p_cabin,''), v_kind, v_seat, auth.uid(), v_actor)
  ON CONFLICT (tenant_id, flight_number, flight_date, pax_key)
  DO UPDATE SET seat = EXCLUDED.seat, cabin = COALESCE(EXCLUDED.cabin, guestora_seat_assignments.cabin),
                assigned_by = auth.uid(), assigned_by_name = v_actor, updated_at = now();

  RETURN jsonb_build_object('ok', true, 'from', v_old, 'to', v_seat,
                            'swapped_with', v_swapped);
END $$;

-- Undo a manual change: a manifest passenger goes back to the seat on the manifest, a walk-up is removed.
CREATE OR REPLACE FUNCTION gs_seat_revert(p_flight text, p_date date, p_key text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_f text := upper(btrim(p_flight)); v_t uuid; v_orig text; occ record; v_status text;
BEGIN
  v_t := gs_seat_guard(v_f, p_date);
  SELECT status INTO v_status FROM guestora_sessions WHERE tenant_id = v_t AND flight_number = v_f AND flight_date = p_date;
  IF v_status = 'closed' THEN RAISE EXCEPTION 'This flight''s session is closed.' USING ERRCODE = 'P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(v_t::text || v_f || p_date::text));

  SELECT gs_norm_seat(e->>'seat') INTO v_orig
    FROM (SELECT passengers FROM passenger_manifests WHERE tenant_id = v_t AND flight_number = v_f AND flight_date = p_date
           ORDER BY created_at DESC LIMIT 1) m,
         LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(m.passengers) = 'array' THEN m.passengers ELSE '[]'::jsonb END) e
   WHERE gs_pax_key(e->>'name') = p_key LIMIT 1;

  IF v_orig IS NOT NULL THEN
    SELECT * INTO occ FROM gs_seat_effective(v_t, v_f, p_date) e WHERE e.seat = v_orig AND e.pax_key <> p_key LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'SEAT_TAKEN: % is now taken by %. Move them first.', v_orig, occ.pax_name USING ERRCODE = 'P0001';
    END IF;
  END IF;
  DELETE FROM guestora_seat_assignments WHERE tenant_id = v_t AND flight_number = v_f AND flight_date = p_date AND pax_key = p_key;
END $$;

-- ---------- grants ----------
REVOKE ALL ON FUNCTION gs_pax_key(text), gs_norm_seat(text), gs_seat_effective(uuid,text,date), gs_seat_guard(text,date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION gs_seat_list(text,date), gs_seat_set(text,date,text,text,text,text,text,boolean), gs_seat_revert(text,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION gs_seat_list(text,date), gs_seat_set(text,date,text,text,text,text,text,boolean), gs_seat_revert(text,date,text) TO authenticated;

DO $$ BEGIN RAISE NOTICE 'Migration 35 verified: Guestora manual seat assignment ready.'; END $$;
