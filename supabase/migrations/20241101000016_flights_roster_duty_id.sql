-- =============================================================================
-- Migration: 20241101000016_flights_roster_duty_id.sql
-- Description: Link completed roster duties to their auto-created flight log entries
--
-- Context:
--   When a crew member marks an OP roster duty as complete, the app auto-creates
--   a matching row in the `flights` table so the duty appears in Flight Logs.
--   This column links the two records for de-duplication and future reference.
--
--   roster_duty_id is nullable — manually-entered flight log entries have no
--   corresponding roster duty, so they leave this column NULL.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Add the column
-- ---------------------------------------------------------------------------
ALTER TABLE flights
  ADD COLUMN IF NOT EXISTS roster_duty_id uuid
    REFERENCES roster_duties(id) ON DELETE SET NULL;

COMMENT ON COLUMN flights.roster_duty_id IS
  'If this flight log entry was auto-created from a completed roster duty, '
  'this references that roster_duties row. NULL for manually-entered flights.';

-- ---------------------------------------------------------------------------
-- 2. Index for fast reverse-lookup (find the flight log entry for a duty)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_flights_roster_duty_id
  ON flights (roster_duty_id)
  WHERE roster_duty_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_col int;
BEGIN
  SELECT COUNT(*) INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'flights'
     AND column_name  = 'roster_duty_id';

  IF v_col = 0 THEN
    RAISE EXCEPTION 'Migration 16: flights.roster_duty_id column not found';
  END IF;

  RAISE NOTICE 'Migration 16 verified: flights.roster_duty_id column present.';
END;
$$;
