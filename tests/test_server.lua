-- Server smoke test with stubbed natives (tests/harness.lua). Run from repo root: lua tests/test_server.lua
local H = dofile('tests/harness.lua')
local ok = H.ok

-- ===== ESX stub ======================================================================================
local jobs = {}    -- src -> { name, grade }
local groups = {}  -- src -> group
local items = {}   -- src -> count of flight_radar
local usable = {}
local ESX = {
  GetPlayerFromId = function(src)
    if not H.players[src] then return nil end
    return {
      getJob = function() return jobs[src] or { name = 'unemployed', grade = 0 } end,
      getGroup = function() return groups[src] or 'user' end,
      getInventoryItem = function(name) return { name = name, count = items[src] or 0 } end,
    }
  end,
  RegisterUsableItem = function(name, fn) usable[name] = fn end,
}
H.resources.es_extended = 'started'
H.siblings.es_extended = { getSharedObject = function() return ESX end }

-- players: 1 police on the ground, 2 pilot, 3 passenger, 4 civilian, 5 ATC at the tower, 6 copilot
local tower = vector3(-1037.0, -2963.0, 13.9)
H.addPlayer(1, { coords = vector3(0, 0, 0) })
H.addPlayer(2)
H.addPlayer(3)
H.addPlayer(4, { coords = vector3(10, 10, 0) })
H.addPlayer(5, { coords = tower })
H.addPlayer(6)
H.addPlayer(7, { coords = vector3(50, 50, 0) })
jobs[1] = { name = 'police', grade = 0 }
jobs[7] = { name = 'police', grade = 0, onDuty = false } -- off duty (esx_core 1.10+ onDuty)
jobs[5] = { name = 'atc', grade = 0 }

-- one aircraft exists before the resource starts (seeded by GetAllVehicles)
local pre = H.spawnAircraft({ vtype = 'plane', coords = vector3(100, 100, 300), model = 'luxor', plate = ' LUX1 ' })
H.entities[pre].seats[-1] = 999999 -- an NPC pilot
local car = H.spawnAircraft({ vtype = 'automobile', coords = vector3(5, 5, 0) })

H.boot({ config = function(c) c.Framework = 'auto' end })

local R, B, T = NpFR.Registry, NpFR.Broadcast, NpFR.Transponder

-- ===== registry ======================================================================================
ok(R.byEntity[pre] ~= nil, 'start scan registers existing plane')
ok(R.byEntity[car] == nil, 'cars are ignored')
ok(R.byEntity[pre].plate == 'LUX1', 'plate trimmed')
ok(usable.flight_radar ~= nil or true, 'boot ok')
H.advance(1500)
ok(usable.flight_radar ~= nil, 'ESX usable item registered without np_inventory')

local heli = H.spawnAircraft({ vtype = 'heli', coords = vector3(0, 3000, 200), model = 'polmav', vel = vector3(0, -40, 1) })
TriggerEvent('entityCreated', heli)
local heliNet = H.entities[heli].netId
ok(R.byEntity[heli] and R.byNet[heliNet] and R.byEntity[heli].kind == 'heli', 'entityCreated registers heli')
ok(H.countLocal('np_flightradar:aircraftAdded') == 2, 'aircraftAdded fired for both aircraft')

-- pilot (2) in heli, passenger (3) seat 1
H.seat(2, heli, -1)
H.seat(3, heli, 1)

local function contactsFor(src, since)
  local args = H.lastClient('np_flightradar:contacts', src, since)
  if not args then return nil end
  local set = {}
  for _, c in ipairs(args[1].c) do set[c.id] = c end
  return set, args[1]
end

-- ===== idle with no subscribers ======================================================================
do
  local seatCalls = H.calls.GetPedInVehicleSeat or 0
  local mark = #H.clientEvents
  H.advance(5000)
  ok(not B.running and B.count == 0, 'loop not running without subscribers')
  ok(H.countClient('np_flightradar:contacts', nil, mark) == 0, 'no payloads without subscribers')
  ok((H.calls.GetPedInVehicleSeat or 0) == seatCalls, 'no per-aircraft work without subscribers')
end

