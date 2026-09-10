-- Mobile Data Computer: database schema
--
-- You do NOT need to run this. The resource creates and migrates every table it
-- owns on start. It is here for operators who prefer to review or apply the
-- schema by hand, and as documentation of what is stored.
--
-- Every table is namespaced `mdc_`. The resource never writes to your
-- framework's own tables. It only READS them, and only through
-- server/bridge.lua.

CREATE TABLE IF NOT EXISTS mdc_charges (
  id INT AUTO_INCREMENT PRIMARY KEY,
  citizenid VARCHAR(64),
  code VARCHAR(16),
  title VARCHAR(128),
  class VARCHAR(16),
  months INT,
  fine INT,
  modifiers VARCHAR(128),
  officer VARCHAR(128),
  plea VARCHAR(16) DEFAULT 'Guilty',
  status VARCHAR(16) DEFAULT 'outstanding',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS mdc_bolos (
  id INT AUTO_INCREMENT PRIMARY KEY,
  type VARCHAR(16) DEFAULT 'person',
  title VARCHAR(128) NOT NULL,
  description TEXT,
  image_url VARCHAR(512) DEFAULT '',
  image_urls TEXT,
  officer VARCHAR(128),
  status VARCHAR(16) DEFAULT 'active',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at DATETIME DEFAULT NULL
);

CREATE TABLE IF NOT EXISTS mdc_reports (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(128) NOT NULL,
  type VARCHAR(32) DEFAULT 'Incident',
  content TEXT,
  subject_name VARCHAR(128) DEFAULT '',
  officer VARCHAR(128),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS mdc_mugshots (
  citizenid VARCHAR(64) PRIMARY KEY,
  image MEDIUMTEXT,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS mdc_prints (
  citizenid VARCHAR(64) PRIMARY KEY,
  officer VARCHAR(128) DEFAULT '',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS mdc_imprisonments (
  id INT AUTO_INCREMENT PRIMARY KEY,
  citizenid VARCHAR(64) NOT NULL,
  officer VARCHAR(128) DEFAULT '',
  months INT DEFAULT 0,
  fine INT DEFAULT 0,
  charges INT DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_imp_cid (citizenid)
);

CREATE TABLE IF NOT EXISTS mdc_weapons (
  id INT AUTO_INCREMENT PRIMARY KEY,
  serial VARCHAR(64) NOT NULL,
  citizenid VARCHAR(64) NOT NULL,
  owner_name VARCHAR(128) DEFAULT '',
  weapon VARCHAR(64) NOT NULL,
  source_label VARCHAR(160) DEFAULT '',
  status VARCHAR(16) NOT NULL DEFAULT 'clean',
  registered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uniq_serial (serial),
  INDEX idx_weapons_cid (citizenid),
  INDEX idx_weapons_owner (owner_name)
);

CREATE TABLE IF NOT EXISTS mdc_licenses (
  id INT AUTO_INCREMENT PRIMARY KEY,
  citizenid VARCHAR(64) NOT NULL,
  type VARCHAR(32) NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'valid',
  issued DATE DEFAULT NULL,
  expires DATE DEFAULT NULL,
  issuer VARCHAR(128) DEFAULT '',
  UNIQUE KEY uniq_cid_type (citizenid, type),
  INDEX idx_lic_cid (citizenid)
);

CREATE TABLE IF NOT EXISTS mdc_plate_records (
  id INT AUTO_INCREMENT PRIMARY KEY,
  vin VARCHAR(32) NOT NULL,
  plate VARCHAR(16) NOT NULL,
  note VARCHAR(160) DEFAULT '',
  recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_plate_vin (vin),
  INDEX idx_plate_plate (plate)
);

CREATE TABLE IF NOT EXISTS mdc_dmv_photos (
  citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
  image LONGTEXT,
  taken_by VARCHAR(128) DEFAULT '',
  taken_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

