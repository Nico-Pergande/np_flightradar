fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'np_flightradar'
author 'Nico-Pergande'
description 'Server-authoritative flight radar: live aircraft blips, transponder/squawk, TCAS-lite proximity alerts, ATC stations and a phone app'
version '1.0.0'
repository 'https://github.com/Nico-Pergande/np_flightradar'

--[[
  Optional siblings (auto-detected, each can be switched off in Config.Integrations):
    es_extended / qbx_core / qb-core   jobs, grades, duty, admin groups, callsigns (standalone works too)
    np_hud             notifications, top-right zone claim while the panel is open
    np_phone           "Flightradar" store app with live traffic, emergency push notifications
    np_inventory       usable 'flight_radar' scanner item (ESX usable item as fallback)
    np_identification  pilot licence check ('pilot_license') -> unlicensed flag
    np_discord         radar access by Discord role, emergency log channel
    np_menu            radial entries: flight radar + transponder submenu
    np_manufacturing   vehicle callsigns (state bag vehicleCallsign)
    np_helicam         camera-active flag (state bag helicam_cam)
]]

dependency '/onesync'

shared_scripts {
  'config.lua',
  'shared/locale.lua',
  'locales/*.lua',
  'shared/radarmath.lua',
  'shared/access.lua',
  'integrations/registry.lua',
}

server_scripts {
  'bridge/server.lua',
  'integrations/server.lua',
  'server/registry.lua',
  'server/access.lua',
  'server/transponder.lua',
  'server/broadcast.lua',
  'server/exports.lua',
  'server/main.lua',
}

client_scripts {
  'bridge/client.lua',
  'integrations/client.lua',
  'client/blips.lua',
  'client/radar.lua',
  'client/transponder.lua',
  'client/proximity.lua',
  'client/nui.lua',
  'client/phone.lua',
  'client/main.lua',
}

ui_page 'html/index.html'

files {
  'html/index.html',
  'html/app.js',
  'html/radar.js',
  'html/style.css',
  'html/phone.html',
  'html/phone.js',
  'html/vendor/**/*',
  'html/fonts/**/*',
}