-- ===== subscribe: validation =========================================================================
do
  local mark = #H.clientEvents
  H.fromClient('np_flightradar:subscribe', 4, 'ground', 1)
  ok(H.lastClient('np_flightradar:denied', 4, mark) ~= nil, 'civilian denied ground')
  ok(B.subs[4] == nil, 'denied player not subscribed')
  H.fromClient('np_flightradar:subscribe', 4, 'hax', 2)
  ok(H.countClient('np_flightradar:denied', 4, mark) == 1 and B.subs[4] == nil, 'unknown mode ignored')
  H.fromClient('np_flightradar:subscribe', 77, 'auto', 1)
  ok(B.subs[77] == nil, 'unknown source ignored')
end

-- rapid re-subscribes are coalesced and still answered (latest wins)
do
  jobs[4] = { name = 'police', grade = 0 }
  NpFR.Access.cache[4] = nil
  H.advance(300)
  local m = #H.clientEvents
  H.fromClient('np_flightradar:subscribe', 4, 'item', 10)
  H.fromClient('np_flightradar:subscribe', 4, 'ground', 11)
  H.fromClient('np_flightradar:subscribe', 4, 'auto', 12)
  local first = H.lastClient('np_flightradar:denied', 4, m)
  ok(first and first[1].reqId == 10, 'first request answered at once')
  ok(H.lastClient('np_flightradar:subscribed', 4, m) == nil, 'burst deferred')
  H.advance(300)
  local last = H.lastClient('np_flightradar:subscribed', 4, m)
  ok(last and last[1].reqId == 12 and H.countClient('np_flightradar:subscribed', 4, m) == 1, 'burst coalesced to the latest request')
  H.fromClient('np_flightradar:unsubscribe', 4)
  H.advance(300)
  ok(B.subs[4] == nil, 'unsubscribe after burst')
  jobs[4] = nil
  NpFR.Access.cache[4] = nil
end

-- ===== police on the ground ==========================================================================
H.fromClient('np_flightradar:subscribe', 1, 'auto', 7)
do
  local args = H.lastClient('np_flightradar:subscribed', 1)
  ok(args and args[1].mode == 'ground' and args[1].range == 12000 and args[1].reqId == 7, 'police gets ground radar')
  ok(B.running, 'loop starts with the first subscriber')
end
local mark = #H.clientEvents
H.advance(1000)
do
  local set, payload = contactsFor(1, mark)
  ok(set and set[heliNet] and set[H.entities[pre].netId], 'both aircraft in range')
  ok(type(payload.t) == 'number', 'payload has server time')
  local c = set[heliNet]
  ok(c.x == 0 and c.y == 3000 and c.z == 200 and c.s == 400 and c.vs == 10, 'packed contact')
  local meta = H.lastClient('np_flightradar:meta', 1, mark)
  ok(meta and meta[1][heliNet] and meta[1][heliNet].callsign == 'AIR-1', 'meta with perModel callsign')
  ok(meta[1][heliNet].squawk == '7000' and meta[1][heliNet].kind == 'heli', 'meta squawk + kind')
  ok(meta[1][H.entities[pre].netId].callsign == 'LUX1', 'plate as last callsign fallback')
end
mark = #H.clientEvents
H.advance(1000)
ok(H.countClient('np_flightradar:contacts', 1, mark) >= 1 and H.countClient('np_flightradar:meta', 1, mark) == 0,
  'meta not re-sent when unchanged')

-- ===== range filter ==================================================================================
H.entities[pre].coords = vector3(20000, 0, 300)
mark = #H.clientEvents
H.advance(1000)
do
  local set = contactsFor(1, mark)
  ok(set[heliNet] and not set[H.entities[pre].netId], 'aircraft outside the range filtered')
end
H.entities[pre].coords = vector3(100, 100, 300)

-- ===== own vehicle + air mode ========================================================================
H.fromClient('np_flightradar:subscribe', 2, 'air', 1)
ok(B.subs[2] and B.subs[2].mode == 'air', 'pilot gets air radar')
mark = #H.clientEvents
H.advance(1000)
do
  local set = contactsFor(2, mark)
  ok(set and not set[heliNet], 'own aircraft excluded')
  ok(set[H.entities[pre].netId] ~= nil, 'other aircraft included for pilot')
end

