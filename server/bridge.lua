--[[
    FRAMEWORK BRIDGE
    ================

    THIS IS THE ONLY FILE YOU NEED TO REWRITE TO RUN THE MDC ON A DIFFERENT
    FRAMEWORK OR A DIFFERENT DATABASE SCHEMA.

    Everything else in the resource talks to players and citizen records through
    the functions below. The shipped implementation targets Qbox (qbx_core) with
    the standard `players` / `player_vehicles` tables.

    To port it, replace the bodies below. Keep the RETURN SHAPES exactly as
    documented. The rest of the resource depends on them and on nothing else.

    Contract
    --------
    Bridge.GetPlayer(src)              -> player | nil
    Bridge.GetPlayers()                -> { [src] = player }
    Bridge.SetMetadata(src, key, val)  -> nil
    Bridge.FindCitizenByName(query)    -> { cid, name, phone } | nil
    Bridge.FindCitizenExact(f, l)      -> cid | nil
    Bridge.GetCitizenCard(query)       -> { cid, name, dob, gender, phone,
                                            licences = { driver, weapon, id } } | nil
    Bridge.FindVehicleByPlate(plate)   -> { cid, plate, model, vin, owner, phone } | nil

    A `player` object must expose:
        player.PlayerData.source        number
        player.PlayerData.citizenid     string
        player.PlayerData.charinfo      { firstname, lastname, phone, birthdate, gender }
        player.PlayerData.job           { name, type, onduty, grade = { level, name } }
        player.PlayerData.metadata      table  (the MDC reads/writes 'callsign' and 'optin')
        player.Functions.RemoveMoney(account, amount, reason) -> boolean

    `job.type` must be 'leo' for police-type jobs. If your framework has no job
    types, map them here (see JOB_TYPES below).
]]

Bridge = {}

-- If your framework has no job "type" concept, list your police jobs here and
-- GetPlayer will synthesise job.type = 'leo' for them.
local JOB_TYPES = {
    -- ['police']  = 'leo',
    -- ['sheriff'] = 'leo',
}

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

---@param src number
---@return table|nil
function Bridge.GetPlayer(src)
    local player = exports.qbx_core:GetPlayer(src)
    if not player or not player.PlayerData then return nil end

    local job = player.PlayerData.job
    if job and not job.type and JOB_TYPES[job.name] then
        job.type = JOB_TYPES[job.name]
    end
    return player
end

---Every loaded player, keyed by server id.
---@return table<number, table>
function Bridge.GetPlayers()
    return exports.qbx_core:GetQBPlayers() or {}
end

---@param src number
---@param key string
---@param value any
function Bridge.SetMetadata(src, key, value)
    exports.qbx_core:SetMetadata(src, key, value)
end

--------------------------------------------------------------------------------
-- Citizen records
--
-- These read the framework's own player table. On Qbox, character data lives in
-- `players.charinfo` as JSON. Rewrite the SQL (or replace it with an API call)
-- if your data lives elsewhere. Only the return shape matters.
--------------------------------------------------------------------------------

local PERSON_SQL = [[
SELECT
  citizenid                                        AS cid,
  TRIM(CONCAT(
    COALESCE(JSON_VALUE(charinfo,'$.firstname'),''),' ',
    COALESCE(JSON_VALUE(charinfo,'$.lastname'),''))) AS name,
  COALESCE(phone_number, JSON_VALUE(charinfo,'$.phone')) AS phone
FROM players
WHERE CONCAT(JSON_VALUE(charinfo,'$.firstname'),' ',JSON_VALUE(charinfo,'$.lastname')) LIKE ?
   OR JSON_VALUE(charinfo,'$.firstname') LIKE ?
   OR JSON_VALUE(charinfo,'$.lastname')  LIKE ?
   OR phone_number LIKE ?
   OR JSON_VALUE(charinfo,'$.phone') LIKE ?
LIMIT 1
]]

