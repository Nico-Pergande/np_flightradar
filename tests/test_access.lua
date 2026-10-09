-- Run from repo root: lua tests/test_access.lua
function vec3(x, y, z) return { x = x, y = y, z = z } end
dofile('config.lua')
dofile('shared/access.lua')

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; print('FAIL: ' .. name) end
end

local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
local base = copy(Config)
local function cfg(mut) local c = copy(base) if mut then mut(c) end return c end

local C = cfg()
local tower = C.Stations[1]

-- ===== air ===========================================================================================
do
  local r = Access.resolve({ inAircraft = true }, C, 'air')
  ok(r and r.mode == 'air' and r.range == 6000 and r.primary == false, 'air in aircraft')
  ok(Access.resolve({ inAircraft = false }, C, 'air') == nil, 'air denied on foot')
  ok(Access.resolve({ inAircraft = true }, cfg(function(c) c.Access.inAircraft = false end), 'air') == nil, 'air switched off')
  local lic = cfg(function(c) c.Identification.requireLicenseForAirRadar = true end)
  ok(Access.resolve({ inAircraft = true, licensed = false }, lic, 'air') == nil, 'air needs licence')
  ok(Access.resolve({ inAircraft = true, licensed = true }, lic, 'air') ~= nil, 'air with licence')
  ok(Access.resolve({ inAircraft = true, licensed = nil }, lic, 'air') ~= nil, 'air licence unknown = allowed')
  ok(Access.resolve({ inAircraft = true, licensed = false }, C, 'air') ~= nil, 'licence not required by default')
end

-- ===== ground: jobs, duty, grade =====================================================================
do
  local r = Access.resolve({ job = 'police', grade = 0, onduty = true }, C, 'ground')
  ok(r and r.mode == 'ground' and r.range == 12000 and not r.primary, 'police ground')
  ok(Access.resolve({ job = 'police', grade = 0, onduty = false }, C, 'ground') == nil, 'off duty denied')
  ok(Access.resolve({ job = 'police', grade = 0, onduty = false }, cfg(function(c) c.Access.requireDuty = false end), 'ground') ~= nil,
    'duty not required')
  ok(Access.resolve({ job = 'mechanic', grade = 4, onduty = true }, C, 'ground') == nil, 'other job denied')
  local graded = cfg(function(c) c.Access.jobs = { police = 3 } end)
  ok(Access.resolve({ job = 'police', grade = 2, onduty = true }, graded, 'ground') == nil, 'grade too low')
  ok(Access.resolve({ job = 'police', grade = 3, onduty = true }, graded, 'ground') ~= nil, 'grade reached')
  ok(Access.resolve({ job = 'police', grade = '5', onduty = true }, graded, 'ground') ~= nil, 'string grade coerced')
  local list = cfg(function(c) c.Access.jobs = { 'atc' } end)
  ok(Access.resolve({ job = 'atc', grade = 0, onduty = true }, list, 'ground') ~= nil, 'job list form')
  ok(Access.resolve({ job = 'civ', discordOk = true }, C, 'ground') ~= nil, 'discord role grants ground')
  ok(Access.resolve({}, C, 'ground') == nil, 'no job denied')
end

-- ===== item ==========================================================================================
do
  local r = Access.resolve({ hasItem = true }, C, 'item')
  ok(r and r.range == 4000, 'item holder')
  ok(Access.resolve({ hasItem = false }, C, 'item') == nil, 'no item')
  ok(Access.resolve({ hasItem = true }, cfg(function(c) c.Access.item = false end), 'item') == nil, 'item disabled')
end

-- ===== station =======================================================================================
do
  local r = Access.resolve({ job = 'atc', grade = 0, onduty = true, station = tower }, C, 'station')
  ok(r and r.mode == 'station' and r.range == 0 and r.primary == true, 'atc at tower: unlimited + primary')
  ok(Access.resolve({ job = 'atc', grade = 0, onduty = true }, C, 'station') == nil, 'not at a station')
  ok(Access.resolve({ job = 'ambulance', grade = 0, onduty = true, station = tower }, C, 'station') == nil, 'job not allowed at tower')
  ok(Access.resolve({ job = 'atc', onduty = false, station = tower }, C, 'station') == nil, 'station needs duty')
  local open = { label = 'x', jobs = nil }
  ok(Access.resolve({ job = 'police', onduty = true, station = open }, C, 'station') ~= nil, 'station without jobs uses ground list')
  ok(Access.resolve({ job = 'civ', onduty = true, station = open }, C, 'station') == nil, 'station without jobs denies civilians')
  local noPrimary = cfg(function(c) c.PrimaryRadar.enabled = false end)
  ok(Access.resolve({ job = 'atc', onduty = true, station = tower }, noPrimary, 'station').primary == false, 'primary radar off')
end

-- ===== phone =========================================================================================
do
  ok(Access.resolve({}, C, 'phone').range == 8000, 'phone for everyone')
  ok(Access.resolve({}, cfg(function(c) c.Phone.enabled = false end), 'phone') == nil, 'phone disabled')
  local job = cfg(function(c) c.Phone.job = 'atc' end)
  ok(Access.resolve({ job = 'atc' }, job, 'phone') ~= nil and Access.resolve({ job = 'civ' }, job, 'phone') == nil, 'phone job string')
  local jobs = cfg(function(c) c.Phone.job = { 'atc', 'police' } end)
  ok(Access.resolve({ job = 'police' }, jobs, 'phone') ~= nil and Access.resolve({ job = 'civ' }, jobs, 'phone') == nil, 'phone job list')
