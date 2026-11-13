-- =============================================================================
-- Migration: 20241101000009_purser_reports_sector_fields.sql
-- Description: Add multi-sector fields to purser_reports
--
-- Context:
--   Phase 3 (PFR scope) added a "No. of Sectors" dropdown and per-sector
--   flight number fields to the Purser Flight Report overlay. The client
--   already serialises these two values into savePFRDraft() and submitPFR()
--   payloads (index.html lines 10319-10320):
--
--     sector_count:          _pfrData.sector_count || 1
--     sector_flight_numbers: JSON.stringify(_pfrData.sector_flight_numbers||[])
--
--   Without this migration those columns don't exist and every draft save
--   raises:  "Could not find the 'sector_count' column of 'purser_reports'"
--
-- What this migration does:
--   1. Add sector_count   — integer, 1-4, NOT NULL DEFAULT 1
--   2. Add sector_flight_numbers — text (JSON array of flight number strings)
--   3. Backfill existing rows from the legacy flight_number column so
--      old reports aren't left with an empty sector list
--   4. Add comments for future maintainers
--   5. Verification DO block
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. sector_count — how many sectors the duty contains (1 to 4)
-- ---------------------------------------------------------------------------
ALTER TABLE purser_reports
  ADD COLUMN IF NOT EXISTS sector_count integer NOT NULL DEFAULT 1
    CONSTRAINT purser_reports_sector_count_range CHECK (sector_count BETWEEN 1 AND 4);

COMMENT ON COLUMN purser_reports.sector_count
  IS 'Number of sectors in this duty (1-4). Drives how many sector rows appear in the PFR form.';

-- ---------------------------------------------------------------------------
-- 2. sector_flight_numbers — JSON array, e.g. ["UR206","UR207"]
--    Stored as text so it survives schema migrations without touching JSON
--    operators; the client parses it with JSON.parse() on load.
-- ---------------------------------------------------------------------------
ALTER TABLE purser_reports
  ADD COLUMN IF NOT EXISTS sector_flight_numbers text;

COMMENT ON COLUMN purser_reports.sector_flight_numbers
  IS 'JSON array of individual sector flight numbers in order, e.g. ["UR206","UR207"]. '
     'Parsed by the client with JSON.parse(). NULL means legacy single-sector report.';

-- ---------------------------------------------------------------------------
-- 3. Backfill existing rows
--    Old reports have a single flight_number text column. Seed
--    sector_flight_numbers from it so the PFR overlay pre-fills correctly
--    when a crew member reopens a legacy draft.
--    sector_count stays at 1 (the default) for all legacy rows — that is
--    correct since they were written before multi-sector support existed.
-- ---------------------------------------------------------------------------
UPDATE purser_reports
SET    sector_flight_numbers = to_json(ARRAY[flight_number])::text
WHERE  sector_flight_numbers IS NULL
  AND  flight_number IS NOT NULL
  AND  flight_number <> '';

DO $$
DECLARE
  v_backfilled  integer;
  v_remaining   integer;
BEGIN
  -- Count backfilled rows (rows that now have sector_flight_numbers from above)
  SELECT COUNT(*) INTO v_backfilled
  FROM   purser_reports
  WHERE  sector_flight_numbers IS NOT NULL;

  -- Count rows still NULL (reports with no flight_number at all — orphaned drafts)
  SELECT COUNT(*) INTO v_remaining
  FROM   purser_reports
  WHERE  sector_flight_numbers IS NULL;

  IF v_remaining > 0 THEN
    RAISE NOTICE
      'purser_reports: backfill complete — % row(s) seeded from flight_number. '
      '% row(s) have NULL sector_flight_numbers (empty legacy drafts; harmless).',
      v_backfilled, v_remaining;
  ELSE
    RAISE NOTICE
      'purser_reports: backfill complete — all % row(s) have sector_flight_numbers.',
      v_backfilled;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_col_count   integer;
  v_col_fnums   integer;
  v_check_name  integer;
BEGIN
  -- sector_count column present
  SELECT COUNT(*) INTO v_col_count
  FROM   information_schema.columns
  WHERE  table_schema = 'public'
    AND  table_name   = 'purser_reports'
    AND  column_name  = 'sector_count';
  IF v_col_count = 0 THEN
    RAISE EXCEPTION 'sector_count column not found on purser_reports';
  END IF;

  -- sector_flight_numbers column present
  SELECT COUNT(*) INTO v_col_fnums
  FROM   information_schema.columns
  WHERE  table_schema = 'public'
    AND  table_name   = 'purser_reports'
    AND  column_name  = 'sector_flight_numbers';
  IF v_col_fnums = 0 THEN
    RAISE EXCEPTION 'sector_flight_numbers column not found on purser_reports';
  END IF;

  -- CHECK constraint present
  SELECT COUNT(*) INTO v_check_name
  FROM   pg_constraint
  WHERE  conrelid = 'purser_reports'::regclass
    AND  conname  = 'purser_reports_sector_count_range'
    AND  contype  = 'c';
  IF v_check_name = 0 THEN
    RAISE EXCEPTION 'CHECK constraint purser_reports_sector_count_range not found';
  END IF;

  RAISE NOTICE
    'Migration 9 verified: purser_reports.sector_count (1-4 CHECK) and '
    'purser_reports.sector_flight_numbers columns present and correct.';
END;
$$;
