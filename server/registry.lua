-- Aircraft registry: every heli/plane entity the server knows about. Seeded once with GetAllVehicles,
-- kept current by entityCreated / entityRemoved, and re-synced every 30 s as a safety net. Entities that
-- no longer exist are dropped the moment anyone touches them, so nothing ghosts on the radar.
local Registry = { byEntity = {}, byNet = {}, count = 0 }
NpFR.Registry = Registry

local KINDS = { heli = 'heli', plane = 'plane' }
local RESYNC_MS = 30000

local function trim(s)
  if type(s) ~= 'string' then return nil end
  s = s:match('^%s*(.-)%s*$')
  return s ~= '' and s or nil
end

local function kindOf(entity)
  if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
  if GetEntityType(entity) ~= 2 then return nil end
  return KINDS[GetVehicleType(entity)]
end

function Registry.add(entity)
  if Registry.byEntity[entity] then return Registry.byEntity[entity] end
  local kind = kindOf(entity)
  if not kind then return nil end
  local netId = NetworkGetNetworkIdFromEntity(entity)
  if not netId or netId == 0 then return nil end
  local e = {
    entity = entity, netId = netId, kind = kind, model = GetEntityModel(entity),
    plate = trim(GetVehicleNumberPlateText(entity)), since = GetGameTimer(),
  }
  Registry.byEntity[entity] = e
  Registry.byNet[netId] = e
  Registry.count = Registry.count + 1
  TriggerEvent('np_flightradar:aircraftAdded', netId, kind)
  return e
end

function Registry.remove(entity)
  local e = Registry.byEntity[entity]
  if not e then return end
  Registry.byEntity[entity] = nil
  if Registry.byNet[e.netId] == e then Registry.byNet[e.netId] = nil end
  Registry.count = Registry.count - 1
  if NpFR.Transponder then NpFR.Transponder.forget(entity) end
  TriggerEvent('np_flightradar:aircraftRemoved', e.netId)
end

-- Entry if `entity` is a live registered aircraft (drops it when it vanished)
function Registry.get(entity)
  local e = Registry.byEntity[entity]
  if not e then return nil end
  if not DoesEntityExist(entity) then Registry.remove(entity) return nil end
  return e
end

function Registry.byNetId(netId)
  local e = Registry.byNet[netId]
  if e and not DoesEntityExist(e.entity) then Registry.remove(e.entity) return nil end
  return e
end

-- Live entries (stale ones removed on the way)
function Registry.each()
  local out, stale = {}, nil
  for entity, e in pairs(Registry.byEntity) do
    if DoesEntityExist(entity) then
      out[#out + 1] = e
    else
      stale = stale or {}
      stale[#stale + 1] = entity
    end
  end
  -- removed after iterating (no table mutation inside pairs)
  if stale then for _, entity in ipairs(stale) do Registry.remove(entity) end end
  return out
end

function Registry.scan()
  local seen = {}
  for _, veh in ipairs(GetAllVehicles() or {}) do
    seen[veh] = true
    if not Registry.byEntity[veh] then Registry.add(veh) end
  end
  local stale = {}
  for entity in pairs(Registry.byEntity) do
    if not seen[entity] or not DoesEntityExist(entity) then stale[#stale + 1] = entity end
  end
  for _, entity in ipairs(stale) do Registry.remove(entity) end
end

-- Seats -1..MAX_SEAT: there is no seat-count native server side; empty/nonexistent seats return 0
Registry.MAX_SEAT = 15

-- "Active traffic" filter (Config.Traffic)
function Registry.isActive(e, pilotPed, speed)
  local t = Config.Traffic or {}
  if t.includeParked then return true end
  local piloted = pilotPed ~= nil and pilotPed ~= 0
  local engine = GetIsVehicleEngineRunning(e.entity) == true
  local ok
  if t.requirePilot ~= false and t.requireEngine then ok = piloted and engine
  elseif t.requirePilot ~= false then ok = piloted or engine
  elseif t.requireEngine then ok = engine
  else ok = true end
  if not ok then return false end
  if (t.minSpeed or 0) > 0 and (speed or 0) < t.minSpeed then return false end
  return true
end

AddEventHandler('entityCreated', function(entity)
  if not entity or entity == 0 then return end
  if Registry.add(entity) then return end
  -- the vehicle type is not always known in the very first frame of creation
  if DoesEntityExist(entity) and GetEntityType(entity) == 2 then
    SetTimeout(500, function() Registry.add(entity) end)
  end
end)

AddEventHandler('entityRemoved', function(entity)
  Registry.remove(entity)
end)

function Registry.start()
  Registry.scan()
  -- aircraft that existed before this resource started may carry a transponder bag from its last run
  for _, e in pairs(Registry.byEntity) do e.seeded = true end
  CreateThread(function()
    while true do
      Wait(RESYNC_MS)
      Registry.scan()
    end
  end)
end
