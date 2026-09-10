--[[
    mdc - SERVER (REDESIGN2 overhaul)
    Qbox MDC. Required: qbx_core + ox_lib + oxmysql.
    Optional: screenshot-basic (mugshots + DMV photos), ox_inventory (auto weapon registration).

    HARD RULES enforced here:
      - NO citizenid is EVER returned to the NUI. All person targeting is BY NAME.
        The server resolves name->citizenid INTERNALLY for storage/queries only.
      - The Arrest Calculator (placeCharges) ONLY records charges as OUTSTANDING.
        It performs NO jailing and NO fining: sentencing is left to whatever
        prison system the server already runs.

    Callbacks (dual-registered under mdc:<name> AND mdc:server:<name>):
      LEO-only (getOfficer): getDashboard, placeCharges, getBolos, createBolo,
        cancelBolo, createReport, getCameras
      LEO + court (getMdcUser; judge/lawyer read-only): searchVehicle,
        searchPerson, getPenalCode, getWarrants (derived, online-only),
        getReports, getReport

]]

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

-- Department of Corrections anchor (suspect must be within 50m for /jail).
local DOC = vec3(1845.83, 2585.90, 45.67)
local DOC_RADIUS = 50.0



----------------------------------------------------------------------
-- SQL - schema (idempotent CREATE; migrations handled in ensureColumn)
----------------------------------------------------------------------

local CREATE_CHARGES_SQL = [[
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
)
]]

local CREATE_BOLOS_SQL = [[
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
)
]]

local CREATE_REPORTS_SQL = [[
CREATE TABLE IF NOT EXISTS mdc_reports (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(128) NOT NULL,
  type VARCHAR(32) DEFAULT 'Incident',
  content TEXT,
  subject_name VARCHAR(128) DEFAULT '',
  officer VARCHAR(128),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
]]

local CREATE_MUGSHOTS_SQL = [[
CREATE TABLE IF NOT EXISTS mdc_mugshots (
  citizenid VARCHAR(64) PRIMARY KEY,
  image MEDIUMTEXT,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
)
]]

-- One row per citizen who has been fingerprinted. Presence = "on file" (the Person tab shows a
-- boolean; the citizenid itself is never sent to the NUI, preserving the anti-metagaming rule).
local CREATE_PRINTS_SQL = [[
CREATE TABLE IF NOT EXISTS mdc_prints (
  citizenid VARCHAR(64) PRIMARY KEY,
  officer VARCHAR(128) DEFAULT '',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
)
]]

-- One row per actual /jail execution. The Person tab "imprisonments" total is a
-- COUNT of these rows - NOT how many charges carry prison time.
local CREATE_IMPRISONMENTS_SQL = [[
CREATE TABLE IF NOT EXISTS mdc_imprisonments (
  id INT AUTO_INCREMENT PRIMARY KEY,
  citizenid VARCHAR(64) NOT NULL,
  officer VARCHAR(128) DEFAULT '',
  months INT DEFAULT 0,
  fine INT DEFAULT 0,
  charges INT DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_imp_cid (citizenid)
)
]]

-- Registered firearms. A weapon is registered once (gun store sale, permit
-- issue, police seizure) and thereafter tracked by SERIAL, which is what
-- ox_inventory stamps into weapon metadata. status: clean | missing | stolen.
local CREATE_WEAPONS_SQL = [[
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
)
]]

-- Licences on record. qbx_core only stores booleans in metadata.licences, which
-- cannot express issue/expiry/issuer, so the MDC keeps its own ledger and falls
-- back to the qbx booleans when a citizen has no rows here yet.
local CREATE_LICENSES_SQL = [[
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
)
]]

-- Plate history. A vehicle can be re-plated; this records each plate a VIN has
-- carried so an officer running a plate can see how many records exist against
-- it. Nothing writes here automatically; a re-plating resource calls the
-- RecordPlateChange export.
local CREATE_PLATE_RECORDS_SQL = [[
CREATE TABLE IF NOT EXISTS mdc_plate_records (
  id INT AUTO_INCREMENT PRIMARY KEY,
  vin VARCHAR(32) NOT NULL,
  plate VARCHAR(16) NOT NULL,
  note VARCHAR(160) DEFAULT '',
  recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_plate_vin (vin),
  INDEX idx_plate_plate (plate)
)
]]

