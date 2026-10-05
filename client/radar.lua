-- Subscription + contact state. Several things may want radar data at once (the panel, the phone app,
-- simply sitting in an aircraft); the client subscribes with the most capable wish and the server decides
-- what it really gets. Contacts arrive as a full set: whatever is missing is gone.
local Radar = {
  wants = {},          -- source -> mode ('panel' | 'item' | 'phone' | 'air')
  sub = nil,           -- granted { mode, range, primary }
  pending = nil,       -- { reqId, mode, source }
  reqId = 0,
  meta = {},           -- [netId] = meta from the server
  contacts = {},       -- merged list (NUI shape + internals)
  byId = {},
  receivedAt = 0,
  access = { modes = {}, best = nil },
  listeners = {},
}
NpFR.Radar = Radar

-- air outranks phone: the onboard subscription draws blips and feeds TCAS, and the phone app shows
-- whatever is subscribed. Phone first would wipe a pilot's blips while the app is open.
local PRIORITY = { 'panel', 'air', 'phone' }

function Radar.on(fn) Radar.listeners[#Radar.listeners + 1] = fn end

local function emit(kind, data)
  for _, fn in ipairs(Radar.listeners) do
    local ok, err = pcall(fn, kind, data)
    if not ok then NpFR.debug('listener failed', err) end
  end
end

local function effective()
  for _, src in ipairs(PRIORITY) do
    if Radar.wants[src] then return Radar.wants[src], src end
  end
  return nil
end

local function resetContacts()
  Radar.contacts, Radar.byId, Radar.meta = {}, {}, {}
  NpFR.Blips.clear()
end

local function apply()
  local mode, source = effective()
  if not mode then
    if Radar.sub or Radar.pending then TriggerServerEvent('np_flightradar:unsubscribe') end
    Radar.sub, Radar.pending = nil, nil
    resetContacts()
    emit('unsubscribed')
    return
  end
  if Radar.pending and Radar.pending.mode == mode then return end
  if Radar.sub and Radar.sub.requested == mode and not Radar.pending then
    emit('subscribed', Radar.sub)
    return
  end
  Radar.reqId = Radar.reqId + 1
  Radar.pending = { reqId = Radar.reqId, mode = mode, source = source }
  TriggerServerEvent('np_flightradar:subscribe', mode, Radar.reqId)
end

-- source: 'panel' | 'phone' | 'air'; mode: requested mode or nil to drop that wish
function Radar.want(source, mode)
  if Radar.wants[source] == mode then return end
  Radar.wants[source] = mode
  apply()
end

function Radar.wanting(source) return Radar.wants[source] end
function Radar.isSubscribed() return Radar.sub ~= nil end

-- any mode a panel could open with (radial / hints)
function Radar.canOpen()
  local m = Radar.access.modes or {}
  return m.admin or m.station or m.ground or m.air or m.item or false
end

RegisterNetEvent('np_flightradar:access', function(summary)
  if type(summary) ~= 'table' then return end
  Radar.access = { modes = type(summary.modes) == 'table' and summary.modes or {}, best = summary.best }
end)

local function setSub(data, requested, source, reqId)
  local prevMode = Radar.sub and Radar.sub.mode
  Radar.sub = {
    mode = data.mode, range = tonumber(data.range) or 0, primary = data.primary == true,
    requested = requested, source = source, reqId = reqId,
  }
  if prevMode and prevMode ~= data.mode then resetContacts() end
  emit('subscribed', Radar.sub)
end

RegisterNetEvent('np_flightradar:subscribed', function(data)
  if type(data) ~= 'table' then return end
  -- server-side re-resolve of the current subscription (mode / range changed, e.g. left the aircraft)
  if data.update and not Radar.pending and Radar.sub and data.reqId == Radar.sub.reqId then
    setSub(data, Radar.sub.requested, Radar.sub.source, Radar.sub.reqId)
    return
  end
  if not Radar.pending or data.reqId ~= Radar.pending.reqId then return end
  local p = Radar.pending
  Radar.pending = nil
  -- the wish may have changed while the answer was in flight
  if effective() ~= p.mode then apply() return end
  setSub(data, p.mode, p.source, p.reqId)
end)

RegisterNetEvent('np_flightradar:denied', function(data)
  if type(data) ~= 'table' or not Radar.pending or data.reqId ~= Radar.pending.reqId then return end
  local p = Radar.pending
  Radar.pending = nil
  Radar.sub = nil
  -- drop the wish that was denied; a lower one (e.g. air) may still be granted
  Radar.wants[p.source] = nil
  emit('denied', p)
  apply()
end)

-- The server dropped the current subscription. Only the wish behind it is dropped: another one (phone
-- app still open, still flying) is asked for again. A request already in flight is kept, its answer
-- refers to the new subscription.
RegisterNetEvent('np_flightradar:revoked', function(reason)
  local src = Radar.sub and Radar.sub.source
  Radar.sub = nil
  if src then Radar.wants[src] = nil end
  resetContacts()
  emit('revoked', reason)
  if src == 'panel' then NpFR.Client.notify({ type = 'warning', message = L('access_lost') }) end
  -- still flying? ask again with the onboard radar
  NpFR.Main.checkAircraft()
  if not Radar.pending then apply() end
end)

-- ===== data =========================================================================================

local function modelLabel(hash)
  if type(hash) ~= 'number' then return nil end
  local name = GetDisplayNameFromVehicleModel(hash)
  if not name or name == '' or name == 'CARNOTFOUND' then return nil end
  local label = GetLabelText(name)
  if label and label ~= 'NULL' and label ~= '' then return label end
  return name:sub(1, 1) .. name:sub(2):lower()
end

RegisterNetEvent('np_flightradar:meta', function(meta)
  if type(meta) ~= 'table' or not Radar.sub then return end
  for key, m in pairs(meta) do
    local id = math.tointeger(tonumber(key))
    if id and type(m) == 'table' then
      m.modelLabel = modelLabel(m.model)
      m.flags = type(m.flags) == 'table' and m.flags or {}
      Radar.meta[id] = m
    end
  end
end)

-- Self position (ped, or the aircraft when inside one) -> x, y, z, compass heading, inAircraft
function Radar.self()
  local ped = PlayerPedId()
  local veh = GetVehiclePedIsIn(ped, false)
  local ent = veh ~= 0 and veh or ped
  local c = GetEntityCoords(ent)
  return c.x, c.y, c.z, RadarMath.compass(GetEntityHeading(ent)), NpFR.Main.aircraftClass(veh)
end

RegisterNetEvent('np_flightradar:contacts', function(payload)
  if type(payload) ~= 'table' or type(payload.c) ~= 'table' or not Radar.sub then return end
  local now = GetGameTimer()
  local sx, sy = Radar.self()
  local list, byId, keepMeta = {}, {}, {}
  for i = 1, math.min(#payload.c, 512) do
    local u = RadarMath.unpack(payload.c[i])
    local m = u and Radar.meta[u.id]
    if m then
      local f = m.flags
      local c = {
        id = u.id, kind = m.kind == 'plane' and 'plane' or 'heli',
        callsign = m.callsign, model = m.modelLabel, squawk = (not f.xpdrOff) and m.squawk or nil,
        x = u.x, y = u.y, z = u.z, alt = u.z, heading = RadarMath.compass(u.h), speed = u.speed, vs = u.vs,
        dist = RadarMath.dist2d(sx, sy, u.x, u.y), bearing = RadarMath.bearing(sx, sy, u.x, u.y),
        flags = {
          emergency = f.emergency, xpdrOff = f.xpdrOff == true, unlicensed = f.unlicensed == true,
          camera = f.camera == true, org = m.org,
        },
        threat = NpFR.Proximity.threatOf(u.id),
        -- internals (blips, proximity)
        h = u.h, vx = u.vx, vy = u.vy, vz = u.vz, t = now,
      }
      list[#list + 1] = c
      byId[c.id] = c
      keepMeta[c.id] = m
    end
  end
  table.sort(list, function(a, b) return a.dist < b.dist end)
  -- the server re-sends meta when an aircraft comes back, so forget everything not in this set
  Radar.meta, Radar.contacts, Radar.byId, Radar.receivedAt = keepMeta, list, byId, now

  local s = Radar.sub
  if s and (s.mode ~= 'phone' or (Config.Blips and Config.Blips.showForPhone)) then
    NpFR.Blips.sync(list, now)
  else
    NpFR.Blips.clear()
  end
  NpFR.Proximity.update(list)
  emit('contacts', list)
  TriggerEvent('np_flightradar:contactsUpdated', list)
end)

-- Public shape for exports / phone / NUI (internals stripped)
function Radar.public(list, range)
  local out = {}
  for i = 1, #list do
    local c = list[i]
    if RadarMath.inRange(c.dist, range) then
      out[#out + 1] = {
        id = c.id, kind = c.kind, callsign = c.callsign, model = c.model, x = c.x, y = c.y, z = c.z,
        alt = c.alt, heading = c.heading, speed = c.speed, vs = c.vs, dist = c.dist, bearing = c.bearing,
        squawk = c.squawk, flags = c.flags, threat = NpFR.Proximity.threatOf(c.id),
      }
    end
  end
  return out
end

-- { self, range, contacts } as the NUI / phone expect it
function Radar.payload(range)
  local x, y, z, heading, inAircraft = Radar.self()
  range = range or (Radar.sub and Radar.sub.range) or 0
  return {
    self = { x = x, y = y, z = z, heading = heading, inAircraft = inAircraft and true or false },
    range = range,
    contacts = Radar.public(Radar.contacts, range),
  }
end

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  Radar.wants, Radar.sub = {}, nil
end)
