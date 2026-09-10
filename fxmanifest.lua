fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mdc'
author 'mdc contributors'
description 'Mobile Data Computer - police records terminal for FiveM'
version '2.0.0'

-- ox_lib is loaded ONCE here so `lib`, `cache` and the global `PenalCode`
-- (from shared/penalcode.lua) are available in BOTH client and server.
-- Do not re-list @ox_lib/init.lua in client_scripts/server_scripts.
shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/penalcode.lua', -- external build; provides global PenalCode (client + server)
}

client_scripts {
    'client/bridge.lua', -- framework adapter (client side) - PORT THIS FILE
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/bridge.lua', -- framework/database adapter - PORT THIS FILE
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/logo.png',
}

-- Hard requirements only. screenshot-basic (mugshots + DMV photos) is OPTIONAL:
-- see Config.Integrations in config.lua.
dependencies {
    'qbx_core',
    'ox_lib',
    'oxmysql',
}