-- ===== transponder: seat ownership + validation ======================================================
do
  H.fromClient('np_flightradar:setTransponder', 3, { squawk = '1234' })
  ok(H.entities[heli].state.np_fr_xpdr == nil, 'passenger cannot set the transponder')
  ok(H.lastClient('np_flightradar:notify', 3) ~= nil, 'passenger told why')
  H.fromClient('np_flightradar:setTransponder', 4, { squawk = '1234' })
  ok(H.entities[heli].state.np_fr_xpdr == nil, 'player on foot cannot set a transponder')

  H.fromClient('np_flightradar:setTransponder', 2, { squawk = '7800' })
  ok(H.entities[heli].state.np_fr_xpdr == nil, 'invalid squawk rejected')
  H.advance(1100)
  H.fromClient('np_flightradar:setTransponder', 2, { callsign = '<script>' })
  ok(H.entities[heli].state.np_fr_xpdr.callsign == 'SCRIPT', 'callsign sanitised')
  H.fromClient('np_flightradar:setTransponder', 2, { callsign = 'FAST' })
  ok(H.entities[heli].state.np_fr_xpdr.callsign == 'SCRIPT', 'rate limited')
  H.advance(1100)
  H.fromClient('np_flightradar:setTransponder', 2, 'junk')
  H.fromClient('np_flightradar:setTransponder', 2, { on = 'yes' })
  ok(H.entities[heli].state.np_fr_xpdr.on == true, 'wrong types rejected')
  H.advance(1100)

  -- copilot may edit (Config.Transponder.copilotCanEdit)
  H.seat(6, heli, 0)
  H.fromClient('np_flightradar:setTransponder', 6, { callsign = 'n12' })
  ok(H.entities[heli].state.np_fr_xpdr.callsign == 'N12', 'copilot may edit')
  H.advance(1100)

  -- emergency squawk -> local event + police notified
  local before = H.countLocal('np_flightradar:emergency')
  mark = #H.clientEvents
  H.fromClient('np_flightradar:setTransponder', 2, { squawk = 7700 })
  ok(H.entities[heli].state.np_fr_xpdr.squawk == '7700', 'emergency squawk set (integer accepted)')
  ok(H.countLocal('np_flightradar:emergency') == before + 1, 'emergency event fired')
  ok(H.lastClient('np_flightradar:notify', 1, mark) ~= nil, 'police notified of the emergency')
  ok(H.lastClient('np_flightradar:notify', 4, mark) == nil, 'civilian not notified')
  ok(H.lastClient('np_flightradar:notify', 7, mark) == nil, 'off-duty police not notified (requireDuty)')
  mark = #H.clientEvents
  H.advance(1000)
  local meta = H.lastClient('np_flightradar:meta', 1, mark)
  ok(meta and meta[1][heliNet].flags.emergency == '7700' and meta[1][heliNet].callsign == 'N12', 'changed meta re-sent with emergency flag')
  H.advance(1100)

  -- a client that owns the entity writes the bag itself: the server copy wins
  H.entities[heli].state.np_fr_xpdr = { on = true, squawk = '7500', callsign = 'SPOOF' }
  local st = T.get(heli)
  ok(st.squawk == '7700' and st.callsign == 'N12', 'client-written state bag ignored')
  H.entities[heli].state.np_fr_xpdr = { on = true, squawk = '7700', callsign = 'N12' }
  -- bags from a previous run are adopted for aircraft found by the start-up scan
  H.entities[pre].state.np_fr_xpdr = { on = true, squawk = '1200', callsign = 'old 1' }
  T.forget(pre)
  ok(T.get(pre).squawk == '1200' and T.get(pre).callsign == 'OLD-1', 'pre-existing bag adopted after restart')
end

-- ===== transponder off: hidden, primary radar sees "unidentified" ====================================
H.fromClient('np_flightradar:subscribe', 5, 'auto', 1)
ok(B.subs[5] and B.subs[5].mode == 'station' and B.subs[5].primary, 'ATC at the tower gets station + primary')
H.fromClient('np_flightradar:setTransponder', 2, { on = false })
ok(H.entities[heli].state.np_fr_xpdr.on == false, 'transponder off')
-- move the heli near the tower (within PrimaryRadar.range)
H.entities[heli].coords = vector3(-1037, -2000, 200)
mark = #H.clientEvents
H.advance(1000)
do
  local set1 = contactsFor(1, mark)
  ok(set1 and not set1[heliNet], 'transponder-off aircraft hidden from secondary radar')
  local set5 = contactsFor(5, mark)
  ok(set5 and set5[heliNet], 'primary radar still sees it')
  local meta = H.lastClient('np_flightradar:meta', 5, mark)
  local m = meta and meta[1][heliNet]
  ok(m and m.flags.xpdrOff == true and m.callsign == nil and m.squawk == nil, 'sent as unidentified')
end
H.advance(1100)
H.fromClient('np_flightradar:setTransponder', 2, { on = true, squawk = '7000' })

