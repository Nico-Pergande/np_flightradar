-- Pure access resolver: player facts + config -> { mode, range, primary } | nil. No natives; the server
-- gathers the facts (server/access.lua) and the client never decides. Unit tested (tests/test_access.lua).
--
-- info = {
--   inAircraft = bool,         any seat of a heli/plane (server view)
--   job = 'police', grade = 0, onduty = bool,
--   jobs = { { job, grade, onduty }, ... } | nil   every job the player holds (multi-job resources such as
--                              np_faction); when present, a rule is met by ANY of them, duty checked per job
--   hasItem = bool,            holds Config.Access.item
--   station = <Config.Stations entry> | nil   (the station the player stands at)
--   isAdmin = bool,            np_admin node np_flightradar.admin
--   groundGrant = bool,        np_admin node np_flightradar.ground (ground radar without a job)
--   discordOk = bool,
--   licensed = true | false | nil (nil = unknown / np_identification absent)
-- }
-- veto = function(mode) -> bool|nil  (false denies; Config.CanUse + RegisterAccessCheck)
Access = {}

Access.MODES = { 'admin', 'station', 'ground', 'air', 'item', 'phone' }
-- `best` order when the client opens the panel without asking for a mode (phone is explicit only)
Access.BEST = { 'admin', 'station', 'ground', 'air', 'item' }

local VALID = {}
for _, m in ipairs(Access.MODES) do VALID[m] = true end
Access.VALID = VALID

local function range(cfg, mode)
  local r = cfg.Ranges and cfg.Ranges[mode]
  if type(r) ~= 'number' or r < 0 then return 0 end
  return r
end

-- jobs = { job = minGrade } (or a list { 'job', ... } = grade 0)
local function oneJobAllowed(jobs, info, requireDuty)
  if type(info) ~= 'table' or type(info.job) ~= 'string' then return false end
  local min = jobs[info.job]
  if min == nil then
    for _, j in ipairs(jobs) do
      if j == info.job then min = 0 break end
    end
  end
  if min == nil or min == false then return false end
  if min == true then min = 0 end
  if (tonumber(info.grade) or 0) < (tonumber(min) or 0) then return false end
  if requireDuty and info.onduty == false then return false end
  return true
end

-- info.jobs (multi-job) when present, otherwise the single info.job
local function anyJob(info, test)
  if type(info.jobs) == 'table' then
    for _, j in ipairs(info.jobs) do
      if test(j) then return true end
    end
    return false
  end
  return test(info)
end

function Access.jobAllowed(jobs, info, requireDuty)
  if type(jobs) ~= 'table' then return false end
  return anyJob(info, function(j) return oneJobAllowed(jobs, j, requireDuty) end)
end

local function onePhoneJobOk(job, info)
  if type(info) ~= 'table' then return false end
  if type(job) == 'string' then return info.job == job end
  if type(job) == 'table' then
    for _, j in ipairs(job) do if j == info.job then return true end end
    return job[info.job] ~= nil and job[info.job] ~= false
  end
  return false
end

local function phoneJobOk(job, info)
  if job == nil then return true end
  return anyJob(info, function(j) return onePhoneJobOk(job, j) end)
end

-- Is `mode` granted on its own merits (ignores admin + veto)?
function Access.allows(mode, info, cfg)
  local a = cfg.Access or {}
  local duty = a.requireDuty ~= false
  if mode == 'air' then
    if a.inAircraft == false or not info.inAircraft then return false end
    local id = cfg.Identification or {}
    if id.requireLicenseForAirRadar and info.licensed == false then return false end
    return true
  elseif mode == 'ground' then
    return Access.jobAllowed(a.jobs, info, duty) or info.discordOk == true or info.groundGrant == true
  elseif mode == 'item' then
    return a.item ~= nil and a.item ~= false and info.hasItem == true
  elseif mode == 'station' then
    local st = info.station
    if type(st) ~= 'table' then return false end
    if st.jobs == nil then
      return Access.jobAllowed(a.jobs, info, duty) or info.discordOk == true or info.groundGrant == true
    end
    return Access.jobAllowed(st.jobs, info, duty)
  elseif mode == 'phone' then
    local p = cfg.Phone or {}
    return p.enabled ~= false and phoneJobOk(p.job, info)
  elseif mode == 'admin' then
    return info.isAdmin == true
  end
  return false
end

-- Resolve one requested mode -> { mode, range, primary } | nil
function Access.resolve(info, cfg, mode, veto)
  if type(info) ~= 'table' or type(cfg) ~= 'table' or not VALID[mode] then return nil end
  local admin = info.isAdmin == true
  if not admin and not Access.allows(mode, info, cfg) then return nil end
  if mode == 'station' and admin and type(info.station) ~= 'table' then return nil end
  if veto and veto(mode) == false then return nil end
  local primaryOn = not cfg.PrimaryRadar or cfg.PrimaryRadar.enabled ~= false
  return {
    mode = mode,
    range = range(cfg, mode),
    primary = primaryOn and (admin or mode == 'station') or false,
  }
end

-- Best mode for a panel opened without a preference
function Access.best(info, cfg, veto)
  for _, mode in ipairs(Access.BEST) do
    local r = Access.resolve(info, cfg, mode, veto)
    if r then return r end
  end
  return nil
end

-- { [mode] = true } for everything the player may open (client hints: radial, /radar)
function Access.modes(info, cfg, veto)
  local out = {}
  for _, mode in ipairs(Access.MODES) do
    if Access.resolve(info, cfg, mode, veto) then out[mode] = true end
  end
  return out
end

return Access
