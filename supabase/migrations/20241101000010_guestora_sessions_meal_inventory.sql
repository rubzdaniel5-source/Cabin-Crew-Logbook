-- =============================================================================
-- Migration: 20241101000010_guestora_sessions_meal_inventory.sql
-- Description: Add meal_inventory column to guestora_sessions
--
-- Context:
--   CRANE CUISINE / GUESTORA service sessions need a per-session record of
--   how many of each menu item were loaded on board (uplift count). Crew
--   enter these quantities when a new session opens; counts decrement as
--   orders are placed so the remaining inventory is always visible in the
--   seat map header.
--
-- Design decisions:
--   • jsonb column — schema-less so it doesn't require re-migration when
--     menu items are added/removed. The client manages the shape.
--   • Shape: { "<item-uuid>": { "name": "...", "total": N, "remaining": N }, ... }
--   • NULL = inventory not yet entered (or feature not used for legacy sessions)
--   • RLS row already on guestora_sessions (migration 7); no changes needed here.
--   • The client is IDB-first; it stores mealInventory in the IDB session cache
--     and syncs to this column on every update when online.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Add the column
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_sessions
  ADD COLUMN IF NOT EXISTS meal_inventory jsonb;

COMMENT ON COLUMN guestora_sessions.meal_inventory
  IS 'Per-item meal uplift counts for this service session. '
     'JSON object keyed by menu item id, e.g. '
     '{"<uuid>":{"name":"Beef stew","total":24,"remaining":21}}. '
     'NULL means inventory has not been entered for this session yet. '
     'Maintained by the CRANE CUISINE client; updated on every order save.';

-- ---------------------------------------------------------------------------
-- 2. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_col integer;
BEGIN
  SELECT COUNT(*) INTO v_col
  FROM   information_schema.columns
  WHERE  table_schema = 'public'
    AND  table_name   = 'guestora_sessions'
    AND  column_name  = 'meal_inventory';

  IF v_col = 0 THEN
    RAISE EXCEPTION 'meal_inventory column not found on guestora_sessions';
  END IF;

  RAISE NOTICE
    'Migration 10 verified: guestora_sessions.meal_inventory (jsonb, nullable) column present.';
END;
$$;
