-- =============================================================================
-- Migration: 20241101000011_crew_rosters.sql
-- Description: Crew roster PDF import — crew_rosters + roster_duties tables
--
-- Context:
--   Cabin crew receive their monthly/fortnightly roster as a PDF export from
--   ARMS®. This migration stores the parsed roster so the crew can:
--     1. View all rostered duties in a "My Roster" tab
--     2. Mark operating flights as completed (entering actual block time)
--     3. Automatically surface completed duties in the Flight Logs tab
--
-- Duty types (from ARMS® Crew Daily Roster):
--   OP          – Operating flight (rank suffix stripped on parse: JCCM/SCCM/P/SP/SFP)
--   DMA         – Duty May be Assigned (dynamic; could become standby or a flight)
--   WOFF        – Weekly Off (rest/days off)
--   DMA-LayOver – Layover day at destination
--   NA          – Not Available
--   SBY         – Standby (may appear in future rosters)
--   TRG         – Training
--   GRD         – Ground Duty
--
-- Block time notes:
--   block_scheduled_mins  = estimated block per sector FROM the PDF (not actual)
--   block_actual_mins     = actual block entered by crew after the flight
--   The PDF "Total Block Time" row is stored in crew_rosters.total_est_block_mins
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. crew_rosters — one row per uploaded roster PDF
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS crew_rosters (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL REFERENCES tenants(id),

  -- Header metadata extracted from the PDF
  crew_name             text,
  crew_code             text,
  crew_rank             text,         -- e.g. JCCM, SCCM, P, SP, SFP (from OP suffix)
  base                  text,
  period_from           date,
  period_to             date,
  total_est_block_mins  int,          -- "Total Block Time" footer from the PDF

  -- Source / audit
  source_filename       text,         -- original PDF filename
  raw_text              text,         -- full extracted text, for re-parsing if needed
  uploaded_by           uuid REFERENCES auth.users(id),
  created_at            timestamptz   DEFAULT now()
);

COMMENT ON TABLE  crew_rosters IS
  'One row per uploaded ARMS® Crew Daily Roster PDF.';
COMMENT ON COLUMN crew_rosters.total_est_block_mins IS
  'Estimated total block time for the roster period, in minutes, '
  'as printed in the PDF footer ("Total Block Time"). NOT actual block.';
COMMENT ON COLUMN crew_rosters.crew_rank IS
  'Rank parsed from the OP duty suffix in the PDF, e.g. JCCM. '
  'Applies to all OP duties on this roster.';

-- ---------------------------------------------------------------------------
-- 2. roster_duties — one row per table row in the PDF
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roster_duties (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL REFERENCES tenants(id),
  roster_id             uuid        NOT NULL REFERENCES crew_rosters(id) ON DELETE CASCADE,

  -- From the PDF table
  s_no                  int,
  duty_date             date        NOT NULL,
  duty_type             text        NOT NULL,   -- normalised: OP, DMA, WOFF, DMA-LayOver, NA, SBY, TRG, GRD
  flight_number         text,                   -- NULL for non-OP duties
  origin                text,
  destination           text,
  std_local             text,                   -- HH:MM local
  std_utc               text,                   -- HH:MM UTC
  sta_local             text,                   -- HH:MM or HH:MM/DD (next-day suffix kept raw)
  sta_utc               text,
  block_scheduled_mins  int,                    -- estimated block from PDF, in minutes
  remark                text,

  -- Completion — filled by crew in-app
  status                text        NOT NULL DEFAULT 'rostered',
  --  rostered   = future / not yet actioned
  --  completed  = flight operated, actual times entered
  --  cancelled  = flight did not operate
  --  diverted   = operated but to a different destination
  --  standby    = DMA converted to standby by ops

  block_actual_mins     int,                    -- actual block entered by crew (minutes)
  atd_local             text,                   -- actual time of departure HH:MM
  ata_local             text,                   -- actual time of arrival HH:MM
  divert_airport        text,                   -- IATA code if diverted
  completion_note       text,
  completed_at          timestamptz,

  created_at            timestamptz DEFAULT now(),

  CONSTRAINT roster_duties_status_check CHECK (
    status IN ('rostered','completed','cancelled','diverted','standby')
  )
);

