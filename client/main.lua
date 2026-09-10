--[[
    Mobile Data Computer - CLIENT
    Qbox MDC. Required: qbx_core + ox_lib. Optional: screenshot-basic (mugshots).

    Responsibilities:
      - /mdc command + F11 keybind -> open the NUI for LEO
        (PlayerData.job.type == 'leo' covers police/bcso/sasp) and for court
        (job.name 'judge'/'lawyer' -> restricted read-only role). The server
        re-checks the role on every callback.
      - Relay every NUI data fetch to the authoritative server callbacks
        via lib.callback.await('mdc:<name>', ...).
      - Booking / DMV camera: a target zone or command calls the exports
        -> ask for a name, drop to first person + viewfinder; on [E] capture via
        screenshot-basic, downscale the photo IN OUR OWN NUI to ~50KB, then send
        the small image to the server to store against the named citizen.
      - closeMdc is handled entirely client-side (releases NUI focus).

    NUI <-> client contract (fetch https://mdc/<name>):
      Relayed to authoritative server callbacks (lib.callback.await):
        getDashboard  {}                 -> mdc:getDashboard
        searchVehicle {plate}            -> mdc:searchVehicle
        searchPerson  {name}             -> mdc:searchPerson
        getPenalCode  {}                 -> mdc:getPenalCode
        placeCharges  {name, items}      -> mdc:placeCharges
        getBolos      {}                 -> mdc:getBolos
        createBolo    {type,...}          -> mdc:createBolo
        cancelBolo    {id}               -> mdc:cancelBolo
        getWarrants   {}                 -> mdc:getWarrants  (derived)
        getReports    {}                 -> mdc:getReports
        getReport     {id}               -> mdc:getReport
        createReport  {title,...}         -> mdc:createReport
      Client-only (no server hop):
        closeMdc      {}                 -> SetNuiFocus(false) + restore cam

    Outbound (client -> NUI) messages:
      {action='open'} {action='close'}

    NOTE (REDESIGN2): the old jail-proximity thread / {jailProximity} message /
    BOOKING_POINTS and the Send-to-Jail + Issue-Fine buttons are GONE. Imprisonment
    and forced fines now happen exclusively through the server /jail command at the
    Department of Corrections; placeCharges only RECORDS outstanding charges.
]]

local isOpen = false

----------------------------------------------------------------------

local function mdtRole()
    local data = ClientBridge.GetPlayerData()
    if data == nil or data.job == nil then return nil end
    if data.job.type == 'leo' and data.job.onduty == true then return 'leo' end
    if data.job.name == 'judge' or data.job.name == 'lawyer' then return 'court' end
    return nil
end

-- True only when the local player is an ON-DUTY LEO (radar, booking cam).
local function isLeo()
    return mdtRole() == 'leo'
end

----------------------------------------------------------------------
-- Open / close
----------------------------------------------------------------------

-- Client-side feedback, routed through Config.Notify like the server helper.
local function mdcNotify(message, ntype)
    if Config.Notify.mode == 'chat' then
        local kind = ({ success = 'ok', error = 'err', inform = 'info' })[ntype or 'inform'] or 'info'
        TriggerEvent('chat:addMessage', {
            templateId = Config.Notify.template,
            args = { 'MDC', message, kind },
        })
        return
    end

    lib.notify({
        title = 'MDC',
        description = message,
        type = ntype or 'inform',
        position = Config.Notify.position,
    })
end

local function openMdc()
    if isOpen then return end
    local role = mdtRole()
    if not role then
        mdcNotify('You are not authorized to use the police terminal.', 'error')
        return
    end

    isOpen = true
    SetNuiFocus(true, true)
    -- role drives the NUI: 'court' hides the Arrest Calculator, BOLO create
    -- form and every action button; 'ems' sees ONLY the Medical tab. The
    -- server enforces the same role on every callback, so this is
    -- presentation only.
    SendNUIMessage({
        action = 'open',
        role = role,
        -- config.lua stays the single source of truth for the expiry choices;
        -- the NUI builds its dropdown from whatever is sent here.
        boloExpiry = {
            options = Config.Bolo.expiryOptions,
            default = Config.Bolo.defaultExpiryHours,
        },
        sections = Config.Sections,
    })
end

local function closeMdc()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    -- Tell the UI to hide (it already releases its own state on close).
    SendNUIMessage({ action = 'close' })
end

-- Plate-lookup entry point: any resource (radar HUD, ANPR, etc) can fire this
-- local event to open the MDC
-- straight onto the Vehicle tab with the selected plate already searched.
AddEventHandler('mdc:runPlate', function(plate)
    if not isLeo() then return end
    if type(plate) ~= 'string' or plate == '' then return end
    if not isOpen then
        isOpen = true
        SetNuiFocus(true, true)
    end
    SendNUIMessage({
        action = 'open', plate = plate, role = 'leo', -- isLeo() checked above
        boloExpiry = {
            options = Config.Bolo.expiryOptions,
            default = Config.Bolo.defaultExpiryHours,
        },
        sections = Config.Sections,
    })
end)

----------------------------------------------------------------------
-- Command + keybind
----------------------------------------------------------------------

-- Entry point. Both the command name and the default key come from config.lua
-- so a server can avoid clashing with whatever else it runs (ps-mdt binds /mdt,
-- for example) without editing this file.
RegisterCommand(Config.Command, function()
    -- Toggle: the key / command opens when closed and closes when open.
    if isOpen then closeMdc() else openMdc() end
end, false)

-- Players can always rebind in GTA's key settings; this is only the default.
if Config.Keybind then
    RegisterKeyMapping(Config.Command, Config.CommandLabel, 'keyboard', Config.Keybind)
end

----------------------------------------------------------------------
-- Plea prompt (suspect side). After /jail processing, the suspect picks a
-- plea; guilty waives a trial and cuts the sentence. /plea re-opens a pending one.
----------------------------------------------------------------------

local RELAY_CALLBACKS = {
    'getDashboard',
    'searchVehicle', 'searchPerson',
    'getPenalCode', 'placeCharges',
    'getBolos', 'createBolo', 'cancelBolo',
    'getWarrants',
    'getReports', 'getReport', 'createReport',
    -- Citizen ID / Weapons
    'searchCitizenId', 'getWeapons', 'searchWeapon', 'setWeaponStatus',
}

for _, name in ipairs(RELAY_CALLBACKS) do
    RegisterNUICallback(name, function(data, cb)
        cb(lib.callback.await('mdc:' .. name, false, data or {}))
    end)
end

----------------------------------------------------------------------
-- NUI callbacks - client-only (no server hop).
----------------------------------------------------------------------

-- closeMdc {} - release focus, restore cam, ack the UI.
RegisterNUICallback('closeMdc', function(_, cb)
    closeMdc()
    cb('ok')
end)

----------------------------------------------------------------------
-- Booking camera (officer-driven). The officer
-- "takes out a camera": we ask for the individual's name, drop to first person
-- with a viewfinder overlay, and on [E] capture the framed view via screenshot-
-- basic. The raw shot is downscaled in OUR OWN NUI (downscaleMugshot) and the
-- small result is sent to the server (storeBookingMugshot) for the named citizen.
----------------------------------------------------------------------

-- kind = 'mugshot' (police booking) | 'dmv' (licence portrait). Same camera,
-- different destination. See startPhotoCapture below.
local booking = { on = false, capturing = false, prevView = nil, first = nil, last = nil, kind = 'mugshot' }

local function bookingCleanup()
    booking.on = false
    booking.capturing = false
    booking.first = nil
    booking.last = nil
    booking.kind = 'mugshot'
    SendNUIMessage({ action = 'bookingViewfinder', on = false })
    if booking.prevView ~= nil then
        SetFollowPedCamViewMode(booking.prevView)
        booking.prevView = nil
    end
end

-- Capture the officer's current (first-person) view, then hand the raw shot to
-- our OWN NUI to downscale to ~50KB. The NUI posts the small image back via the
-- 'mugProcessed' callback. Nothing depends on screenshot-basic's NUI patch.
local function snapBookingPhoto()
    exports['screenshot-basic']:requestScreenshot({ encoding = 'jpg', quality = 0.7 }, function(dataUri)
        if type(dataUri) == 'string' and dataUri:find('data:image', 1, true) then
            SendNUIMessage({ action = 'downscaleMugshot', src = dataUri })
        else
            bookingCleanup()
            lib.notify({ title = 'Booking Camera', description = 'Capture failed - try again.', type = 'error' })
        end
    end)
end

-- Exported so a booking point (ox_target zone, /command, whatever the server
-- uses) can launch the flow: exports.mdc:startBookingMugshot().
-- DMV photos are taken by DMV staff, not police. Config lists the jobs that
-- may operate the counter camera; the server re-checks on store.
local function canTakeDmvPhoto()
    local data = ClientBridge.GetPlayerData()
    local job = data and data.job
    if not job then return false end
    for _, name in ipairs(Config.Dmv.jobs or {}) do
        if job.name == name then return true end
    end
    if Config.Dmv.allowLeo and job.type == 'leo' and job.onduty then return true end
    return false
end

-- One camera, two destinations.
--   'mugshot' -> police booking photo, stored against the arrest record
--   'dmv'     -> the portrait taken at the DMV counter, shown on the licence
-- They are deliberately separate images: a licence should show the photo the
-- citizen sat for, not the shot taken of them after an arrest.
local PHOTO_KINDS = {
    mugshot = { title = 'Booking Photo', camera = 'Booking Camera' },
    dmv     = { title = 'DMV Licence Photo', camera = 'DMV Camera' },
}

local function startPhotoCapture(kind)
    if booking.on then return end
    local meta = PHOTO_KINDS[kind] or PHOTO_KINDS.mugshot

    if kind == 'dmv' then
        if not canTakeDmvPhoto() then
            lib.notify({ title = meta.camera, description = 'DMV staff only.', type = 'error' })
            return
        end
    elseif not isLeo() then
        lib.notify({ title = meta.camera, description = 'On-duty officers only.', type = 'error' })
        return
    end

    local input = lib.inputDialog(meta.title, {
        { type = 'input', label = 'First name', required = true, max = 30 },
        { type = 'input', label = 'Last name',  required = true, max = 30 },
    })
    if not input then return end
    local first = (input[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local last  = (input[2] or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if first == '' or last == '' then return end

    booking.on = true
    booking.capturing = false
    booking.kind = kind
    booking.first = first
    booking.last = last
    booking.prevView = GetFollowPedCamViewMode()
    SetFollowPedCamViewMode(4) -- first person: a clean shot of whoever is framed
    SendNUIMessage({ action = 'bookingViewfinder', on = true, name = first .. ' ' .. last })

    CreateThread(function()
        while booking.on do
            Wait(0)
            HideHudAndRadarThisFrame() -- keep the HUD/minimap out of the photo
            if not booking.capturing then
                if IsControlJustPressed(0, 38) then          -- E = capture
                    booking.capturing = true
                    SendNUIMessage({ action = 'bookingViewfinder', on = false })
                    snapBookingPhoto()
                    SetTimeout(8000, function() if booking.on then bookingCleanup() end end) -- safety
                elseif IsControlJustPressed(0, 177) or IsControlJustPressed(0, 200) then -- Backspace / ESC = cancel
                    bookingCleanup()
                    lib.notify({ title = meta.camera, description = 'Cancelled.', type = 'inform' })
                    return
                end
            end
        end
    end)
end

local function startBookingMugshot() startPhotoCapture('mugshot') end
local function startDmvPhoto()       startPhotoCapture('dmv') end

exports('startBookingMugshot', startBookingMugshot)
exports('startDmvPhoto', startDmvPhoto)

RegisterCommand('dmvphoto', function() startDmvPhoto() end, false)

-- The NUI returns the downscaled photo; send it (small) to the server, then
-- restore the officer's view.
RegisterNUICallback('mugProcessed', function(data, cb)
    cb('ok')
    local first, last, kind = booking.first, booking.last, booking.kind
    bookingCleanup()
    if first and last and type(data) == 'table'
       and type(data.src) == 'string' and data.src ~= '' then
        TriggerServerEvent(
            kind == 'dmv' and 'mdc:storeDmvPhoto' or 'mdc:storeBookingMugshot',
            first, last, data.src)
    else
        lib.notify({ title = 'Booking Camera', description = 'Photo processing failed.', type = 'error' })
    end
end)

----------------------------------------------------------------------
-- Safety: release focus + restore cam if the resource stops while open.
----------------------------------------------------------------------

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    bookingCleanup() -- restore view if the resource stops mid-booking
    if isOpen then
        isOpen = false
        SetNuiFocus(false, false)
    end
end)