-- DMV licence portraits. Deliberately a DIFFERENT image from mdc_mugshots:
-- the licence shows the photo the citizen sat for at the counter, the mugshot
-- shows the one taken after an arrest. Person Search reads mugshots; Citizen ID
-- reads this table and never falls back to a mugshot.
local CREATE_DMV_PHOTOS_SQL = [[
CREATE TABLE IF NOT EXISTS mdc_dmv_photos (
  citizenid VARCHAR(64) NOT NULL PRIMARY KEY,
  image LONGTEXT,
  taken_by VARCHAR(128) DEFAULT '',
  taken_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
]]

----------------------------------------------------------------------
-- SQL - lookups
----------------------------------------------------------------------

-- Lifetime totals (ALL statuses - represents the person's record).
local TOTALS_SQL = [[
SELECT
  COUNT(*)                            AS charges,
  COALESCE(SUM(class = 'citation'),0) AS citations
FROM mdc_charges
WHERE citizenid = ?
]]

-- Actual imprisonments = number of times /jail was executed on this person.
local IMPRISONMENTS_COUNT_SQL = [[
SELECT COUNT(*) AS imprisonments FROM mdc_imprisonments WHERE citizenid = ?
]]


-- Processed charge history (rap sheet): each past charge/citation + its case plea.
local HISTORY_FOR_PERSON_SQL = [[
SELECT c.code, c.title, c.class, c.months, c.fine, i.plea AS plea,
       c.officer AS officer,
       DATE_FORMAT(c.created_at,'%Y-%m-%d') AS date
FROM mdc_charges c
LEFT JOIN mdc_imprisonments i ON i.id = c.case_id
WHERE c.citizenid = ? AND c.status = 'processed'
ORDER BY c.created_at DESC
LIMIT 60
]]

local INSERT_IMPRISONMENT_SQL = [[
INSERT INTO mdc_imprisonments (citizenid, officer, months, fine, charges)
VALUES (?, ?, ?, ?, ?)
]]

-- Outstanding charges for a person (Person tab outstanding list).
local OUTSTANDING_FOR_PERSON_SQL = [[
SELECT code, title, class, months, fine, modifiers, officer,
       DATE_FORMAT(created_at,'%Y-%m-%d') AS date
FROM mdc_charges
WHERE citizenid = ? AND status = 'outstanding'
ORDER BY created_at DESC
]]

-- Sum of outstanding charges (used by /jail + derived Warrants).
local SUM_OUTSTANDING_SQL = [[
SELECT
  COALESCE(SUM(months),0) AS months,
  COALESCE(SUM(fine),0)   AS fine,
  COUNT(*)                AS charges
FROM mdc_charges
WHERE citizenid = ? AND status = 'outstanding'
]]

-- Flip served rows to processed (clears them from outstanding + warrants).
local MARK_PROCESSED_SQL = [[
UPDATE mdc_charges SET status = 'processed'
WHERE citizenid = ? AND status = 'outstanding'
]]

local INSERT_CHARGE_SQL = [[
INSERT INTO mdc_charges
  (citizenid, code, title, class, months, fine, modifiers, officer, plea, status)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]]

-- Mugshots
local MUGSHOT_SELECT_SQL = [[
SELECT image FROM mdc_mugshots WHERE citizenid = ? LIMIT 1
]]

local MUGSHOT_UPSERT_SQL = [[
INSERT INTO mdc_mugshots (citizenid, image) VALUES (?, ?)
ON DUPLICATE KEY UPDATE image = VALUES(image), updated_at = CURRENT_TIMESTAMP
]]

-- Fingerprints (boolean on-file lookup + collect upsert)
local PRINTS_SELECT_SQL = [[
SELECT 1 AS has FROM mdc_prints WHERE citizenid = ? LIMIT 1
]]

local PRINTS_UPSERT_SQL = [[
INSERT INTO mdc_prints (citizenid, officer) VALUES (?, ?)
ON DUPLICATE KEY UPDATE officer = VALUES(officer), updated_at = CURRENT_TIMESTAMP
]]

-- BOLOs
local BOLOS_SELECT_SQL = [[
SELECT id, type, title, description, image_url, image_urls, officer,
  DATE_FORMAT(created_at,'%Y-%m-%d %H:%i') AS created_at,
  DATE_FORMAT(expires_at,'%Y-%m-%d %H:%i')  AS expires_at,
  CASE WHEN expires_at IS NULL THEN NULL
       ELSE TIMESTAMPDIFF(SECOND, NOW(), expires_at) END AS expires_in
FROM mdc_bolos
WHERE status = 'active'
  AND (expires_at IS NULL OR expires_at > NOW())
ORDER BY created_at DESC
LIMIT 50
]]

-- Expiry is computed by MySQL, not Lua, so it is immune to the server's
-- os.date timezone. hours = 0 means the BOLO never expires.
local BOLOS_EXPIRE_SWEEP_SQL = [[
UPDATE mdc_bolos SET status = 'expired'
WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at <= NOW()
]]

local BOLOS_INSERT_SQL = [[
INSERT INTO mdc_bolos (type, title, description, image_url, image_urls, officer, status, expires_at)
VALUES (?, ?, ?, ?, ?, ?, 'active',
        CASE WHEN ? > 0 THEN DATE_ADD(NOW(), INTERVAL ? HOUR) ELSE NULL END)
]]

local BOLOS_CANCEL_SQL = [[
UPDATE mdc_bolos SET status = 'cancelled' WHERE id = ?
]]

-- Reports
local REPORTS_SELECT_SQL = [[
SELECT id, title, type, subject_name, officer,
  DATE_FORMAT(created_at,'%Y-%m-%d %H:%i') AS created_at
FROM mdc_reports
ORDER BY created_at DESC
LIMIT 50
]]

local REPORT_SELECT_SQL = [[
SELECT id, title, type, content, subject_name, officer,
  DATE_FORMAT(created_at,'%Y-%m-%d %H:%i') AS created_at
FROM mdc_reports
WHERE id = ?
LIMIT 1
]]

local REPORTS_INSERT_SQL = [[
INSERT INTO mdc_reports (title, type, content, subject_name, officer)
VALUES (?, ?, ?, ?, ?)
]]

----------------------------------------------------------------------
-- PenalCode indices (built from the global shared table)
----------------------------------------------------------------------

local chargeIndex, modIndex

local function buildPenalIndex()
    chargeIndex, modIndex = {}, {}
    if type(PenalCode) ~= 'table' then return end
    for _, c in ipairs(PenalCode.charges or {}) do
        if c.code then chargeIndex[c.code] = c end
    end
    for _, m in ipairs(PenalCode.modifiers or {}) do
        if m.id then modIndex[m.id] = m end
    end
end

local function ensureIndex()
    if not chargeIndex or not modIndex then buildPenalIndex() end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Returns the officer Player object only if source is an ON-DUTY LEO, else nil.
-- (Off-duty officers cannot use any MDC callback or /jail.)
local function getOfficer(source)
    local player = Bridge.GetPlayer(source)
    if not player or not player.PlayerData then return nil end
    local job = player.PlayerData.job
    if not job or job.type ~= 'leo' or not job.onduty then return nil end
    return player
end

-- Court access: judge/lawyer (qbx_core/shared/jobs.lua job names). Returns the
-- Player object or nil. Court users get a RESTRICTED read-only MDC role:
-- searchPerson, searchVehicle, getPenalCode, getWarrants, getReports,
-- getReport ONLY. Everything else stays getOfficer-gated.
local function isCourt(source)
    local player = Bridge.GetPlayer(source)
    if not player or not player.PlayerData then return nil end
    local job = player.PlayerData.job
    if not job or (job.name ~= 'judge' and job.name ~= 'lawyer') then return nil end
    return player
end

-- Shared read-only gate: on-duty LEO OR court (judge/lawyer).
local function getMdcUser(source)
    return getOfficer(source) or isCourt(source)
end


-- Build a "First Last" display name from a charinfo table.
local function fullName(ci)
    ci = ci or {}
    local name = ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return 'Unknown' end
    return name
end

local function officerName(player)
    local name = fullName(player.PlayerData and player.PlayerData.charinfo)
    if name == 'Unknown' then return 'Unknown Officer' end
    return name
end

-- MDC feedback. Routed through Config.Notify so a server can use ox_lib toasts
-- (the portable default) or its own themed chat template without touching code.
-- tag defaults to 'DOC' (jail / sentencing / plea = Department of Corrections);
-- police functions (units, fingerprints, booking) pass 'LEO' via leoNotify.
local NKIND = { success = 'ok', error = 'err', inform = 'info' }
local function notify(src, message, ntype, tag)
    if not src or src == 0 then return end
    ntype = ntype or 'inform'

    if Config.Notify.mode == 'chat' then
        TriggerClientEvent('chat:addMessage', src, {
            templateId = Config.Notify.template,
            args = { tag or 'DOC', message, NKIND[ntype] or 'info' },
        })
        return
    end

    TriggerClientEvent('ox_lib:notify', src, {
        title = tag or 'DOC',
        description = message,
        type = ntype,
        position = Config.Notify.position,
    })
end

-- LEO-tagged feedback for police functions (unit callsigns, fingerprints, mugshot booking).
local function leoNotify(src, message, ntype)
    notify(src, message, ntype, 'LEO')
end

----------------------------------------------------------------------
-- Callback handlers
----------------------------------------------------------------------

-- getDashboard {} -> { units:[{callsign, members:[name], unassigned?}] }  (ON-DUTY leo only).
-- Officers are GROUPED by callsign so the dashboard shows each unit + who is in it; officers with
-- no callsign are collected under an 'Unassigned' pseudo-unit. (No job label - removed.)
local function handleGetDashboard(source)
    if not getOfficer(source) then return { units = {} } end

    local byUnit, solo = {}, {}
    local players = Bridge.GetPlayers()
    for _, p in pairs(players) do
        local pd = p.PlayerData
        if pd and pd.job and pd.job.type == 'leo' and pd.job.onduty then
            local cs = (pd.metadata and pd.metadata.callsign) or ''
            local name = fullName(pd.charinfo)
            if cs == '' or cs == 'NO CALLSIGN' then
                solo[#solo + 1] = name
            else
                byUnit[cs] = byUnit[cs] or {}
                byUnit[cs][#byUnit[cs] + 1] = name
            end
        end
    end

    local units = {}
    for cs, members in pairs(byUnit) do
        table.sort(members)
        units[#units + 1] = { callsign = cs, members = members }
    end
    table.sort(units, function(a, b) return a.callsign < b.callsign end)
    if #solo > 0 then
        table.sort(solo)
        units[#units + 1] = { callsign = '-', members = solo, unassigned = true }
    end
    return { units = units }
end

-- searchVehicle {plate} -> { found, owner, model, plate, vin, phone }  (NO cid)
-- Read-only: available to court (judge/lawyer) as well as LEO.
local function handleSearchVehicle(source, data)
    if not getMdcUser(source) then return { found = false } end

    local plate = data and data.plate
    if type(plate) ~= 'string' or plate == '' then return { found = false } end

    local row = Bridge.FindVehicleByPlate(plate)
    if not row then return { found = false } end

    -- How many plates this VIN has carried. 0 records = never re-plated, so the
    -- current plate IS the original.
    local records = tonumber(MySQL.scalar.await(
        'SELECT COUNT(*) FROM mdc_plate_records WHERE vin = ?', { row.vin })) or 0

    -- Running a plate should tell an officer about the OWNER, not just the car.
    -- Same record Person Search returns, so the two views never disagree.
    local totals, outstanding, history = { charges = 0, citations = 0, imprisonments = 0 }, {}, {}
    if row.cid then
        totals, outstanding, history = citizenRecord(row.cid)
    end

    return {
        found = true,
        owner = row.owner,
        model = row.model,
        plate = row.plate,
        vin = row.vin,
        phone = row.phone,
        plateVersion = records,
        plateRecords = records,
        totals = totals,
        outstanding = outstanding,
        history = history,
    }
end

-- Record a conviction against a citizen and clear the charges it covered.
--
-- This resource deliberately does NOT imprison anyone: sentencing belongs to
-- whatever prison system the server already runs. Call this from that system
-- when a sentence is handed down and the record stays accurate: the Person and
-- Plate views count these rows as "imprisonments", and the rap sheet joins them
-- to show the plea per charge.
--
-- charges: how many charges the sentence covered (defaults to the number of
-- outstanding rows cleared). plea: 'guilty' | 'not_guilty' | 'pending'.
exports('RecordImprisonment', function(citizenid, officer, months, fine, plea)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end

    local pending = MySQL.query.await(
        "SELECT id FROM mdc_charges WHERE citizenid = ? AND status = 'outstanding'", { citizenid }) or {}

    local caseId = MySQL.insert.await([[
        INSERT INTO mdc_imprisonments (citizenid, officer, months, fine, charges, plea)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { citizenid, officer or 'Unknown', tonumber(months) or 0, tonumber(fine) or 0,
          #pending, plea or 'pending' })

    -- Flip the charges this sentence covered out of outstanding so they stop
    -- showing as live and stop generating a warrant.
    if caseId and #pending > 0 then
        MySQL.update.await(
            "UPDATE mdc_charges SET status = 'processed', case_id = ? WHERE citizenid = ? AND status = 'outstanding'",
            { caseId, citizenid })
    end

    return caseId or false
end)

-- Log a plate change. Called by whatever resource performs the re-plating.
exports('RecordPlateChange', function(vin, plate, note)
    if type(vin) ~= 'string' or vin == '' then return false end
    if type(plate) ~= 'string' or plate == '' then return false end
    MySQL.insert.await(
        'INSERT INTO mdc_plate_records (vin, plate, note) VALUES (?, ?, ?)',
        { vin, plate:upper(), type(note) == 'string' and note:sub(1, 160) or '' })
    return true
end)

-- searchPerson {name} -> { found, name, mugshot, phone, totals, outstanding, history, prints }  (NO cid)
-- Read-only: available to court (judge/lawyer) as well as LEO.
-- Totals + outstanding charges + rap sheet for one citizen. Shared by Person
-- Search and Plate Search, so a plate shows the same record as a name lookup.
---@param cid string
---@return table totals, table outstanding, table history
function citizenRecord(cid)
    local totalsRow = MySQL.single.await(TOTALS_SQL, { cid })
    local impRow    = MySQL.single.await(IMPRISONMENTS_COUNT_SQL, { cid })
    local totals = {
        charges = totalsRow and tonumber(totalsRow.charges) or 0,
        citations = totalsRow and tonumber(totalsRow.citations) or 0,
        imprisonments = impRow and tonumber(impRow.imprisonments) or 0,
    }

    local outstanding = MySQL.query.await(OUTSTANDING_FOR_PERSON_SQL, { cid }) or {}
    for _, c in ipairs(outstanding) do
        c.months = tonumber(c.months) or 0
        c.fine = tonumber(c.fine) or 0
        c.modifiers = c.modifiers or ''
    end

    local history = {}
    for _, h in ipairs(MySQL.query.await(HISTORY_FOR_PERSON_SQL, { cid }) or {}) do
        local months = tonumber(h.months) or 0
        history[#history + 1] = {
            code = h.code, title = h.title, class = h.class,
            months = months, fine = tonumber(h.fine) or 0,
            date = h.date or h.created_at,
            officer = h.officer,
            outcome = months > 0 and 'served' or 'paid',
            plea = (h.class == 'citation') and 'na' or (h.plea or 'na'),
        }
    end

    return totals, outstanding, history
end

local function handleSearchPerson(source, data)
    if not getMdcUser(source) then return { found = false } end

    local name = data and data.name
    if type(name) ~= 'string' or name == '' then return { found = false } end

    local row = Bridge.FindCitizenByName(name)
    if not row then return { found = false } end

    local cid = row.cid -- internal only; never returned

    local totals, outstanding, history = citizenRecord(cid)

    local mugRow = MySQL.single.await(MUGSHOT_SELECT_SQL, { cid })
    local mugshot = mugRow and mugRow.image
    if mugshot == '' then mugshot = nil end -- omitted key -> NUI shows placeholder

    -- Fingerprints on file? Boolean only - the cid never leaves the server (anti-metagaming).
    local printRow = MySQL.single.await(PRINTS_SELECT_SQL, { cid })
    local hasPrints = printRow ~= nil

    -- Mugshots are downscaled to ~50KB at capture (in the MDC's own NUI), so they
    -- are small enough to return inline here without overflowing the net event.

    return {
        found = true,
        name = row.name,
        mugshot = mugshot,
        phone = row.phone,
        totals = totals,
        outstanding = outstanding,
        history = history,
        prints = hasPrints,
    }
end

-- getPenalCode {} -> { charges, modifiers }  (read-only: LEO + court)
local function handleGetPenalCode(source)
    if not getMdcUser(source) then return { charges = {}, modifiers = {} } end
    if type(PenalCode) ~= 'table' then return { charges = {}, modifiers = {} } end
    return {
        charges = PenalCode.charges or {},
        modifiers = PenalCode.modifiers or {},
    }
end

-- placeCharges {name, items:[{code, modifiers:[id]}]} -> { success, message }
-- AUTHORITATIVE: recompute months/fine; reject blocked modifiers; record as
-- OUTSTANDING only. NO jail, NO fine. NO cid in response.
local function handlePlaceCharges(source, data)
    local officer = getOfficer(source)
    if not officer then return { success = false, message = 'Not authorized' } end
    if type(data) ~= 'table' then return { success = false, message = 'Invalid request' } end

    local items = data.items
    if type(items) ~= 'table' or #items == 0 then
        return { success = false, message = 'No charges selected' }
    end

    -- One incident can involve several people, so the calculator sends a list.
    -- `name` is still accepted for older callers.
    local names = {}
    if type(data.names) == 'table' then
        for _, n in ipairs(data.names) do
            if type(n) == 'string' and n ~= '' then names[#names + 1] = n end
        end
    elseif type(data.name) == 'string' and data.name ~= '' then
        names[1] = data.name
    end
    if #names == 0 then return { success = false, message = 'No target selected' } end
    if #names > 10 then return { success = false, message = 'Too many targets (max 10)' } end

    -- Resolve EVERY name to a cid before writing anything: a half-applied
    -- incident where one suspect got charges and another did not is worse than
    -- a clean failure. Names never leave the server as cids.
    local targets, seen = {}, {}
    for _, name in ipairs(names) do
                local prow = Bridge.FindCitizenByName(name)
        if not prow then
            return { success = false, message = ('Person not found: %s'):format(name) }
        end
        if not seen[prow.cid] then           -- same person typed twice
            seen[prow.cid] = true
            targets[#targets + 1] = { cid = prow.cid, name = prow.name or name }
        end
    end

    ensureIndex()
    if type(PenalCode) ~= 'table' then
        return { success = false, message = 'Penal code unavailable' }
    end

    local offName = officerName(officer)
    local placed = 0
    local rows = {} -- collect; commit only after full validation passes

    for _, item in ipairs(items) do
        local base = item and chargeIndex[item.code]
        if base then -- unknown codes are silently skipped
            local mult = 1.0

            local blocked = {}
            for _, b in ipairs(base.blockedModifiers or {}) do blocked[b] = true end

            local modList = item.modifiers or {}
            for _, modId in ipairs(modList) do
                if blocked[modId] then
                    return { success = false, message = 'Blocked modifier on ' .. base.code }
                end
                local mod = modIndex[modId]
                if mod and tonumber(mod.mult) then
                    mult = mult * tonumber(mod.mult)
                end
            end

            local m = math.floor((tonumber(base.months) or 0) * mult + 0.5)
            local f = math.floor((tonumber(base.fine) or 0) * mult + 0.5)
            placed = placed + 1

            rows[#rows + 1] = {
                base.code, base.title, base.class, m, f,
                table.concat(modList, ','),
            }
        end
    end

    if placed == 0 then
        return { success = false, message = 'No valid charges to apply' }
    end

    -- Same charge set applied to every target in the incident.
    for _, t in ipairs(targets) do
        for _, r in ipairs(rows) do
            MySQL.insert.await(INSERT_CHARGE_SQL,
                { t.cid, r[1], r[2], r[3], r[4], r[5], r[6], offName, 'Guilty', 'outstanding' })
        end
    end

    -- Mugshots are NOT auto-captured on charge anymore. An officer takes the photo
    -- deliberately at the pdloc 'mugshot' booking camera (mdc:storeBookingMugshot).

    local who = {}
    for _, t in ipairs(targets) do who[#who + 1] = t.name end

    return {
        success = true,
        targets = who,
        charges = placed,
        message = #targets == 1
            and ('Recorded %d charge%s against %s.'):format(placed, placed == 1 and '' or 's', who[1])
            or  ('Recorded %d charge%s against %d people.'):format(placed, placed == 1 and '' or 's', #targets),
    }
end

-- getBolos {} -> { items:[{id,type,title,description,images,officer,created_at}] }
-- Decodes the image_urls JSON array, validates each link, falls back to the
-- legacy single image_url, and exposes ONLY a clean images[] to the NUI.
local function handleGetBolos(source)
    if not getOfficer(source) then return { items = {} } end
    local rows = MySQL.query.await(BOLOS_SELECT_SQL, {}) or {}
    for _, r in ipairs(rows) do
        local list = {}
        if type(r.image_urls) == 'string' and r.image_urls ~= '' then
            local ok, decoded = pcall(json.decode, r.image_urls)
            if ok and type(decoded) == 'table' then
                for _, u in ipairs(decoded) do
                    if type(u) == 'string' and u:match('^https?://') then
                        list[#list + 1] = u
                    end
                end
            end
        end
        -- Back-compat: a pre-migration row with only the legacy single link.
        if #list == 0 and type(r.image_url) == 'string' and r.image_url:match('^https?://') then
            list[#list + 1] = r.image_url
        end
        r.images = list      -- the ONLY image field the NUI reads
        r.image_url = nil    -- do not leak raw columns to the UI
        r.image_urls = nil
    end
    return { items = rows }
end

-- createBolo {type,title,description,images:[http(s) link]} -> { success, message }
-- Accepts an array of links (legacy single image_url still works). Each link is
-- trimmed, must match ^https?://, is capped at 512 chars, and at most 8 are kept.
local function handleCreateBolo(source, data)
    local officer = getOfficer(source)
    if not officer then return { success = false, message = 'Not authorized' } end
    if type(data) ~= 'table' then return { success = false, message = 'Invalid request' } end

    local title = data.title
    if type(title) ~= 'string' or title:gsub('%s+', '') == '' then
        return { success = false, message = 'Title is required' }
    end

    local btype = data.type
    if btype ~= 'person' and btype ~= 'vehicle' and btype ~= 'other' then
        btype = 'person'
    end
    local description = type(data.description) == 'string' and data.description or ''

    local images = {}
    if type(data.images) == 'table' then
        for _, u in ipairs(data.images) do
            if type(u) == 'string' then
                u = u:gsub('^%s+', ''):gsub('%s+$', '')
                if u:match('^https?://') and #u <= 512 then
                    images[#images + 1] = u
                    if #images >= 8 then break end
                end
            end
        end
    elseif type(data.image_url) == 'string' and data.image_url:match('^https?://') then
        images[1] = data.image_url -- legacy single-link callers still work
    end

    local imagesJson = json.encode(images) -- "[]" when none
    local firstUrl = images[1] or ''        -- keep the legacy column populated

    -- Expiry in hours. Absent -> the configured default; 0 -> never expires.
    -- Clamped so a crafted payload cannot pin a BOLO up for years.
    local hours = tonumber(data.expiryHours)
    if hours == nil then hours = Config.Bolo.defaultExpiryHours end
    hours = math.floor(hours)
    if hours < 0 then hours = 0 end
    if hours > Config.Bolo.maxExpiryHours then hours = Config.Bolo.maxExpiryHours end

    MySQL.insert.await(BOLOS_INSERT_SQL,
        { btype, title, description, firstUrl, imagesJson, officerName(officer), hours, hours })

    return {
        success = true,
        message = hours > 0
            and ('BOLO created - expires in %dh'):format(hours)
            or  'BOLO created - no expiry',
    }
end

-- cancelBolo {id} -> { success, message }
local function handleCancelBolo(source, data)
    if not getOfficer(source) then return { success = false, message = 'Not authorized' } end
    local id = data and tonumber(data.id)
    if not id then return { success = false, message = 'Invalid BOLO id' } end

    MySQL.update.await(BOLOS_CANCEL_SQL, { id })
    return { success = true, message = 'BOLO cancelled' }
end

-- getWarrants {} -> { items:[{name, charges, months, fine}] }
-- DERIVED: ONLINE players that currently have status='outstanding' charges. NO cid.
-- Read-only: available to court (judge/lawyer) as well as LEO.
local function handleGetWarrants(source)
    if not getMdcUser(source) then return { items = {} } end

    local items = {}
    local players = Bridge.GetPlayers()
    for _, p in pairs(players) do
        local pd = p.PlayerData
        if pd and pd.citizenid then
            local row = MySQL.single.await(SUM_OUTSTANDING_SQL, { pd.citizenid })
            local charges = row and tonumber(row.charges) or 0
            if charges > 0 then
                items[#items + 1] = {
                    name = fullName(pd.charinfo),
                    charges = charges,
                    months = row and tonumber(row.months) or 0,
                    fine = row and tonumber(row.fine) or 0,
                }
            end
        end
    end
    return { items = items }
end

-- getReports {} -> { items:[{id,title,type,subject_name,officer,created_at}] }  (read-only: LEO + court)
local function handleGetReports(source)
    if not getMdcUser(source) then return { items = {} } end
    local rows = MySQL.query.await(REPORTS_SELECT_SQL, {}) or {}
    return { items = rows }
end

-- getReport {id} -> { found, report }  (read-only: LEO + court)
local function handleGetReport(source, data)
    if not getMdcUser(source) then return { found = false } end
    local id = data and tonumber(data.id)
    if not id then return { found = false } end

    local row = MySQL.single.await(REPORT_SELECT_SQL, { id })
    if not row then return { found = false } end
    return { found = true, report = row }
end

-- createReport {title,type,content,subject_name} -> { success, message }
local function handleCreateReport(source, data)
    local officer = getOfficer(source)
    if not officer then return { success = false, message = 'Not authorized' } end
    if type(data) ~= 'table' then return { success = false, message = 'Invalid request' } end

    local title = data.title
    if type(title) ~= 'string' or title:gsub('%s+', '') == '' then
        return { success = false, message = 'Title is required' }
    end

    local rtype = data.type
    if rtype ~= 'Incident' and rtype ~= 'Arrest' and rtype ~= 'Other' then
        rtype = 'Incident'
    end
    local content = type(data.content) == 'string' and data.content or ''
    local subject = type(data.subject_name) == 'string' and data.subject_name or ''

    MySQL.insert.await(REPORTS_INSERT_SQL, { title, rtype, content, subject, officerName(officer) })
    return { success = true, message = 'Report filed' }
end




----------------------------------------------------------------------
-- CITIZEN ID / WEAPONS / DISPATCH sections
----------------------------------------------------------------------

-- Driver licence number. Derived from the citizenid so it is stable for a
-- character and needs no extra column, but is not the citizenid itself (which
-- must never reach a NUI). Format: DL 520-1C5F-6C589.
local function licenceNumber(cid)
    if not cid or cid == '' then return '' end
    local h1, h2, h3 = 0, 0, 0
    for i = 1, #cid do
        local b = cid:byte(i)
        h1 = (h1 * 31 + b) % 1000
        h2 = (h2 * 37 + b) % 0xFFFF
        h3 = (h3 * 41 + b) % 0xFFFFF
    end
    return ('DL %03d-%04X-%05X'):format(h1, h2, h3)
end

-- charinfo.gender is stored as 0 / 1 by qbx, which is meaningless on a licence.
local function genderLabel(g)
    local n = tonumber(g)
    if n == 0 then return 'Male' end
    if n == 1 then return 'Female' end
    local str = tostring(g or ''):lower()
    if str == 'm' or str == 'male'   then return 'Male' end
    if str == 'f' or str == 'female' then return 'Female' end
    return '-'
end

-- Is this citizen currently connected? qbx's GetSource keys on identifiers, not
-- citizenid, so match the loaded players directly.
local function isOnline(cid)
    for _, p in pairs(Bridge.GetPlayers()) do
        if p.PlayerData and p.PlayerData.citizenid == cid then return true end
    end
    return false
end

local LICENSES_SQL = [[
SELECT type, status,
  DATE_FORMAT(issued,'%Y-%m-%d')  AS issued,
  DATE_FORMAT(expires,'%Y-%m-%d') AS expires,
  issuer
FROM mdc_licenses WHERE citizenid = ? ORDER BY type
]]

local WEAPONS_BY_OWNER_SQL = [[
SELECT serial, weapon, source_label, status,
  DATE_FORMAT(registered_at,'%Y-%m-%d %H:%i:%s') AS registered_at, owner_name
FROM mdc_weapons WHERE owner_name LIKE ? ORDER BY registered_at DESC LIMIT 100
]]

local WEAPONS_RECENT_SQL = [[
SELECT serial, weapon, source_label, status,
  DATE_FORMAT(registered_at,'%Y-%m-%d %H:%i:%s') AS registered_at, owner_name
FROM mdc_weapons ORDER BY registered_at DESC LIMIT 50
]]

local WEAPON_BY_SERIAL_SQL = [[
SELECT serial, weapon, source_label, status, citizenid, owner_name,
  DATE_FORMAT(registered_at,'%Y-%m-%d %H:%i:%s') AS registered_at
FROM mdc_weapons WHERE serial = ? LIMIT 1
]]

-- searchCitizenId {query} -> full DL record + licences on file
local function handleSearchCitizenId(source, data)
    if not getMdcUser(source) then return { found = false } end
    local q = tostring((data and data.query) or ''):gsub('_', ' '):gsub('%s+', ' ')
    q = q:match('^%s*(.-)%s*$') or ''
    if q == '' then return { found = false, message = 'Enter a name.' } end

    local row = Bridge.GetCitizenCard(q)
    if not row then return { found = false, message = 'No citizen on record.' } end

    -- Licences: prefer the MDC ledger, fall back to the qbx metadata booleans
    -- so a fresh install still shows something truthful.
    local licences = {}
    for _, l in ipairs(MySQL.query.await(LICENSES_SQL, { row.cid }) or {}) do
        licences[#licences + 1] = {
            type = l.type, status = l.status,
            issued = l.issued, expires = l.expires, issuer = l.issuer or '',
        }
    end
    if #licences == 0 then
        local flags = row.licences or {}
        local fallback = { { 'Driver', flags.driver }, { 'Firearms', flags.weapon }, { 'ID', flags.id } }
        for _, f in ipairs(fallback) do
            licences[#licences + 1] = { type = f[1], status = f[2] and 'valid' or 'none', issuer = '' }
        end
    end

    -- Licence portrait only. If the citizen has never sat for one the card
    -- shows its placeholder; it must NOT quietly fall back to a mugshot.
    local portrait = MySQL.scalar.await(
        'SELECT image FROM mdc_dmv_photos WHERE citizenid = ? LIMIT 1', { row.cid })

    return {
        found = true,
        name = row.name or 'Unknown',
        dl = licenceNumber(row.cid),
        dob = row.dob or '',
        gender = genderLabel(row.gender),
        phone = row.phone or '',
        photo = portrait or nil,
        online = isOnline(row.cid),
        licences = licences,
    }
end

local function weaponRows(rows)
    local items = {}
    for _, r in ipairs(rows or {}) do
        items[#items + 1] = {
            serial = r.serial,
            weapon = r.weapon,
            owner = r.owner_name or '',
            source = r.source_label or '',
            status = r.status or 'clean',
            registered_at = r.registered_at,
        }
    end
    return items
end

-- getWeapons {name} -> registered firearms for an owner (blank name = newest)
local function handleGetWeapons(source, data)
    if not getMdcUser(source) then return { items = {} } end
    local name = tostring((data and data.name) or ''):gsub('_', ' ')
    name = name:match('^%s*(.-)%s*$') or ''
    if name == '' then
        return { items = weaponRows(MySQL.query.await(WEAPONS_RECENT_SQL, {})) }
    end
    return { items = weaponRows(MySQL.query.await(WEAPONS_BY_OWNER_SQL, { '%' .. name .. '%' })) }
end

-- searchWeapon {serial} -> one registration record
local function handleSearchWeapon(source, data)
    if not getMdcUser(source) then return { found = false } end
    local serial = tostring((data and data.serial) or ''):upper()
    serial = serial:match('^%s*(.-)%s*$') or ''
    if serial == '' then return { found = false, message = 'Enter a serial number.' } end

    local r = MySQL.single.await(WEAPON_BY_SERIAL_SQL, { serial })
    if not r then return { found = false, message = 'No weapon registered to that serial.' } end
    return {
        found = true,
        serial = r.serial, weapon = r.weapon,
        owner = r.owner_name or 'Unknown',
        source = r.source_label or '',
        status = r.status or 'clean',
        registered_at = r.registered_at,
        dl = licenceNumber(r.citizenid),
    }
end

-- setWeaponStatus {serial,status} -> flag a firearm missing / stolen / clean (LEO)
local function handleSetWeaponStatus(source, data)
    local officer = getOfficer(source)
    if not officer then return { success = false, message = 'On-duty LEO only.' } end
    local serial = tostring((data and data.serial) or ''):upper()
    local status = tostring((data and data.status) or ''):lower()
    if serial == '' then return { success = false, message = 'No serial.' } end
    if status ~= 'clean' and status ~= 'missing' and status ~= 'stolen' then
        return { success = false, message = 'Invalid status.' }
    end
    MySQL.update.await('UPDATE mdc_weapons SET status = ? WHERE serial = ?', { status, serial })
    return { success = true, message = ('Serial %s marked %s.'):format(serial, status), status = status }
end







-- Retire expired BOLOs so the table does not fill with active-but-stale rows.
-- The read query already hides them; this just keeps the data honest.
CreateThread(function()
    while true do
        MySQL.query.await(BOLOS_EXPIRE_SWEEP_SQL)
        Wait(600000) -- 10 minutes
    end
end)

-- Register a firearm to a citizen. Exported so a gun store, permit office or
-- evidence locker can file the registration without knowing the schema.
exports('RegisterWeapon', function(citizenid, ownerName, weapon, serial, sourceLabel)
    if type(serial) ~= 'string' or serial == '' then return false end
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    MySQL.insert.await([[
        INSERT INTO mdc_weapons (serial, citizenid, owner_name, weapon, source_label)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE citizenid = VALUES(citizenid), owner_name = VALUES(owner_name),
                                weapon = VALUES(weapon), source_label = VALUES(source_label)
    ]], { serial:upper(), citizenid, ownerName or '', weapon or 'UNKNOWN', sourceLabel or '' })
    return true
end)

----------------------------------------------------------------------
-- Automatic firearm registration.
--
-- ox_inventory stamps a serial into weapon metadata as the item is created, and
-- exposes a 'createItem' hook at exactly that moment. Registering there means
-- every weapon that legitimately enters the world is on file with the source
-- that produced it, without a gun store having to know this resource exists.
-- A resource that wants to file a registration explicitly can still call the
-- RegisterWeapon export above.
----------------------------------------------------------------------

-- ox_inventory keys player inventories by citizenid on qbx; fall back to a
-- source lookup so a numeric inventory id still resolves.
local function ownerFromInventoryId(inventoryId)
    if inventoryId == nil then return nil end
    local key = tostring(inventoryId)

    for _, p in pairs(Bridge.GetPlayers()) do
        local pd = p.PlayerData
        if pd and (pd.citizenid == key or tostring(pd.source) == key) then
            return pd.citizenid, fullName(pd.charinfo)
        end
    end
    return nil
end

CreateThread(function()
    if not (Config.Integrations and Config.Integrations.autoRegisterWeapons) then return end

    -- Wait for ox_inventory; the hook API does not exist until it has started.
    local tries = 0
    while GetResourceState('ox_inventory') ~= 'started' and tries < 100 do
        Wait(250)
        tries = tries + 1
    end
    if GetResourceState('ox_inventory') ~= 'started' then return end

    local ok, err = pcall(function()
        exports.ox_inventory:registerHook('createItem', function(payload)
            local meta = payload and payload.metadata
            local item = payload and payload.item
            if type(meta) ~= 'table' or type(item) ~= 'table' then return end

            local serial = meta.serial
            if type(serial) ~= 'string' or serial == '' then return end

            local name = tostring(item.name or ''):upper()
            if not name:find('^WEAPON_') then return end

            local cid, owner = ownerFromInventoryId(payload.inventoryId)
            if not cid then return end

            local src = payload.resource and ('[%s]'):format(payload.resource) or ''
            exports.mdc:RegisterWeapon(cid, owner, name, serial, src)
        end, { print = false })
    end)

    if not ok then
        print(('[mdc] weapon auto-registration unavailable: %s'):format(tostring(err)))
    end
end)

----------------------------------------------------------------------
-- Register callbacks (both naming conventions for client compatibility)
----------------------------------------------------------------------

local handlers = {
    getDashboard  = handleGetDashboard,
    -- Citizen ID / Weapons / Dispatch sections
    searchCitizenId  = handleSearchCitizenId,
    getWeapons       = handleGetWeapons,
    searchWeapon     = handleSearchWeapon,
    setWeaponStatus  = handleSetWeaponStatus,
    searchVehicle = handleSearchVehicle,
    searchPerson  = handleSearchPerson,
    getPenalCode  = handleGetPenalCode,
    placeCharges  = handlePlaceCharges,
    getBolos      = handleGetBolos,
    createBolo    = handleCreateBolo,
    cancelBolo    = handleCancelBolo,
    getWarrants   = handleGetWarrants,
    getReports    = handleGetReports,
    getReport     = handleGetReport,
    createReport  = handleCreateReport,
}

for name, fn in pairs(handlers) do
    lib.callback.register('mdc:' .. name, fn)        -- task-prompt names
    lib.callback.register('mdc:server:' .. name, fn) -- SPEC.md names
end

----------------------------------------------------------------------
-- Booking camera (officer-driven): store the named citizen's mugshot.
--
-- The officer triggers this from a booking point (see the startBookingMugshot export). They
-- enter a name; the client captures + DOWNSCALES the photo entirely client-side
-- (screenshot-basic raw capture -> the MDC's own NUI resizes it to ~50KB) and
-- sends only the small data URI here. The SERVER just resolves the name ->
-- citizenid and writes it to mdc_mugshots.image. No huge images ever cross
-- the network, so it can be returned inline on lookup with no risk.
----------------------------------------------------------------------

RegisterNetEvent('mdc:storeBookingMugshot', function(first, last, image)
    local src = source
    local officer = getOfficer(src) -- on-duty LEO only
    if not officer then return end
    if type(first) ~= 'string' or type(last) ~= 'string' or type(image) ~= 'string' then return end
    first = first:gsub('^%s+', ''):gsub('%s+$', '')
    last  = last:gsub('^%s+', ''):gsub('%s+$', '')
    if first == '' or last == '' then return end

    -- The client already downscaled to ~50KB; reject anything that is not a small
    -- data URI so a misbehaving client can never store a giant blob.
    if not image:find('^data:image') or #image > 524288 then -- 512KB ceiling
        leoNotify(src, 'Photo rejected (bad/oversized).', 'error')
        return
    end

    local cid = Bridge.FindCitizenExact(first, last)
    if not cid then
        leoNotify(src, ('No citizen found named %s %s.'):format(first, last), 'error')
        return
    end

    MySQL.insert(MUGSHOT_UPSERT_SQL, { cid, image })
    leoNotify(src, ('Mugshot updated for %s %s.'):format(first, last), 'success')
end)

RegisterNetEvent('mdc:storeDmvPhoto', function(first, last, image)
    local src = source
    local player = Bridge.GetPlayer(src)
    if not player or not player.PlayerData then return end

    -- Re-check the job here: the client gate is a convenience, this is the rule.
    local job = player.PlayerData.job or {}
    local allowed = false
    for _, name in ipairs(Config.Dmv.jobs or {}) do
        if job.name == name then allowed = true break end
    end
    if not allowed and Config.Dmv.allowLeo and job.type == 'leo' and job.onduty then
        allowed = true
    end
    if not allowed then return end

    if type(first) ~= 'string' or type(last) ~= 'string' or type(image) ~= 'string' then return end
    first = first:gsub('^%s+', ''):gsub('%s+$', '')
    last  = last:gsub('^%s+', ''):gsub('%s+$', '')
    if first == '' or last == '' then return end

    if not image:find('^data:image') or #image > 524288 then -- 512KB ceiling
        notify(src, 'Photo rejected (bad/oversized).', 'error', 'DMV')
        return
    end

    local cid = Bridge.FindCitizenExact(first, last)
    if not cid then
        notify(src, ('No citizen found named %s %s.'):format(first, last), 'error', 'DMV')
        return
    end

    MySQL.insert.await([[
        INSERT INTO mdc_dmv_photos (citizenid, image, taken_by) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE image = VALUES(image), taken_by = VALUES(taken_by),
                                taken_at = CURRENT_TIMESTAMP
    ]], { cid, image, officerName(player) })

    notify(src, ('Licence photo updated for %s %s.'):format(first, last), 'success', 'DMV')
end)

----------------------------------------------------------------------
-- Fingerprints: an officer triggers this from a 'fingerprint' pdloc or their cruiser
-- (see the collectPrints event) with the NEAREST player's server id. The server re-validates
-- on-duty LEO + a 3.5m proximity, resolves the target's citizenid INTERNALLY, and upserts
-- mdc_prints. The cid never reaches any NUI - searchPerson only returns a boolean.
----------------------------------------------------------------------
RegisterNetEvent('mdc:collectPrints', function(targetId)
    local src = source
    local officer = getOfficer(src) -- on-duty LEO only
    if not officer then leoNotify(src, 'Not authorized.', 'error') return end
    targetId = tonumber(targetId)
    if not targetId then return end
    local target = Bridge.GetPlayer(targetId)
    if not target or not target.PlayerData then
        leoNotify(src, 'No valid person to print.', 'error'); return
    end
    -- Server-side proximity re-check so a spoofed id cannot print someone across the map.
    local op = GetPlayerPed(src)
    local tp = GetPlayerPed(targetId)
    if op == 0 or tp == 0 or #(GetEntityCoords(op) - GetEntityCoords(tp)) > 3.5 then
        leoNotify(src, 'That person is not close enough to print.', 'error'); return
    end
    local cid = target.PlayerData.citizenid
    MySQL.insert(PRINTS_UPSERT_SQL, { cid, officerName(officer) }) -- fire-and-forget upsert (mirrors mugshot)
    local tName = fullName(target.PlayerData.charinfo)
    leoNotify(src, ('Fingerprints collected for %s and added to record.'):format(tName), 'success')
end)

----------------------------------------------------------------------
-- PD units (callsigns). An officer's "unit" IS their callsign (metadata.callsign,
-- which the Active Units dashboard reads). On-duty LEO only.
----------------------------------------------------------------------

local function sanitizeCallsign(raw)
    if type(raw) ~= 'string' then return nil end
    local cs = raw:upper():gsub('[^%w%-]', ''):sub(1, 12)
    if cs == '' then return nil end
    return cs
end

local function currentCallsign(officer)
    local cs = officer.PlayerData.metadata and officer.PlayerData.metadata.callsign
    if cs == nil or cs == '' or cs == 'NO CALLSIGN' then return nil end
    return cs
end

RegisterCommand('createunit', function(source, args)
    local officer = getOfficer(source)
    if not officer then leoNotify(source, 'On-duty officers only.', 'error') return end
    local cs = sanitizeCallsign(args[1])
    if not cs then leoNotify(source, 'Usage: /createunit [CALLSIGN]', 'error') return end
    if currentCallsign(officer) then
        leoNotify(source, ('You are already Unit %s. Use /renameunit or /disbandunit.'):format(currentCallsign(officer)), 'error')
        return
    end
    Bridge.SetMetadata(source, 'callsign', cs)
    leoNotify(source, ('Unit %s created - you are on the air.'):format(cs), 'success')
end, false)

-- Join an existing unit (another on-duty officer's callsign), so multiple officers share a unit.
RegisterCommand('joinunit', function(source, args)
    local officer = getOfficer(source)
    if not officer then leoNotify(source, 'On-duty officers only.', 'error') return end
    local cs = sanitizeCallsign(args[1])
    if not cs then leoNotify(source, 'Usage: /joinunit [CALLSIGN]', 'error') return end
    local exists = false
    for src2, p in pairs(Bridge.GetPlayers()) do
        if tonumber(src2) ~= source then
            local pd = p.PlayerData
            if pd and pd.job and pd.job.type == 'leo' and pd.job.onduty
                and pd.metadata and pd.metadata.callsign == cs then
                exists = true; break
            end
        end
    end
    if not exists then
        leoNotify(source, ('No active unit "%s" to join - use /createunit to start one.'):format(cs), 'error')
        return
    end
    Bridge.SetMetadata(source, 'callsign', cs)
    leoNotify(source, ('You joined Unit %s.'):format(cs), 'success')
end, false)

RegisterCommand('renameunit', function(source, args)
    local officer = getOfficer(source)
    if not officer then leoNotify(source, 'On-duty officers only.', 'error') return end
    local cs = sanitizeCallsign(args[1])
    if not cs then leoNotify(source, 'Usage: /renameunit [CALLSIGN]', 'error') return end
    Bridge.SetMetadata(source, 'callsign', cs)
    leoNotify(source, ('Unit renamed to %s.'):format(cs), 'success')
end, false)

RegisterCommand('disbandunit', function(source)
    local officer = getOfficer(source)
    if not officer then leoNotify(source, 'On-duty officers only.', 'error') return end
    Bridge.SetMetadata(source, 'callsign', 'NO CALLSIGN')
    leoNotify(source, 'Unit disbanded.', 'success')
end, false)

----------------------------------------------------------------------
-- Resource start: create/migrate tables + index penal code
----------------------------------------------------------------------

-- Adds a column only if it does not already exist (robust across MySQL/MariaDB).
local function ensureColumn(tableName, columnName, ddl)
    local row = MySQL.single.await([[
        SELECT COUNT(*) AS c FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], { tableName, columnName })
    if not row or (tonumber(row.c) or 0) == 0 then
        MySQL.query.await(('ALTER TABLE %s ADD COLUMN %s %s'):format(tableName, columnName, ddl))
    end
end

CreateThread(function()
    MySQL.query.await(CREATE_CHARGES_SQL)
    MySQL.query.await(CREATE_BOLOS_SQL)
    MySQL.query.await(CREATE_REPORTS_SQL)
    MySQL.query.await(CREATE_MUGSHOTS_SQL)
    MySQL.query.await(CREATE_IMPRISONMENTS_SQL)
    MySQL.query.await(CREATE_PRINTS_SQL)
    MySQL.query.await(CREATE_WEAPONS_SQL)
    MySQL.query.await(CREATE_LICENSES_SQL)
    MySQL.query.await(CREATE_DMV_PHOTOS_SQL)
    MySQL.query.await(CREATE_PLATE_RECORDS_SQL)

    -- Idempotent migrations for pre-existing installs.
    ensureColumn('mdc_charges', 'status', "VARCHAR(16) DEFAULT 'outstanding'")
    -- Plea system: each imprisonment (case) records the suspect's plea + any guilty-plea cut.
    ensureColumn('mdc_imprisonments', 'plea', "VARCHAR(16) DEFAULT 'pending'")
    ensureColumn('mdc_imprisonments', 'reduced', 'INT DEFAULT 0')
    ensureColumn('mdc_imprisonments', 'charge_list', 'TEXT')
    -- Links a processed charge to the imprisonment (case) it was part of, so the
    -- rap sheet can show the plea per charge.
    ensureColumn('mdc_charges', 'case_id', 'INT DEFAULT 0')
    ensureColumn('mdc_bolos', 'image_url', "VARCHAR(512) DEFAULT ''")
    ensureColumn('mdc_bolos', 'image_urls', 'TEXT')
    ensureColumn('mdc_bolos', 'expires_at', 'DATETIME DEFAULT NULL')
    ensureColumn('mdc_reports', 'subject_name', "VARCHAR(128) DEFAULT ''")

    -- One-time backfill: wrap any legacy single image_url into the JSON array.
    -- JSON_ARRAY() emits valid JSON even if the URL contains quotes or
    -- backslashes, so this is safe. Runs only on rows not yet migrated.
    MySQL.query.await([[
        UPDATE mdc_bolos
        SET image_urls = JSON_ARRAY(image_url)
        WHERE (image_urls IS NULL OR image_urls = '')
          AND image_url IS NOT NULL AND image_url <> ''
    ]])

    buildPenalIndex()
end)