COMMENT ON TABLE  roster_duties IS
  'One row per duty line in an ARMS® Crew Daily Roster PDF.';
COMMENT ON COLUMN roster_duties.duty_type IS
  'Normalised duty type: OP (rank suffix stripped), DMA, WOFF, DMA-LayOver, NA, SBY, TRG, GRD.';
COMMENT ON COLUMN roster_duties.block_scheduled_mins IS
  'Estimated sector block time from the roster PDF, in minutes. NOT the actual post-flight block.';
COMMENT ON COLUMN roster_duties.block_actual_mins IS
  'Actual block time entered by crew after the flight, in minutes.';
COMMENT ON COLUMN roster_duties.sta_local IS
  'Stored raw, e.g. "06:45/19" where /19 means next-day (19th). '
  'Parser strips the suffix for display but preserves the original here.';

-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS crew_rosters_tenant_period
  ON crew_rosters(tenant_id, period_from, period_to);

CREATE INDEX IF NOT EXISTS roster_duties_roster_id
  ON roster_duties(roster_id);

CREATE INDEX IF NOT EXISTS roster_duties_tenant_date
  ON roster_duties(tenant_id, duty_date);

CREATE INDEX IF NOT EXISTS roster_duties_tenant_status
  ON roster_duties(tenant_id, status)
  WHERE duty_type = 'OP';

-- ---------------------------------------------------------------------------
-- 4. Row-Level Security
-- ---------------------------------------------------------------------------
ALTER TABLE crew_rosters  ENABLE ROW LEVEL SECURITY;
ALTER TABLE roster_duties ENABLE ROW LEVEL SECURITY;

-- crew_rosters: tenant isolation (same pattern as all other tables)
CREATE POLICY crew_rosters_tenant_isolation ON crew_rosters
  USING (tenant_id = (
    SELECT tenant_id FROM profiles WHERE id = auth.uid() LIMIT 1
  ));

-- roster_duties: tenant isolation via roster join
CREATE POLICY roster_duties_tenant_isolation ON roster_duties
  USING (tenant_id = (
    SELECT tenant_id FROM profiles WHERE id = auth.uid() LIMIT 1
  ));

-- ---------------------------------------------------------------------------
-- 5. Tenant auto-assign trigger (same pattern as other tables)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_crew_rosters_tenant()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.tenant_id IS NULL THEN
    SELECT tenant_id INTO NEW.tenant_id
    FROM profiles WHERE id = auth.uid() LIMIT 1;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER crew_rosters_set_tenant
  BEFORE INSERT ON crew_rosters
  FOR EACH ROW EXECUTE FUNCTION set_crew_rosters_tenant();

CREATE OR REPLACE FUNCTION set_roster_duties_tenant()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.tenant_id IS NULL THEN
    SELECT tenant_id INTO NEW.tenant_id
    FROM profiles WHERE id = auth.uid() LIMIT 1;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER roster_duties_set_tenant
  BEFORE INSERT ON roster_duties
  FOR EACH ROW EXECUTE FUNCTION set_roster_duties_tenant();

-- ---------------------------------------------------------------------------
-- 6. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_rosters  int;
  v_duties   int;
BEGIN
  SELECT COUNT(*) INTO v_rosters FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'crew_rosters';
  SELECT COUNT(*) INTO v_duties  FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'roster_duties';

  IF v_rosters = 0 THEN RAISE EXCEPTION 'crew_rosters table not found'; END IF;
  IF v_duties  = 0 THEN RAISE EXCEPTION 'roster_duties table not found'; END IF;

  RAISE NOTICE 'Migration 11 verified: crew_rosters and roster_duties tables present with RLS enabled.';
END;
$$;
