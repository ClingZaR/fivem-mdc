--[[
    Mobile Data Computer (MDC) - configuration.

    Everything a server owner is expected to change lives here. The resource is
    Qbox-native (qbx_core + ox_lib + oxmysql are required); every other
    integration below is optional and degrades gracefully when the resource is
    not installed.
]]

Config = {}

-- How the MDC opens.
Config.Command = 'mdc'
Config.Keybind = 'F11'          -- set to false to register no default key
Config.CommandLabel = 'Open Mobile Data Computer'


-- Notifications.
--   'ox_lib' -> lib.notify (portable; the default, works on any Qbox install)
--   'chat'   -> chat:addMessage with Config.Notify.template, for servers that
--               route system feedback through a themed chat template.
Config.Notify = {
    mode = 'ox_lib',
    template = 'mdc:notify',    -- args: { tag, message, kind } where kind = ok|err|info
    position = 'top',
}

-- Optional integrations. Set false to disable even if the resource is present.
Config.Integrations = {
    screenshotBasic = true,     -- booking mugshots (screenshot-basic)

    -- Auto-file a firearm into the weapon registry the moment ox_inventory
    -- stamps it with a serial. Without this (or a resource calling the
    -- RegisterWeapon export) the Weapon List stays empty.
    autoRegisterWeapons = true,
}

-- Sections. Set one false to hide its rail button and panel entirely; the
-- server still refuses its callbacks, so hiding is not the only guard. Useful
-- for a server that has no CCTV, no DMV, or wants a stripped MDC.
Config.Sections = {
    person       = true,   -- record search
    citizenid    = true,
    vehicle      = true,   -- plate search
    weaponlist   = true,
    weaponsearch = true,
    calculator   = true,   -- panel only; reached from a person/weapon record
    bolos        = true,
    warrants     = true,
    dashboard    = true,   -- active units
}

-- DMV. The licence portrait is a SEPARATE image from the police mugshot: a
-- driver licence shows the photo the citizen sat for at the counter, not the
-- shot taken of them after an arrest. Captured with /dmvphoto (or the
-- exports.mdc:startDmvPhoto() export from a DMV counter target).
Config.Dmv = {
    jobs = { 'dmv' },   -- jobs allowed to operate the counter camera
    allowLeo = true,    -- on-duty police may also take one (small servers)
}

-- "Copy BOLO Text" on a plate lookup. Edit the template to match how your
-- department words a BOLO; the tokens are substituted at copy time.
--
--   {time}    18:42 PM        {plate}    H0PE
--   {date}    10/SEP          {owner}    Jimmi Jones
--   {detail}  see below       {vin}      ZWAG3ZJAJHWPUA000
--   {model}   Coquette D5     {phone}    5183727
--   {extra}   see below       {charges}  count of outstanding charges
Config.BoloText = {
    template = '{time} {date} | {detail} {model} | LP: {plate} | RO: {owner} | {extra}',
    detail = 'DETAIL_HERE',   -- placeholder the officer overwrites after pasting
    extra  = 'EXTRA_INFO',
}

-- Dismissing an outstanding charge.
--
-- A dismissal does NOT delete anything. The charge stops being outstanding (so
-- it clears the warrant and stops counting against the suspect) but stays on
-- the record permanently, showing who dismissed it. Accountability is the point.
Config.ChargeDismissal = {
    minLeoGrade = 3,               -- supervisors and above
    allowBoss   = true,            -- any job grade flagged isboss
    justiceJobs = { 'judge' },     -- add 'lawyer' if your server wants it
}

-- BOLOs. An expired BOLO stops showing to officers but is kept in the table,
-- so the record of what was put out and when survives.
Config.Bolo = {
    defaultExpiryHours = 24,
    -- Offered in the create form. 0 = never expires (kept until cancelled).
    expiryOptions = { 1, 6, 12, 24, 48, 72, 168, 0 },
    maxExpiryHours = 720,        -- 30 days; anything higher is clamped
}