-- ===== no ghosts =====================================================================================
TriggerEvent('entityRemoved', heli)
H.delete(heli)
ok(R.byNet[heliNet] == nil and H.countLocal('np_flightradar:aircraftRemoved') == 1, 'entityRemoved unregisters')
mark = #H.clientEvents
H.advance(1000)
do
  local set = contactsFor(1, mark)
  ok(set and not set[heliNet], 'removed aircraft gone from the next payload')
end
-- vanished without an event
local preNet = H.entities[pre].netId
H.delete(pre)
mark = #H.clientEvents
H.advance(1000)
do
  local set = contactsFor(1, mark)
  ok(set and next(set) == nil, 'vanished aircraft gone without entityRemoved')
  ok(R.byNet[preNet] == nil, 'vanished aircraft dropped from registry')
end

-- ===== access recheck: losing the job drops the subscription =========================================
jobs[1] = { name = 'unemployed', grade = 0 }
TriggerEvent('esx:setJob', 1)
mark = #H.clientEvents
H.advance(500)
ok(B.subs[1] == nil and H.lastClient('np_flightradar:revoked', 1, mark) ~= nil, 'job change revokes ground radar')

-- ===== exports =======================================================================================
do
  local plane = H.spawnAircraft({ vtype = 'plane', coords = vector3(0, 0, 500) })
  TriggerEvent('entityCreated', plane)
  local net = H.entities[plane].netId
  local list = H.exports.GetAircraft()
  ok(#list == 1 and list[1].netId == net and list[1].kind == 'plane', 'GetAircraft')
  ok(H.exports.GetAircraftByNetId(net).squawk == '7000', 'GetAircraftByNetId')
  local st = H.exports.SetTransponder(net, { squawk = '1200', callsign = 'ext 1' })
  ok(st and st.squawk == '1200' and st.callsign == 'EXT-1', 'SetTransponder export')
  ok(H.exports.SetTransponder(123456, { squawk = '1200' }) == nil, 'SetTransponder unknown aircraft')
  ok(H.exports.RegisterAccessCheck(function(src, mode) return mode ~= 'station' end) == true, 'RegisterAccessCheck')
  NpFR.Access.cache[5] = nil
  local m = #H.clientEvents
  B.recheck(5)
  ok(B.subs[5] and B.subs[5].mode == 'ground' and B.subs[5].primary == false, 'veto on recheck: auto falls back to the next mode')
  local upd = H.lastClient('np_flightradar:subscribed', 5, m)
  ok(upd and upd[1].update == true and upd[1].mode == 'ground' and upd[1].range == 12000 and upd[1].reqId == 1,
    'changed grant pushed as an update of the subscription')
  H.fromClient('np_flightradar:subscribe', 5, 'station', 2)
  ok(B.subs[5] == nil, 'explicit station request vetoed')
  ok(B.subs[2] == nil, 'pilot whose aircraft was deleted lost the air grant')
  items[4] = 1
  NpFR.Access.cache[4] = nil
  H.fromClient('np_flightradar:subscribe', 4, 'auto', 5)
  ok(#H.exports.GetSubscribers() == 1 and H.exports.GetSubscribers()[1].source == 4
    and H.exports.GetSubscribers()[1].mode == 'item', 'GetSubscribers')
end

-- ===== positional grant: leaving the aircraft drops 'air' within the positional recheck =============
do
  local plane = H.spawnAircraft({ vtype = 'plane', coords = vector3(0, 0, 500) })
  TriggerEvent('entityCreated', plane)
  H.seat(6, plane, -1)
  H.advance(300)
  H.fromClient('np_flightradar:subscribe', 6, 'air', 3)
  ok(B.subs[6] and B.subs[6].mode == 'air', 'pilot 6 gets air')
  H.seat(6, nil)
  local m = #H.clientEvents
  H.advance(6000)
  ok(B.subs[6] == nil and H.lastClient('np_flightradar:revoked', 6, m) ~= nil, 'air revoked within ~5 s of leaving')
end

-- ===== cleanup =======================================================================================
H.fromClient('playerDropped', 4, 'quit')
ok(B.subs[4] == nil and B.count == 0, 'playerDropped unsubscribes')
H.advance(2000)
ok(not B.running, 'loop stops after the last subscriber left')
mark = #H.clientEvents
H.advance(5000)
ok(H.countClient('np_flightradar:contacts', nil, mark) == 0, 'idle again')

H.done('test_server')
