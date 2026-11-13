-- =============================================================================
-- Migration: 20241101000014_reassign_all_users_uganda_airlines.sql
-- Description: Reassign all current profiles to Uganda Airlines
--
-- Context:
--   All users currently registered on the app are Uganda Airlines cabin crew.
--   Prior migrations defaulted non-@ugandairlines.com emails to 'independent',
--   which was incorrect for this stage of the rollout.
--
--   Going forward:
--     New users who are NOT Uganda Airlines crew will register as 'independent'.
--     This migration is a one-time correction for existing accounts only.
-- =============================================================================

UPDATE profiles
SET
  user_class   = 'airline',
  tenant_id    = (SELECT id FROM guestora_tenants WHERE slug = 'uganda-airlines'),
  airline_name = 'Uganda Airlines'
WHERE true;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_independent int;
  v_airline     int;
BEGIN
  SELECT COUNT(*) INTO v_independent FROM profiles WHERE user_class = 'independent';
  SELECT COUNT(*) INTO v_airline     FROM profiles WHERE user_class = 'airline';

  IF v_independent > 0 THEN
    RAISE EXCEPTION
      'Migration 14: % profile(s) still marked independent — expected 0', v_independent;
  END IF;

  RAISE NOTICE
    'Migration 14 verified: all % profile(s) reassigned to Uganda Airlines.',
    v_airline;
END;
$$;
