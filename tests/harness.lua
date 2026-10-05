-- Plain-Lua (5.4) server harness: stubs the FiveM natives, events, exports, state bags, entities and a
-- controllable clock with a cooperative thread scheduler, then boots the server files in fxmanifest order.
--   local H = dofile('tests/harness.lua')
--   H.boot()                 shared (incl. the np_admin lib + settings) + bridge/server + integrations/server + server/*.lua
--   H.advance(ms)            run threads / timers up to now + ms
local H = {}
_G.H = H

local rawPrint = print
H.log = {}
function print(...)
  local first = tostring((...))
  if first:find('np_flightradar', 1, true) and not os.getenv('VERBOSE') then
    H.log[#H.log + 1] = table.concat({ ... }, ' ')
    return
  end
  rawPrint(...)
end

H.now = 0
H.threads = {}
H.handlers = {}        -- name -> { fn }
H.clientEvents = {}    -- { name, target, args }
H.localEvents = {}     -- TriggerEvent log { name, args }
H.exports = {}         -- our exports
H.siblings = {}        -- resource -> { exportName = fn(...) }
H.resources = { np_flightradar = 'started' }
H.entities = {}        -- handle -> entity
H.players = {}         -- src -> { ped, name, ids }
H.calls = {}           -- native call counters

local function count(name) H.calls[name] = (H.calls[name] or 0) + 1 end

-- ===== vectors ======================================================================================
local vmt = {}
vmt.__index = vmt
vmt.__add = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end
vmt.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
function vector3(x, y, z) return setmetatable({ x = x + 0.0, y = y + 0.0, z = z + 0.0 }, vmt) end
vec3 = vector3

-- ===== scheduler ====================================================================================
function CreateThread(fn)
  local co = coroutine.create(fn)
  H.threads[#H.threads + 1] = { co = co, wake = H.now }
end
Citizen = { CreateThread = CreateThread }

function Wait(ms)
  local co, main = coroutine.running()
  assert(not main, 'Wait outside a thread')
  coroutine.yield(H.now + (ms or 0))
end
Citizen.Wait = Wait

function SetTimeout(ms, fn)
  CreateThread(function() Wait(ms) fn() end)
end

local function runReady()
  local progressed = true
  while progressed do
    progressed = false
    local list = H.threads
    H.threads = {}
    for _, t in ipairs(list) do
      if coroutine.status(t.co) ~= 'dead' then
        if t.wake <= H.now then
          local ok, res = coroutine.resume(t.co)
          if not ok then error('thread error: ' .. tostring(res), 0) end
          if coroutine.status(t.co) ~= 'dead' then
            t.wake = res or H.now
            H.threads[#H.threads + 1] = t
          end
          progressed = true
        else
          H.threads[#H.threads + 1] = t
        end
      end
    end
  end
end

function H.advance(ms)
  local target = H.now + ms
  runReady()
  while true do
    local nextWake
    for _, t in ipairs(H.threads) do
      if coroutine.status(t.co) ~= 'dead' and (not nextWake or t.wake < nextWake) then nextWake = t.wake end
    end
    if not nextWake or nextWake > target then break end
    H.now = math.max(H.now, nextWake)
    runReady()
  end
  H.now = target
  runReady()
end

function H.liveThreads()
  local n = 0
  for _, t in ipairs(H.threads) do if coroutine.status(t.co) ~= 'dead' then n = n + 1 end end
  return n
end

-- ===== events =======================================================================================
function AddEventHandler(name, fn)
  H.handlers[name] = H.handlers[name] or {}
  table.insert(H.handlers[name], fn)
  return { name = name, fn = fn }
end
function RegisterNetEvent(name, fn)
  if fn then return AddEventHandler(name, fn) end
end
RegisterServerEvent = RegisterNetEvent

local function dispatch(name, src, ...)
  for _, fn in ipairs(H.handlers[name] or {}) do
    local prev = _G.source
    _G.source = src
    fn(...)
    _G.source = prev
  end
end

function TriggerEvent(name, ...)
  H.localEvents[#H.localEvents + 1] = { name = name, args = table.pack(...) }
  dispatch(name, '', ...)
end
function H.fromClient(name, src, ...) dispatch(name, src, ...) end

function TriggerClientEvent(name, target, ...)
  H.clientEvents[#H.clientEvents + 1] = { name = name, target = target, args = table.pack(...) }
end

-- last client event `name` for `target` after index `since`
function H.lastClient(name, target, since)
  for i = #H.clientEvents, (since or 0) + 1, -1 do
    local e = H.clientEvents[i]
    if e.name == name and e.target == target then return e.args, i end
  end
  return nil
end
function H.countClient(name, target, since)
  local n = 0
  for i = (since or 0) + 1, #H.clientEvents do
    local e = H.clientEvents[i]
    if e.name == name and (target == nil or e.target == target) then n = n + 1 end
  end
  return n
end
function H.countLocal(name)
  local n = 0
  for _, e in ipairs(H.localEvents) do if e.name == name then n = n + 1 end end
  return n
end

-- ===== exports ======================================================================================
exports = setmetatable({}, {
  __call = function(_, name, fn) H.exports[name] = fn end,
  __index = function(_, res)
    return setmetatable({}, {
      __index = function(_, fnName)
        return function(_, ...)
          local r = H.siblings[res]
          if not r or not r[fnName] then error('No such export ' .. fnName .. ' in resource ' .. res) end
          return r[fnName](...)
        end
      end,
    })
  end,
})

-- ===== resources / misc natives =====================================================================
function GetResourceState(res) return H.resources[res] or 'missing' end
function GetCurrentResourceName() return 'np_flightradar' end
function GetResourceMetadata() return '1.0.0' end
H.convars = { onesync = 'on' }  -- unset convars return the default
function GetConvar(name, def)
  local v = H.convars[name]
  if v == nil then return def end
  return v
end
H.invoking = nil                 -- GetInvokingResource() result (np_admin:settingsChanged checks it)
function GetInvokingResource() return H.invoking end
function IsDuplicityVersion() return true end
function GetGameTimer() return H.now end
function GetHashKey(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:lower():byte(i)) & 0xFFFFFFFF end
  return h
end

-- ===== players ======================================================================================
local nextHandle = 1000
local function newHandle() nextHandle = nextHandle + 1 return nextHandle end

function H.addPlayer(src, opts)
  opts = opts or {}
  local ped = newHandle()
  H.entities[ped] = { type = 1, coords = opts.coords or vector3(0, 0, 0), heading = 0.0, vel = vector3(0, 0, 0), state = {} }
  H.players[src] = { ped = ped, name = opts.name or ('player' .. src), ids = opts.ids or { 'license:p' .. src } }
  return ped
end

function GetPlayers()
  local out = {}
  for src in pairs(H.players) do out[#out + 1] = tostring(src) end
  table.sort(out)
  return out
end
function GetPlayerName(src) local p = H.players[tonumber(src)] return p and p.name or nil end
function GetPlayerPed(src) local p = H.players[tonumber(src)] return p and p.ped or 0 end
function GetPlayerIdentifiers(src) local p = H.players[tonumber(src)] return p and p.ids or {} end

-- ===== entities =====================================================================================
-- H.spawnAircraft{ vtype='heli', coords, heading, vel, engine, model, plate } -> handle (no event fired)
function H.spawnAircraft(o)
  local h = newHandle()
  H.entities[h] = {
    type = 2, vtype = o.vtype or 'heli', coords = o.coords or vector3(0, 0, 100), heading = o.heading or 0.0,
    vel = o.vel or vector3(0, 0, 0), engine = o.engine ~= false, model = GetHashKey(o.model or 'polmav'),
    plate = o.plate or ' AB123  ', netId = h - 1000 + 5000, seats = {}, state = {},
  }
  return h
end

function H.seat(src, veh, seat)
  local ped = H.players[src].ped
  -- leave any previous vehicle
  for _, e in pairs(H.entities) do
    if e.seats then for s, p in pairs(e.seats) do if p == ped then e.seats[s] = nil end end end
  end
  H.entities[ped].vehicle = veh
  if veh then
    H.entities[veh].seats[seat] = ped
    H.entities[ped].coords = H.entities[veh].coords
  end
end

function H.delete(h) H.entities[h] = nil end

function DoesEntityExist(h) return H.entities[h] ~= nil end
function GetEntityType(h) local e = H.entities[h] return e and e.type or 0 end
function GetVehicleType(h) local e = H.entities[h] return e and e.vtype or nil end
function NetworkGetNetworkIdFromEntity(h) local e = H.entities[h] return e and e.netId or 0 end
function GetEntityModel(h) local e = H.entities[h] return e and e.model or 0 end
function GetVehicleNumberPlateText(h) local e = H.entities[h] return e and e.plate or '' end
function GetAllVehicles()
  count('GetAllVehicles')
  local out = {}
  for h, e in pairs(H.entities) do if e.type == 2 then out[#out + 1] = h end end
  return out
end
function GetEntityCoords(h)
  count('GetEntityCoords')
  local e = H.entities[h]
  if not e then return vector3(0, 0, 0) end
  if e.vehicle and H.entities[e.vehicle] then return H.entities[e.vehicle].coords end
  return e.coords
end
function GetEntityHeading(h) local e = H.entities[h] return e and e.heading or 0.0 end
function GetEntityVelocity(h) local e = H.entities[h] return e and e.vel or vector3(0, 0, 0) end
function GetPedInVehicleSeat(veh, seat)
  count('GetPedInVehicleSeat')
  local e = H.entities[veh]
  return e and e.seats and e.seats[seat] or 0
end
function GetIsVehicleEngineRunning(h) local e = H.entities[h] return e and e.engine or false end
function GetVehiclePedIsIn(ped, _)
  local e = H.entities[ped]
  return e and e.vehicle and H.entities[e.vehicle] and e.vehicle or 0
end

function Entity(h)
  local e = H.entities[h] or { state = {} }
  local bag = setmetatable({}, {
    __index = function(_, k)
      if k == 'set' then
        return function(_, key, value, replicated) e.state[key] = value; e.replicated = replicated end
      end
      return e.state[k]
    end,
    __newindex = function() error('state bags are written with :set in this resource') end,
  })
  return { state = bag }
end

-- ===== boot =========================================================================================
local function load(path)
  local chunk, err = loadfile(path)
  if not chunk then error(err) end
  chunk()
end
H.load = load

function H.boot(opts)
  opts = opts or {}
  load('config.lua')
  if opts.config then opts.config(Config) end
  load('bridge/np_admin.lua')
  load('shared/np_admin_settings.lua')
  load('shared/locale.lua')
  load('locales/en.lua')
  load('locales/de.lua')
  load('shared/radarmath.lua')
  load('shared/access.lua')
  load('integrations/registry.lua')
  load('bridge/server.lua')
  load('integrations/server.lua')
  for _, f in ipairs({ 'registry', 'access', 'transponder', 'broadcast', 'exports', 'main', 'np_admin' }) do
    load('server/' .. f .. '.lua')
  end
  H.advance(0)
end

-- ===== assertions ===================================================================================
H.passed, H.failed = 0, 0
function H.ok(cond, name)
  if cond then H.passed = H.passed + 1 else H.failed = H.failed + 1; rawPrint('FAIL: ' .. name) end
end
function H.done(label)
  rawPrint(('%s: %d passed, %d failed'):format(label, H.passed, H.failed))
  os.exit(H.failed == 0 and 0 or 1)
end

return H
