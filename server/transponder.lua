-- Transponder: entity state bag `np_fr_xpdr` = { on, squawk, callsign }, written by the server only.
-- Pilots (and copilots when Config.Transponder.copilotCanEdit) request changes with
-- np_flightradar:setTransponder; the server checks the seat itself and rate-limits per player.
local T = {}
NpFR.Transponder = T
local S = NpFR.Server

local BAG = 'np_fr_xpdr'
T.BAG = BAG

local function cfg() return Config.Transponder or {} end

function T.default()
  return { on = cfg().defaultOn ~= false, squawk = RadarMath.squawk(cfg().defaultSquawk) or '7000', callsign = nil }
end

-- The server's own copy is authoritative: a client that owns the entity can write a replicated entity
-- state bag itself, so the bag is only *published* from here, never trusted. Bags written by a previous
-- run of this resource are adopted once for aircraft found by the start-up scan (resource restart).
local states = {} -- [entity] = { on, squawk, callsign }
T.states = states

local function sanitise(st)
  return {
    on = st.on ~= false,
    squawk = RadarMath.squawk(st.squawk) or T.default().squawk,
    callsign = RadarMath.callsign(st.callsign),
  }
end

function T.get(veh)
  local st = states[veh]
  if not st then
    local e = NpFR.Registry.byEntity[veh]
    if not (e and e.seeded) then return T.default() end
    local ok, bag = pcall(function() return Entity(veh).state[BAG] end)
    st = (ok and type(bag) == 'table') and sanitise(bag) or T.default()
    states[veh] = st
  end
  return { on = st.on, squawk = st.squawk, callsign = st.callsign }
end

function T.forget(veh) states[veh] = nil end

-- ===== callsign resolution ==========================================================================

local function u32(h) return (math.tointeger(tonumber(h) or 0) or 0) & 0xFFFFFFFF end
local perModel = {}
for name, cs in pairs((Config.Callsigns and Config.Callsigns.perModel) or {}) do
  perModel[u32(GetHashKey(name))] = cs
end

local fwCallsign = {} -- [src] = { at, value }
local function pilotCallsign(src)
  if not src then return nil end
  local now = GetGameTimer()
  local c = fwCallsign[src]
  if not c or now - c.at > 30000 then
    c = { at = now, value = RadarMath.callsign(Bridge.playerInfo(src).callsign) }
    fwCallsign[src] = c
  end
  return c.value
end

-- pilot transponder > np_manufacturing vehicleCallsign > Config.Callsigns.perModel > pilot framework
-- callsign > trimmed plate
function T.callsign(e, st, pilotSrc)
  return (st and st.callsign)
    or RadarMath.callsign(S.vehicleCallsign(e.entity))
    or RadarMath.callsign(perModel[u32(e.model)])
    or pilotCallsign(pilotSrc)
    or RadarMath.callsign(e.plate)
    or ('N' .. tostring(e.netId))
end

-- ===== seat check ===================================================================================

-- The aircraft `src` may edit -> veh, entry, seat | nil, reasonKey
function T.editable(src)
  local veh, e, ped = NpFR.Access.aircraftOf(src)
  if not veh then return nil, 'not_in_aircraft' end
  if GetPedInVehicleSeat(veh, -1) == ped then return veh, e, -1 end
  if cfg().copilotCanEdit ~= false and GetPedInVehicleSeat(veh, 0) == ped then return veh, e, 0 end
  return nil, 'not_pilot'
end

-- ===== emergencies ==================================================================================

local function notifyJobs()
  local set = {}
  for _, j in ipairs((Config.Emergency and Config.Emergency.notifyJobs) or {}) do set[j] = true end
  return set
end

