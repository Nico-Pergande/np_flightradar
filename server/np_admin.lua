-- np_admin integration (optional: without np_admin every call here is a no-op and permissions fall back
-- to console, the convars np_admin_fallback / np_admin_fallback_groups and Config.Admin, see
-- bridge/server.lua). Nodes, staff tools and access refreshes when a player's np_admin groups change.
local A, T = NpFR.Access, NpFR.Transponder

npAdmin.permissions({
  { node = 'np_flightradar.admin', label = 'Admin flight radar', category = 'Flight radar',
    description = 'Admin radar mode: every aircraft, unlimited range, primary radar (transponder off). Also the staff tools below.' },
  { node = 'np_flightradar.ground', label = 'Ground radar', category = 'Flight radar',
    description = 'Ground radar without one of the Config.Access.jobs (staff, standalone servers). Range Config.Ranges.ground.' },
})

-- ===== staff tools ("Resource tools" in np_admin) ===================================================

npAdmin.action({
  name = 'np_flightradar.open', label = 'Open admin flight radar', icon = 'satellite-dish', tint = 'blue',
  perm = 'np_flightradar.admin', target = 'none',
  description = 'Opens the flight radar panel in admin mode (every aircraft, primary radar).',
  handler = function(src)
    TriggerClientEvent('np_flightradar:openRadar', src, 'admin')
    return true
  end,
})

local SQUAWK = '^[0-7][0-7][0-7][0-7]$'

npAdmin.action({
  name = 'np_flightradar.transponder', label = 'Set transponder', icon = 'tower-broadcast', tint = 'blue',
  perm = 'np_flightradar.admin', target = 'player',
  description = 'Sets squawk, callsign or transponder power of the aircraft the player sits in. Empty = unchanged.',
  args = {
    { key = 'squawk', type = 'text', label = 'Squawk', maxLength = 4, pattern = SQUAWK, placeholder = '7000' },
    { key = 'callsign', type = 'text', label = 'Callsign', maxLength = 8, help = '"-" resets to the automatic callsign.' },
    { key = 'power', type = 'select', label = 'Transponder', options = { 'unchanged', 'on', 'off' }, default = 'unchanged' },
  },
  handler = function(_, target, args)
    args = type(args) == 'table' and args or {}
    local veh = A.aircraftOf(target)
    if not veh then return false, 'Player is not in an aircraft' end
    local patch = {}
    if type(args.squawk) == 'string' and args.squawk ~= '' then patch.squawk = args.squawk end
    if type(args.callsign) == 'string' and args.callsign ~= '' then
      if args.callsign == '-' then patch.callsign = false else patch.callsign = args.callsign end
    end
    if args.power == 'on' then patch.on = true elseif args.power == 'off' then patch.on = false end
    if next(patch) == nil then return false, 'Nothing to change' end
    local st, err = T.apply(veh, patch, target)
    if not st then return false, L(err) end
    return true, { squawk = st.squawk, callsign = st.callsign, on = st.on }
  end,
})

-- ===== access refresh ===============================================================================

-- np_admin pushes this (server-side TriggerEvent) when a player's groups / nodes change
AddEventHandler('np_admin:permissionsChanged', function(src)
  local from = tonumber(source)
  if from and from > 0 then return end
  src = math.tointeger(tonumber(src))
  if src and Bridge.validSrc(src) then A.invalidate(src, true) end
end)

-- np_admin (re)started or stopped: the source of truth changed for everyone
AddEventHandler('np_admin:ready', function() A.invalidateAll() end)
AddEventHandler('onServerResourceStop', function(res)
  if res == 'np_admin' then A.invalidateAll() end
end)
