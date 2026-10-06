-- Settings editable in np_admin (optional: without np_admin this is a no-op and config.lua stays as written).
-- Config-only: Config.CanUse (function), Config.Stations (vec3 coords), Config.Admin (fallback without
-- np_admin), commands / key, item, phone app gate, callsigns, orgs, emergency codes and the integration
-- switches. 'live' = read at use time (server access changes re-resolve every subscriber at once);
-- shared keys reach the clients through GlobalState and apply on the next panel open / radar update.
local m = 'm'

npAdmin.settings({
  label = 'Flight radar', icon = 'plane-up', tint = 'blue',
  target = Config,
  categories = { 'General', 'Ranges', 'Traffic', 'Access', 'Transponder', 'Emergencies', 'TCAS', 'Blips' },
  fields = {
    -- General
    { key = 'Locale', category = 'General', type = 'select', label = 'Language', options = { 'en', 'de' },
      help = 'Notifications at once, the panel on its next open.', apply = 'live', scope = 'shared' },
    { key = 'Framework', category = 'General', type = 'select', label = 'Framework',
      options = { 'auto', 'esx', 'qbx', 'qb', 'standalone' }, apply = 'restart', scope = 'server' },
    { key = 'UpdateInterval', category = 'General', type = 'number', label = 'Radar update interval',
      help = 'Time between radar updates sent to every subscriber.', min = 250, max = 5000, step = 50, unit = 'ms',
      apply = 'live', scope = 'shared' },
    { key = 'Units', category = 'General', type = 'select', label = 'Units',
      options = { { value = 'aviation', label = 'Aviation (ft, kt, fpm, NM)' }, { value = 'metric', label = 'Metric (m, km/h, m/s, km)' } },
      help = 'Applied on the next panel open.', apply = 'live', scope = 'shared' },

    -- Ranges (0 = unlimited)
    { key = 'Ranges.air', category = 'Ranges', type = 'number', label = 'Onboard radar (in an aircraft)',
      help = '0 = unlimited.', min = 0, max = 50000, step = 500, unit = m, apply = 'live', scope = 'server' },
    { key = 'Ranges.ground', category = 'Ranges', type = 'number', label = 'Ground radar (jobs)',
      help = '0 = unlimited.', min = 0, max = 50000, step = 500, unit = m, apply = 'live', scope = 'server' },
    { key = 'Ranges.item', category = 'Ranges', type = 'number', label = 'Handheld scanner item',
      help = '0 = unlimited.', min = 0, max = 50000, step = 500, unit = m, apply = 'live', scope = 'server' },
    { key = 'Ranges.station', category = 'Ranges', type = 'number', label = 'Radar station (tower)',
      help = '0 = unlimited.', min = 0, max = 50000, step = 500, unit = m, apply = 'live', scope = 'server' },
    { key = 'Ranges.phone', category = 'Ranges', type = 'number', label = 'Phone app',
      help = '0 = unlimited.', min = 0, max = 50000, step = 500, unit = m, apply = 'live', scope = 'server' },
    { key = 'RangeSteps', category = 'Ranges', type = 'list', item = 'number', label = 'Range steps in the panel',
      help = 'Metres, 0 = unlimited. Capped at the granted range; applied on the next panel open.',
      apply = 'live', scope = 'shared' },

    -- Traffic
    { key = 'Traffic.requirePilot', category = 'Traffic', type = 'toggle', label = 'Someone in the pilot seat',
      apply = 'live', scope = 'server' },
    { key = 'Traffic.requireEngine', category = 'Traffic', type = 'toggle', label = 'Engine running',
      help = 'On: pilot AND engine. Off: pilot OR engine.', apply = 'live', scope = 'server' },
    { key = 'Traffic.minSpeed', category = 'Traffic', type = 'number', label = 'Minimum speed',
      help = 'Slower aircraft are hidden. 0 = off.', min = 0, max = 100, step = 1, unit = 'm/s', apply = 'live', scope = 'server' },
    { key = 'Traffic.includeParked', category = 'Traffic', type = 'toggle', label = 'Show parked aircraft too',
      apply = 'live', scope = 'server' },

    -- Access
    { key = 'Access.inAircraft', category = 'Access', type = 'toggle', label = 'Onboard radar for everyone in an aircraft',
      apply = 'live', scope = 'shared' },
    { key = 'Access.jobs', category = 'Access', type = 'json', label = 'Ground radar jobs',
      help = 'Job = minimum grade, e.g. { "police": 0, "atc": 0 }. Stations without own jobs use this list too.',
      apply = 'live', scope = 'server' },
    { key = 'Access.requireDuty', category = 'Access', type = 'toggle', label = 'Require on duty',
      help = 'qb/qbx duty flag; on ESX having the job counts.', apply = 'live', scope = 'server' },
    { key = 'Access.discordRoles', category = 'Access', type = 'list', item = 'string', label = 'Discord roles (ground radar)',
      help = 'np_discord role ids or names. Checked on join and job change; the 10 min refresh needs a restart when the list was empty at start.',
      apply = 'live', scope = 'server' },
    { key = 'Identification.checkPilotLicense', category = 'Access', type = 'toggle', label = 'Flag pilots without a licence',
      help = 'np_identification pilot_license.', apply = 'live', scope = 'server' },
    { key = 'Identification.requireLicenseForAirRadar', category = 'Access', type = 'toggle',
      label = 'Onboard radar needs a pilot licence', apply = 'live', scope = 'server' },
    { key = 'PrimaryRadar.enabled', category = 'Access', type = 'toggle', label = 'Primary radar (stations, admins)',
      help = 'Shows aircraft with the transponder off as "unidentified".', apply = 'live', scope = 'server' },
    { key = 'PrimaryRadar.range', category = 'Access', type = 'number', label = 'Primary radar range',
      min = 0, max = 50000, step = 500, unit = m, apply = 'live', scope = 'server' },

    -- Transponder
    { key = 'Transponder.defaultOn', category = 'Transponder', type = 'toggle', label = 'On by default',
      apply = 'live', scope = 'shared' },
    { key = 'Transponder.defaultSquawk', category = 'Transponder', type = 'text', label = 'Default squawk',
      pattern = '^[0-7][0-7][0-7][0-7]$', maxLength = 4, apply = 'live', scope = 'shared' },
    { key = 'Transponder.copilotCanEdit', category = 'Transponder', type = 'toggle', label = 'Copilot may edit',
      apply = 'live', scope = 'shared' },
    { key = 'Transponder.rate', category = 'Transponder', type = 'number', label = 'Rate limit per player',
      min = 100, max = 10000, step = 100, unit = 'ms', apply = 'live', scope = 'server' },

    -- Emergencies
    { key = 'Emergency.notifyJobs', category = 'Emergencies', type = 'list', item = 'string', label = 'Jobs notified on 7500/7600/7700',
      apply = 'live', scope = 'server' },
    { key = 'Emergency.discordChannel', category = 'Emergencies', type = 'text', label = 'np_discord log channel',
      help = 'Channel name, e.g. aviation. Empty = no Discord log (np_admin logs every emergency anyway).',
      maxLength = 64, apply = 'live', scope = 'server' },

    -- TCAS
    { key = 'Proximity.enabled', category = 'TCAS', type = 'toggle', label = 'TCAS-lite for pilots', apply = 'live', scope = 'shared' },
    { key = 'Proximity.horizontal', category = 'TCAS', type = 'number', label = 'Traffic advisory: horizontal',
      help = 'Resolution advisory = half of it.', min = 100, max = 3000, step = 10, unit = m, apply = 'live', scope = 'shared' },
    { key = 'Proximity.vertical', category = 'TCAS', type = 'number', label = 'Traffic advisory: vertical',
      min = 30, max = 1000, step = 10, unit = m, apply = 'live', scope = 'shared' },
    { key = 'Proximity.lookahead', category = 'TCAS', type = 'number', label = 'Look-ahead',
      help = 'Time to the closest point of approach.', min = 5, max = 120, step = 1, unit = 's', apply = 'live', scope = 'shared' },
    { key = 'Proximity.sound', category = 'TCAS', type = 'toggle', label = 'Alert sound', apply = 'live', scope = 'shared' },

    -- Blips (GTA blip colour ids)
    { key = 'Blips.heli.scale', category = 'Blips', type = 'number', label = 'Helicopter blip size',
      min = 0.3, max = 2, step = 0.1, apply = 'live', scope = 'shared' },
    { key = 'Blips.plane.scale', category = 'Blips', type = 'number', label = 'Plane blip size',
      min = 0.3, max = 2, step = 0.1, apply = 'live', scope = 'shared' },
    { key = 'Blips.showForPhone', category = 'Blips', type = 'toggle', label = 'Map blips for the phone app',
      apply = 'live', scope = 'shared' },
    { key = 'Blips.colours.police', category = 'Blips', type = 'number', label = 'Colour: police',
      min = 0, max = 85, step = 1, apply = 'live', scope = 'shared' },
    { key = 'Blips.colours.ems', category = 'Blips', type = 'number', label = 'Colour: EMS',
      min = 0, max = 85, step = 1, apply = 'live', scope = 'shared' },
    { key = 'Blips.colours.emergency', category = 'Blips', type = 'number', label = 'Colour: emergency squawk',
      min = 0, max = 85, step = 1, apply = 'live', scope = 'shared' },
    { key = 'Blips.colours.unidentified', category = 'Blips', type = 'number', label = 'Colour: unidentified',
      min = 0, max = 85, step = 1, apply = 'live', scope = 'shared' },
  },
})

local function prefixed(key, list)
  for _, p in ipairs(list) do
    if key:sub(1, #p) == p then return true end
  end
  return false
end

if IsDuplicityVersion() then
  -- access-related change: re-resolve every player now instead of at the next 5 / 30 s recheck
  local ACCESS = { 'Ranges.', 'Access.', 'Identification.', 'PrimaryRadar.' }
  npAdmin.onChange('*', function(_, _, key)
    if type(key) == 'string' and prefixed(key, ACCESS) and NpFR and NpFR.Access then NpFR.Access.invalidateAll() end
  end)
else
  -- blip look changed: restyle every blip on the next radar update (the style cache only tracks colours)
  npAdmin.onChange('*', function(_, _, key)
    if type(key) == 'string' and prefixed(key, { 'Blips.' }) and NpFR and NpFR.Blips then
      for _, b in pairs(NpFR.Blips.list) do b.style = nil end
    end
  end)
end
