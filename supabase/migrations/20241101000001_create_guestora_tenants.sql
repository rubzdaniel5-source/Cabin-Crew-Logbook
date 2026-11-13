-- =============================================================================
-- Migration: 20241101000001_create_guestora_tenants.sql
-- Description: Create guestora_tenants table with pre-populated airline directory
--
-- Tenant isolation model:
--   - All 63 airlines pre-populated; only Uganda Airlines has enabled = true
--   - Directory-only airlines: enabled = false, dining_brand = null
--   - tenant_id is NEVER supplied by the client in write operations;
--     server resolves via auth.uid() → profiles
--   - Uganda Airlines email domains: @crew.ugandairlines.com, @ugandairlines.com
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helper: updated_at trigger function (shared across all guestora tables)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guestora_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Table: guestora_tenants
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guestora_tenants (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug             text        NOT NULL UNIQUE,
  airline_name     text        NOT NULL,
  iata_code        text,
  -- dining_brand is NULL for directory-only (non-enabled) tenants
  dining_brand     text,
  tagline          text,
  primary_color    text,
  secondary_color  text,
  logo_url         text,
  cabin_class_labels  jsonb,
  menu_terminology    jsonb,
  -- enabled = false means "directory only"; switching to true onboards the airline
  -- Default is false so accidental inserts never auto-activate
  enabled          boolean     NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER guestora_tenants_updated_at
  BEFORE UPDATE ON guestora_tenants
  FOR EACH ROW EXECUTE FUNCTION guestora_set_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
ALTER TABLE guestora_tenants ENABLE ROW LEVEL SECURITY;

-- Any authenticated user can read all tenant rows (needed for signup airline dropdown)
CREATE POLICY "guestora_tenants_read_all"
  ON guestora_tenants
  FOR SELECT
  TO authenticated
  USING (true);

-- No INSERT/UPDATE/DELETE via client — managed by migrations and admin tooling only

-- ---------------------------------------------------------------------------
-- Pre-populated airline directory (63 airlines, 6 IATA regions)
-- Uganda Airlines is the only enabled tenant; all others are directory-only.
-- Uganda Airlines email domains: @crew.ugandairlines.com / @ugandairlines.com
-- ---------------------------------------------------------------------------
INSERT INTO guestora_tenants (slug, airline_name, iata_code, dining_brand, enabled)
VALUES

  -- =========================================================================
  -- AFRICA
  -- =========================================================================
  ('uganda-airlines',        'Uganda Airlines',                    'UR',  'CRANE CUISINE', true),
  ('ethiopian-airlines',     'Ethiopian Airlines',                 'ET',  null,            false),
  ('kenya-airways',          'Kenya Airways',                      'KQ',  null,            false),
  ('rwandair',               'RwandAir',                           'WB',  null,            false),
  ('air-tanzania',           'Air Tanzania',                       'TC',  null,            false),
  ('precision-air',          'Precision Air',                      'PW',  null,            false),
  ('fastjet',                'fastjet',                            'FN',  null,            false),
  ('south-african-airways',  'South African Airways',              'SA',  null,            false),
  ('kulula',                 'Kulula',                             'MN',  null,            false),
  ('airlink',                'Airlink',                            '4Z',  null,            false),
  ('flysafair',              'FlySafair',                          'FA',  null,            false),
  ('egyptair',               'EgyptAir',                          'MS',  null,            false),
  ('air-algerie',            'Air Algérie',                        'AH',  null,            false),
  ('royal-air-maroc',        'Royal Air Maroc',                    'AT',  null,            false),
  ('tunisair',               'Tunisair',                           'TU',  null,            false),
  ('libyan-airlines',        'Libyan Airlines',                    'LN',  null,            false),
  ('air-mauritius',          'Air Mauritius',                      'MK',  null,            false),
  ('air-madagascar',         'Air Madagascar',                     'MD',  null,            false),
  ('air-seychelles',         'Air Seychelles',                     'HM',  null,            false),
  ('corsair-international',  'Corsair International',              'SS',  null,            false),
  ('asky-airlines',          'ASKY Airlines',                      'KP',  null,            false),
  ('air-cote-divoire',       'Air Côte d''Ivoire',                 'HF',  null,            false),
  ('camair-co',              'Camair-Co',                          'QC',  null,            false),
  ('air-senegal',            'Air Sénégal',                        'HC',  null,            false),
  ('africa-world-airlines',  'Africa World Airlines',              'AW',  null,            false),

  -- =========================================================================
  -- MIDDLE EAST
  -- =========================================================================
  ('emirates',               'Emirates',                           'EK',  null,            false),
  ('etihad-airways',         'Etihad Airways',                     'EY',  null,            false),
  ('qatar-airways',          'Qatar Airways',                      'QR',  null,            false),
  ('flydubai',               'flydubai',                           'FZ',  null,            false),
  ('air-arabia',             'Air Arabia',                         'G9',  null,            false),
  ('oman-air',               'Oman Air',                           'WY',  null,            false),
  ('gulf-air',               'Gulf Air',                           'GF',  null,            false),
  ('kuwait-airways',         'Kuwait Airways',                     'KU',  null,            false),
  ('royal-jordanian',        'Royal Jordanian',                    'RJ',  null,            false),
  ('middle-east-airlines',   'Middle East Airlines',               'ME',  null,            false),

  -- =========================================================================
  -- ASIA PACIFIC
  -- =========================================================================
  ('singapore-airlines',     'Singapore Airlines',                 'SQ',  null,            false),
  ('cathay-pacific',         'Cathay Pacific',                     'CX',  null,            false),
  ('malaysia-airlines',      'Malaysia Airlines',                  'MH',  null,            false),
  ('thai-airways',           'Thai Airways',                       'TG',  null,            false),
  ('garuda-indonesia',       'Garuda Indonesia',                   'GA',  null,            false),
  ('philippine-airlines',    'Philippine Airlines',                'PR',  null,            false),
  ('vietnam-airlines',       'Vietnam Airlines',                   'VN',  null,            false),
  ('air-india',              'Air India',                          'AI',  null,            false),
  ('indigo',                 'IndiGo',                             '6E',  null,            false),
  ('air-new-zealand',        'Air New Zealand',                    'NZ',  null,            false),
  ('qantas',                 'Qantas',                             'QF',  null,            false),
  ('china-southern',         'China Southern Airlines',            'CZ',  null,            false),
  ('china-eastern',          'China Eastern Airlines',             'MU',  null,            false),
  ('air-china',              'Air China',                          'CA',  null,            false),
  ('korean-air',             'Korean Air',                         'KE',  null,            false),
  ('asiana-airlines',        'Asiana Airlines',                    'OZ',  null,            false),
  ('japan-airlines',         'Japan Airlines',                     'JL',  null,            false),
  ('ana',                    'All Nippon Airways',                 'NH',  null,            false),

  -- =========================================================================
  -- EUROPE
  -- =========================================================================
  ('british-airways',        'British Airways',                    'BA',  null,            false),
  ('lufthansa',              'Lufthansa',                          'LH',  null,            false),
  ('air-france',             'Air France',                         'AF',  null,            false),
  ('klm',                    'KLM Royal Dutch Airlines',           'KL',  null,            false),
  ('turkish-airlines',       'Turkish Airlines',                   'TK',  null,            false),
  ('swiss',                  'SWISS',                              'LX',  null,            false),
  ('austrian-airlines',      'Austrian Airlines',                  'OS',  null,            false),
  ('iberia',                 'Iberia',                             'IB',  null,            false),
  ('tap-air-portugal',       'TAP Air Portugal',                   'TP',  null,            false),
  ('finnair',                'Finnair',                            'AY',  null,            false),
  ('scandinavian-airlines',  'Scandinavian Airlines',              'SK',  null,            false),

  -- =========================================================================
  -- AMERICAS
  -- =========================================================================
  ('american-airlines',      'American Airlines',                  'AA',  null,            false),
  ('united-airlines',        'United Airlines',                    'UA',  null,            false),
  ('delta-air-lines',        'Delta Air Lines',                    'DL',  null,            false)

ON CONFLICT (slug) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Verification: confirm Uganda Airlines inserted correctly
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  ug_count integer;
BEGIN
  SELECT COUNT(*) INTO ug_count
  FROM guestora_tenants
  WHERE slug = 'uganda-airlines'
    AND enabled = true
    AND dining_brand = 'CRANE CUISINE'
    AND iata_code = 'UR';

  IF ug_count != 1 THEN
    RAISE EXCEPTION 'Uganda Airlines tenant row not found or misconfigured after insert';
  END IF;
END;
$$;
