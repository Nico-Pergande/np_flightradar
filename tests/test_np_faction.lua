-- np_faction (multi-job) integration with stubbed natives. Run from repo root: lua tests/test_np_faction.lua
local H = dofile('tests/harness.lua')
local ok = H.ok

-- ESX: player 1 has the framework job 'mechanic' (np_faction mirrors the active job into the framework)
local ESX = {
  GetPlayerFromId = function(src)
    if not H.players[src] then return nil end
    return {
      getJob = function() return { name = 'mechanic', grade = 0 } end,
      getGroup = function() return 'user' end,
      getInventoryItem = function(name) return { name = name, count = 0 } end,
    }
  end,
  RegisterUsableItem = function() end,
}
H.resources.es_extended = 'started'
H.siblings.es_extended = { getSharedObject = function() return ESX end }

-- np_faction: every job the player holds, active first
local held = {
  [1] = {
    { name = 'mechanic', grade = 0, onduty = true, onDuty = true },
    { name = 'police', grade = 1, onduty = true, onDuty = true },
  },
}
local calls = 0
H.siblings.np_faction = {
  GetJobs = function(src) calls = calls + 1 return held[src] or {} end,
}

H.addPlayer(1, { coords = vector3(0, 0, 0) })
H.boot({ config = function(c) c.Framework = 'auto' end })
local A = NpFR.Access

-- ===== stopped: inert ===============================================================================
ok(NpFR.Server.factionJobs(1) == nil, 'stopped: no faction jobs')
ok(A.resolve(1, 'ground') == nil, 'stopped: framework job (mechanic) has no ground radar')
ok(calls == 0, 'stopped: np_faction never called')

-- ===== started: every held job counts ===============================================================
H.resources.np_faction = 'started'
TriggerEvent('onServerResourceStart', 'np_faction')
H.advance(1000)
ok(#NpFR.Server.factionJobs(1) == 2, 'started: both jobs read')
local r = A.resolve(1, 'ground')
ok(r and r.mode == 'ground', 'started: the second job (police) grants ground radar')
ok(calls > 0, 'started: GetJobs called')

-- ===== duty change: the cache is dropped on np_faction:dutyChanged ==================================
held[1][2].onduty, held[1][2].onDuty = false, false
ok(A.resolve(1, 'ground') ~= nil, 'cached for up to 30 s')
TriggerEvent('np_faction:dutyChanged', 1, 'police', false)
H.advance(500)
ok(A.resolve(1, 'ground') == nil, 'dutyChanged: off duty in the police job, no ground radar')

-- ===== a failing export or the config switch falls back to the framework job ========================
held[1][2].onduty, held[1][2].onDuty = true, true
H.siblings.np_faction.GetJobs = function() error('boom') end
TriggerEvent('np_faction:jobChanged', 1)
H.advance(500)
ok(NpFR.Server.factionJobs(1) == nil and A.resolve(1, 'ground') == nil, 'export error: framework job')
H.siblings.np_faction.GetJobs = function(src) return held[src] or {} end
Config.Integrations.np_faction = false
TriggerEvent('np_faction:jobChanged', 1)
H.advance(500)
ok(A.resolve(1, 'ground') == nil, 'switched off: framework job')
Config.Integrations.np_faction = true
TriggerEvent('np_faction:jobChanged', 1)
H.advance(500)
ok(A.resolve(1, 'ground') ~= nil, 'switched on again')

-- ===== stopped again: access re-checked at once =====================================================
H.resources.np_faction = 'stopped'
TriggerEvent('onServerResourceStop', 'np_faction')
H.advance(500)
ok(A.resolve(1, 'ground') == nil, 'stopped again: framework job')

H.done('test_np_faction')
