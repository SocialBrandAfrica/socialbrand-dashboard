-- ============================================================
-- STEP 1: Identity tables
-- SB-AP-002 v1.0 — server names and IPs verified 2026-05-17
-- ============================================================
CREATE TABLE IF NOT EXISTS clients (
  client_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_name  TEXT NOT NULL,
  brand_name   TEXT,
  is_active    BOOLEAN DEFAULT true,
  created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS stores (
  store_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL REFERENCES clients(client_id),
  store_code    TEXT NOT NULL,
  store_name    TEXT NOT NULL,
  store_type    TEXT,
  location      TEXT,
  sigma_server  TEXT,
  lan_ip        TEXT,
  secondary_ip  TEXT,
  is_active     BOOLEAN DEFAULT true,
  UNIQUE(client_id, store_code)
);

INSERT INTO clients (client_name, brand_name)
VALUES ('SocialBrand', 'SocialBrand Pulse')
ON CONFLICT DO NOTHING;

INSERT INTO stores (client_id, store_code, store_name, store_type, location, sigma_server, lan_ip, secondary_ip)
SELECT
  c.client_id,
  v.store_code,
  v.store_name,
  v.store_type,
  v.location,
  v.sigma_server,
  v.lan_ip,
  v.secondary_ip
FROM clients c,
(VALUES
  ('10116', 'SPAR Delareyville', 'SPAR', 'Delareyville', 'srsdelareyvilesvr', '10.6.120.1',  NULL),
  ('80175', 'SPAR Roosville',    'SPAR', 'Roosville',     'srsroosvillesvr',   '10.6.214.1',  NULL),
  ('21355', 'TOPS Delareyville', 'TOPS', 'Delareyville',  'srtdelareyvilsv',  '10.6.120.60', NULL),
  ('80579', 'TOPS Dice',         'TOPS', 'Dice',           'srsdelareyt2svr',   '10.6.18.60',  '192.168.0.249'),
  ('80176', 'TOPS Roosville',    'TOPS', 'Roosville',      'srtroosvillesvr',   '10.6.214.60', NULL)
) AS v(store_code, store_name, store_type, location, sigma_server, lan_ip, secondary_ip)
WHERE c.client_name = 'SocialBrand'
ON CONFLICT (client_id, store_code) DO NOTHING;

-- Verify: should return 5 rows
SELECT store_code, store_name, store_type, sigma_server, lan_ip, secondary_ip
FROM stores ORDER BY store_code;