end

-- ===== admin =========================================================================================
do
  local r = Access.resolve({ isAdmin = true }, C, 'admin')
  ok(r and r.mode == 'admin' and r.range == 0 and r.primary, 'admin mode')
  ok(Access.resolve({ isAdmin = false }, C, 'admin') == nil, 'non-admin admin mode')
  r = Access.resolve({ isAdmin = true }, C, 'ground')
  ok(r and r.mode == 'ground' and r.primary, 'admin gets any mode with primary')
  ok(Access.resolve({ isAdmin = true }, C, 'station') == nil, 'admin station mode still needs a station')
  ok(Access.best({ isAdmin = true, job = 'police', onduty = true }, C).mode == 'admin', 'admin is best')
end

-- ===== np_admin node np_flightradar.ground ===========================================================
do
  local r = Access.resolve({ groundGrant = true }, C, 'ground')
  ok(r and r.mode == 'ground' and r.range == 12000 and not r.primary, 'ground node grants the ground radar')
  ok(Access.best({ groundGrant = true }, C).mode == 'ground', 'ground node: best = ground')
  ok(Access.resolve({ groundGrant = true }, C, 'admin') == nil, 'ground node is not admin')
  local open = { label = 'Open', coords = { x = 0, y = 0, z = 0 }, radius = 10 }
  ok(Access.resolve({ groundGrant = true, station = open }, C, 'station') ~= nil, 'ground node: station without own jobs')
  ok(Access.resolve({ groundGrant = true, station = tower }, C, 'station') == nil, 'ground node: station with own jobs still needs one')
end

-- ===== best / modes / veto / junk ====================================================================
do
  ok(Access.best({ inAircraft = true }, C).mode == 'air', 'best: air')
  ok(Access.best({ inAircraft = true, job = 'police', onduty = true }, C).mode == 'ground', 'best: ground over air')
  ok(Access.best({ job = 'atc', onduty = true, station = tower }, C).mode == 'station', 'best: station over ground')
  ok(Access.best({ hasItem = true }, C).mode == 'item', 'best: item')
  ok(Access.best({}, C) == nil, 'best: nothing (phone is never best)')
  local m = Access.modes({ inAircraft = true, hasItem = true }, C)
  ok(m.air and m.item and m.phone and not m.ground and not m.admin, 'modes summary')

  local vetoAir = function(mode) return mode ~= 'air' end
  ok(Access.resolve({ inAircraft = true }, C, 'air', vetoAir) == nil, 'veto denies')
  ok(Access.resolve({ hasItem = true }, C, 'item', vetoAir) ~= nil, 'veto passes other modes')
  ok(Access.best({ inAircraft = true, hasItem = true }, C, vetoAir).mode == 'item', 'best skips vetoed')
  ok(Access.resolve({ isAdmin = true }, C, 'admin', function() return false end) == nil, 'veto applies to admins')
  ok(Access.resolve({ isAdmin = true }, C, 'admin', function() return nil end) ~= nil, 'nil from veto = no opinion')

  ok(Access.resolve({ inAircraft = true }, C, 'hax') == nil, 'unknown mode')
  ok(Access.resolve(nil, C, 'air') == nil and Access.resolve({}, nil, 'air') == nil, 'junk input')
  local neg = cfg(function(c) c.Ranges.air = -5 end)
  ok(Access.resolve({ inAircraft = true }, neg, 'air').range == 0, 'negative range -> 0')
end

-- ===== multi-job facts (info.jobs, e.g. np_faction): any held job counts, duty per job =================
do
  local two = { job = 'mechanic', grade = 0, onduty = true, jobs = {
    { job = 'mechanic', grade = 0, onduty = true },
    { job = 'police', grade = 2, onduty = true },
  } }
  ok(Access.resolve(two, C, 'ground') ~= nil, 'multi-job: second job grants ground')
  local offDuty = { job = 'mechanic', jobs = { { job = 'mechanic', grade = 0, onduty = true }, { job = 'police', grade = 2, onduty = false } } }
  ok(Access.resolve(offDuty, C, 'ground') == nil, 'multi-job: duty checked per job')
  ok(Access.resolve(offDuty, cfg(function(c) c.Access.requireDuty = false end), 'ground') ~= nil, 'multi-job: duty not required')
  local graded = cfg(function(c) c.Access.jobs = { police = 3 } end)
  ok(Access.resolve(two, graded, 'ground') == nil, 'multi-job: grade per job')
  ok(Access.resolve({ job = 'police', grade = 0, onduty = true, jobs = {} }, C, 'ground') == nil, 'multi-job: an empty list overrides the single job')
  local atTower = { station = tower, job = 'mechanic', jobs = { { job = 'mechanic', grade = 0, onduty = true }, { job = 'atc', grade = 0, onduty = true } } }
  ok(Access.resolve(atTower, C, 'station') ~= nil, 'multi-job: station rule')
  local phoneAtc = cfg(function(c) c.Phone.job = 'atc' end)
  ok(Access.resolve(atTower, phoneAtc, 'phone') ~= nil, 'multi-job: phone job rule')
  ok(Access.resolve(two, phoneAtc, 'phone') == nil, 'multi-job: phone job rule not held')
end

print(('test_access: %d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
