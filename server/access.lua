-- Per-player access: gathers the facts shared/access.lua needs from the server's own view of the world
-- (framework job, item, admin, Discord, seat, station position) and caches the slow part. The cache is
-- dropped on job/duty/load events and expires after 30 s; positional facts are always fresh.
local A = { cache = {}, checks = {} }
NpFR.Access = A
local S = NpFR.Server

local TTL = 30000
A.TTL = TTL

-- RegisterAccessCheck(fn(src, mode) -> bool): extra veto hooks from other resources
function A.addCheck(fn)
  if type(fn) == 'function' or (type(fn) == 'table' and getmetatable(fn) and getmetatable(fn).__call) then
    A.checks[#A.checks + 1] = fn
    return true
  end
  return false
end

local function static(src)
  local now = GetGameTimer()
  local c = A.cache[src]
  if c and now - c.at < TTL then return c end
  local info = Bridge.playerInfo(src) or {}
  c = {
    at = now,
    job = info.job, grade = info.grade or 0, onduty = info.onduty ~= false,
    isAdmin = Bridge.isAdmin(src), hasItem = S.hasItem(src), discordOk = S.discordOk(src),
  }
  A.cache[src] = c
  return c
end
A.static = static

-- The aircraft `src` sits in (any seat) -> veh, entry, ped
function A.aircraftOf(src)
  local ped = GetPlayerPed(src)
  if not ped or ped == 0 then return nil end
  local veh = GetVehiclePedIsIn(ped, false)
  if not veh or veh == 0 then return nil, nil, ped end
  local e = NpFR.Registry.get(veh) or NpFR.Registry.add(veh)
  if not e then return nil, nil, ped end
  return veh, e, ped
end

function A.stationAt(coords)
  if not coords then return nil end
  for _, st in ipairs(Config.Stations or {}) do
    local c = st.coords
    if c and RadarMath.dist3d(coords.x, coords.y, coords.z, c.x, c.y, c.z) <= (st.radius or 25.0) then
      return st
    end
  end
  return nil
end

function A.facts(src)
  local c = static(src)
  local veh, _, ped = A.aircraftOf(src)
  ped = ped or GetPlayerPed(src)
  local coords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
  return {
    inAircraft = veh ~= nil, job = c.job, grade = c.grade, onduty = c.onduty,
    hasItem = c.hasItem, station = A.stationAt(coords), isAdmin = c.isAdmin,
    discordOk = c.discordOk, licensed = S.licensed(src),
  }
end

local function veto(src)
  return function(mode)
    if type(Config.CanUse) == 'function' then
      local ok, res = pcall(Config.CanUse, src, mode)
      if ok and res == false then return false end
    end
    for _, fn in ipairs(A.checks) do
      local ok, res = pcall(fn, src, mode)
      if ok and res == false then return false end
    end
    return true
  end
end

-- mode: one of Access.MODES or 'auto' (best panel mode) -> { mode, range, primary } | nil
function A.resolve(src, mode)
  if not Bridge.validSrc(src) then return nil end
  local facts = A.facts(src)
  if mode == 'auto' or mode == nil then return Access.best(facts, Config, veto(src)) end
  return Access.resolve(facts, Config, mode, veto(src))
end

function A.summary(src)
  local facts = A.facts(src)
  local v = veto(src)
  local best = Access.best(facts, Config, v)
  return { modes = Access.modes(facts, Config, v), best = best and best.mode or nil }
end

function A.push(src)
  if Bridge.validSrc(src) then TriggerClientEvent('np_flightradar:access', src, A.summary(src)) end
end

function A.invalidate(src, push)
  A.cache[src] = nil
  if NpFR.Broadcast then NpFR.Broadcast.recheck(src) end
  if push then A.push(src) end
end

Bridge.onPlayerChanged(function(src) A.invalidate(src, true) end)
AddEventHandler('playerDropped', function() A.cache[source] = nil end)