function T.emergency(e, squawk, by)
  local st = T.get(e.entity)
  local cs = T.callsign(e, st, by)
  local reason = (Config.Emergency and Config.Emergency.codes and Config.Emergency.codes[squawk]) or 'emergency'
  local c = GetEntityCoords(e.entity)
  local info = {
    callsign = cs, kind = e.kind, reason = reason, by = by,
    coords = c and { x = c.x, y = c.y, z = c.z } or nil,
  }
  TriggerEvent('np_flightradar:emergency', e.netId, squawk, info)

  local jobs = notifyJobs()
  local needDuty = not Config.Access or Config.Access.requireDuty ~= false
  local text = L('emergency_msg', cs, squawk, L('sq_' .. squawk))
  for _, p in ipairs(Bridge.players()) do
    local info = Bridge.playerInfo(p)
    if info.job and jobs[info.job] and not (needDuty and info.onduty == false) then
      S.notify(p, {
        id = 'np_fr_emerg_' .. e.netId, type = 'error', title = L('emergency_title'), message = text,
        icon = 'triangle-exclamation', tint = 'red', duration = 12000, sound = true,
      })
      S.phoneNotify(p, L('emergency_title'), text)
    end
  end
  S.discordLog({
    title = L('emergency_title'),
    description = L('emergency_log', squawk, L('sq_' .. squawk), cs),
    colour = 0xE5484D,
    fields = info.coords and {
      { name = 'Coords', value = ('%.0f, %.0f, %.0f'):format(info.coords.x, info.coords.y, info.coords.z), inline = true },
    } or nil,
    player = by,
  })
end

-- ===== apply ========================================================================================

-- patch = { on?, squawk?, callsign? }  (callsign '' / false resets)
-- -> state | nil, errKey
function T.apply(veh, patch, by)
  local e = NpFR.Registry.get(veh)
  if not e then return nil, 'not_in_aircraft' end
  if type(patch) ~= 'table' then return nil, 'squawk_invalid' end
  local cur = T.get(veh)
  local nxt = { on = cur.on, squawk = cur.squawk, callsign = cur.callsign }

  if patch.on ~= nil then
    if type(patch.on) ~= 'boolean' then return nil, 'squawk_invalid' end
    nxt.on = patch.on
  end
  if patch.squawk ~= nil then
    local sq = RadarMath.squawk(patch.squawk)
    if not sq then return nil, 'squawk_invalid' end
    nxt.squawk = sq
  end
  if patch.callsign ~= nil then
    if patch.callsign == false or patch.callsign == '' then
      nxt.callsign = nil
    else
      if type(patch.callsign) ~= 'string' or #patch.callsign > 32 then return nil, 'callsign_invalid' end
      local cs = RadarMath.callsign(patch.callsign)
      if not cs then return nil, 'callsign_invalid' end
      nxt.callsign = cs
    end
  end

  states[veh] = { on = nxt.on, squawk = nxt.squawk, callsign = nxt.callsign }
  Entity(veh).state:set(BAG, nxt, true)
  local wasEmerg = cur.on and RadarMath.emergency(cur.squawk)
  local isEmerg = nxt.on and RadarMath.emergency(nxt.squawk)
  if isEmerg and isEmerg ~= wasEmerg then T.emergency(e, isEmerg, by) end
  return nxt
end

RegisterNetEvent('np_flightradar:setTransponder', function(data)
  local src = source
  if not Bridge.validSrc(src) or type(data) ~= 'table' then return end
  if not Bridge.throttle(src, 'xpdr', math.max(100, tonumber(cfg().rate) or 1000)) then
    S.notify(src, { type = 'warning', message = L('rate_limited') })
    return
  end
  -- only the three known keys travel on
  local patch = { on = data.on, squawk = data.squawk, callsign = data.callsign }
  local veh, errKey = T.editable(src)
  if not veh then
    S.notify(src, { type = 'error', message = L(errKey) })
    return
  end
  local st, err = T.apply(veh, patch, src)
  if not st then
    S.notify(src, { type = 'error', message = L(err) })
    return
  end
  local msg
  if patch.squawk ~= nil then msg = L('squawk_set', st.squawk)
  elseif patch.callsign ~= nil then msg = st.callsign and L('callsign_set', st.callsign) or L('callsign_reset')
  else msg = st.on and L('xpdr_on_msg') or L('xpdr_off_msg') end
  S.notify(src, { id = 'np_fr_xpdr', type = 'success', message = msg, icon = 'tower-broadcast' })
end)

AddEventHandler('playerDropped', function() fwCallsign[source] = nil end)