---Fuzzy lookup used by Person Search and the arrest calculator.
---@param query string a partial name or phone number
---@return table|nil { cid, name, phone }
function Bridge.FindCitizenByName(query)
    local q = '%' .. tostring(query or '') .. '%'
    return MySQL.single.await(PERSON_SQL, { q, q, q, q, q })
end

local EXACT_CID_SQL = [[
SELECT citizenid AS cid FROM players
WHERE LOWER(JSON_VALUE(charinfo,'$.firstname')) = LOWER(?)
  AND LOWER(JSON_VALUE(charinfo,'$.lastname'))  = LOWER(?)
LIMIT 1
]]

---Exact first+last match, used by the booking and DMV cameras.
---@return string|nil citizenid
function Bridge.FindCitizenExact(first, last)
    local row = MySQL.single.await(EXACT_CID_SQL, { first, last })
    return row and row.cid or nil
end

local CITIZEN_CARD_SQL = [[
SELECT
  citizenid                                        AS cid,
  TRIM(CONCAT(
    COALESCE(JSON_VALUE(charinfo,'$.firstname'),''),' ',
    COALESCE(JSON_VALUE(charinfo,'$.lastname'),''))) AS name,
  JSON_VALUE(charinfo,'$.birthdate')               AS dob,
  JSON_VALUE(charinfo,'$.gender')                  AS gender,
  COALESCE(phone_number, JSON_VALUE(charinfo,'$.phone')) AS phone,
  JSON_VALUE(metadata,'$.licences.driver')         AS lic_driver,
  JSON_VALUE(metadata,'$.licences.weapon')         AS lic_weapon,
  JSON_VALUE(metadata,'$.licences.id')             AS lic_id
FROM players
WHERE CONCAT(JSON_VALUE(charinfo,'$.firstname'),' ',JSON_VALUE(charinfo,'$.lastname')) LIKE ?
   OR REPLACE(CONCAT(JSON_VALUE(charinfo,'$.firstname'),'_',JSON_VALUE(charinfo,'$.lastname')),'__','_') LIKE ?
   OR JSON_VALUE(charinfo,'$.lastname') LIKE ?
LIMIT 1
]]

---Citizen ID lookup: identity plus whatever licence flags the framework holds.
---@param query string
---@return table|nil { cid, name, dob, gender, phone, licences = { driver, weapon, id } }
function Bridge.GetCitizenCard(query)
    local like = '%' .. tostring(query or '') .. '%'
    local row = MySQL.single.await(CITIZEN_CARD_SQL, { like, like, like })
    if not row then return nil end

    local function truthy(v)
        return v == 'true' or v == true or v == 1 or v == '1'
    end

    return {
        cid = row.cid,
        name = row.name,
        dob = row.dob,
        gender = row.gender,
        phone = row.phone,
        licences = {
            driver = truthy(row.lic_driver),
            weapon = truthy(row.lic_weapon),
            id     = truthy(row.lic_id),
        },
    }
end

--------------------------------------------------------------------------------
-- Vehicles
--------------------------------------------------------------------------------

local VEHICLE_SQL = [[
SELECT
  pv.citizenid                                     AS cid,
  pv.plate                                         AS plate,
  pv.vehicle                                       AS model,
  CONCAT('VIN-', LPAD(pv.id, 8, '0'))              AS vin,
  TRIM(CONCAT(
    COALESCE(JSON_VALUE(p.charinfo,'$.firstname'),''),' ',
    COALESCE(JSON_VALUE(p.charinfo,'$.lastname'),'')))  AS owner,
  COALESCE(p.phone_number, JSON_VALUE(p.charinfo,'$.phone')) AS phone
FROM player_vehicles pv
LEFT JOIN players p ON p.citizenid = pv.citizenid
WHERE REPLACE(UPPER(pv.plate),' ','') = REPLACE(UPPER(?),' ','')
LIMIT 1
]]

---@param plate string
---@return table|nil { cid, plate, model, vin, owner, phone }
---`cid` is used server-side to pull the owner's record and is NEVER returned to the NUI.
function Bridge.FindVehicleByPlate(plate)
    return MySQL.single.await(VEHICLE_SQL, { plate })
end
