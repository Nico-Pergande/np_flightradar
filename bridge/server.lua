-- Server framework bridge (esx > qbx > qb > standalone). Every framework call is pcall'd: a framework
-- that is restarting or different from what we expect degrades to "no job", never to an error inside a
-- net event. No ACE anywhere: permissions are np_admin nodes (NpAdmin.can, see Bridge.can below).
Bridge = {}

local fw = nil
local ESX, QBCore = nil, nil
local changeHandlers = {}

local function started(res) return GetResourceState(res) == 'started' end

local function detect()
  local want = Config.Framework or 'auto'
  if want ~= 'auto' then return want end
  if started('es_extended') then return 'esx' end
  if started('qbx_core') then return 'qbx' end
  if started('qb-core') then return 'qb' end
  return 'standalone'
end

function Bridge.framework()
  if not fw then
    fw = detect()
    print(('[np_flightradar] framework: %s'):format(fw))
  end
  return fw
end

AddEventHandler('onServerResourceStart', function(res)
  if res == 'es_extended' or res == 'qbx_core' or res == 'qb-core' then fw, ESX, QBCore = nil, nil, nil end
end)

function Bridge.esx()
  if not ESX then
    local ok, obj = pcall(function() return exports.es_extended:getSharedObject() end)
    if ok then ESX = obj end
  end
  return ESX
end

local function qbCore()
  if not QBCore then
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok then QBCore = obj end
  end
  return QBCore
end

local function qbPlayer(src)
  local kind = Bridge.framework()
  local ok, p = pcall(function()
    if kind == 'qbx' then return exports.qbx_core:GetPlayer(src) end
    local core = qbCore()
    return core and core.Functions.GetPlayer(src)
  end)
  return ok and p or nil
end

local function esxPlayer(src)
  local ok, xp = pcall(function()
    local core = Bridge.esx()
    return core and core.GetPlayerFromId(src)
  end)
  return ok and xp or nil
end
Bridge.esxPlayer = esxPlayer

function Bridge.validSrc(src)
  return math.type(src) == 'integer' and src > 0 and GetPlayerName(src) ~= nil
end

-- -> { job, grade, onduty, group, callsign } (empty table when not loaded / standalone)
function Bridge.playerInfo(src)
  local kind = Bridge.framework()
  if kind == 'esx' then
    local xp = esxPlayer(src)
    if not xp then return {} end
    local ok, job = pcall(function() return xp.getJob and xp.getJob() or xp.job end)
    local okG, group = pcall(function() return xp.getGroup and xp.getGroup() or xp.group end)
    job = ok and type(job) == 'table' and job or {}
    -- ESX has no duty concept unless the job carries `onDuty` (esx_core 1.10+): default on duty
    local duty = job.onDuty
    if duty == nil then duty = job.onduty end
    return {
      job = job.name, grade = tonumber(job.grade) or 0, onduty = duty ~= false,
      group = okG and group or nil,
    }
  elseif kind == 'qbx' or kind == 'qb' then
    local p = qbPlayer(src)
    local pd = p and p.PlayerData
    if type(pd) ~= 'table' then return {} end
    local job = type(pd.job) == 'table' and pd.job or {}
    local grade = type(job.grade) == 'table' and job.grade.level or job.grade
    local meta = type(pd.metadata) == 'table' and pd.metadata or {}
    local cs = meta.callsign
    if cs == 'NO CALLSIGN' then cs = nil end
    return { job = job.name, grade = tonumber(grade) or 0, onduty = job.onduty == true, callsign = cs }
  end
  return {}
end

function Bridge.identifiers(src)
  local out = {}
  for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do out[id] = true end
  return out
end

-- Permission nodes (managed in np_admin):
--   np_flightradar.admin   admin radar (everything, unlimited range, primary radar)
--   np_flightradar.ground  ground radar without an allowed job (staff, standalone servers)
Bridge.NODES = { admin = 'np_flightradar.admin', ground = 'np_flightradar.ground' }

-- Config.Admin (identifiers / ESX groups): kept as an extra fallback for servers without np_admin
local function configAdmin(src)
  local ids = Bridge.identifiers(src)
  for _, id in ipairs((Config.Admin and Config.Admin.identifiers) or {}) do
    if ids[id] then return true end
  end
  local group = Bridge.playerInfo(src).group
  if type(group) == 'string' then
    for _, g in ipairs((Config.Admin and Config.Admin.groups) or {}) do
      if g == group then return true end
    end
  end
  return false
end
Bridge.configAdmin = configAdmin

-- Without np_admin: the lib's fallback (console, convar np_admin_fallback, ESX groups in
-- np_admin_fallback_groups) or Config.Admin. With np_admin running, np_admin alone decides.
NpAdmin.fallback = function(src, node)
  if NpAdmin.defaultFallback(src, node) then return true end
  return configAdmin(src)
end

function Bridge.can(src, node)
  return NpAdmin.can(src, node) == true
end

function Bridge.isAdmin(src)
  return Bridge.can(src, Bridge.NODES.admin)
end

-- Framework item count (np_inventory is asked first by integrations/server.lua)
function Bridge.itemCount(src, name)
  local kind = Bridge.framework()
  if kind == 'esx' then
    local xp = esxPlayer(src)
    local ok, item = pcall(function() return xp and xp.getInventoryItem(name) end)
    return ok and type(item) == 'table' and (tonumber(item.count) or 0) or 0
  elseif kind == 'qb' or kind == 'qbx' then
    if started('ox_inventory') then
      local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', name) end)
      if ok then return tonumber(n) or 0 end
    end
    local p = qbPlayer(src)
    local ok, item = pcall(function() return p and p.Functions.GetItemByName(name) end)
    return ok and type(item) == 'table' and (tonumber(item.amount or item.count) or 0) or 0
  end
  return 0
end

-- Usable-item fallback when np_inventory is absent. fn(src)
function Bridge.registerUsable(name, fn)
  local kind = Bridge.framework()
  if kind == 'esx' then
    local core = Bridge.esx()
    if core and core.RegisterUsableItem then
      return pcall(core.RegisterUsableItem, name, function(src) fn(src) end)
    end
  elseif kind == 'qb' then
    local core = qbCore()
    if core and core.Functions and core.Functions.CreateUseableItem then
      return pcall(core.Functions.CreateUseableItem, name, function(src) fn(src) end)
    end
  elseif kind == 'qbx' then
    return pcall(function() exports.qbx_core:CreateUseableItem(name, function(src) fn(src) end) end)
  end
  return false
end

function Bridge.players()
  local out = {}
  for _, p in ipairs(GetPlayers()) do
    local id = math.tointeger(tonumber(p))
    if id then out[#out + 1] = id end
  end
  return out
end

-- Rate limiter: true when `src` may do `key` now (at most once per `ms`)
local last = {}
function Bridge.throttle(src, key, ms)
  local now = GetGameTimer()
  local bucket = last[src]
  if not bucket then bucket = {}; last[src] = bucket end
  local t = bucket[key]
  if t and now - t < ms then return false end
  bucket[key] = now
  return true
end

-- Job / duty / load changes: handlers get (src)
function Bridge.onPlayerChanged(fn) changeHandlers[#changeHandlers + 1] = fn end

local function changed(src)
  src = math.tointeger(tonumber(src or ''))
  if not src then return end
  -- frameworks fire these around the PlayerData write, not always after it
  SetTimeout(250, function()
    for _, fn in ipairs(changeHandlers) do pcall(fn, src) end
  end)
end

AddEventHandler('esx:setJob', function(src) changed(src) end)
AddEventHandler('esx:playerLoaded', function(src) changed(src) end)
AddEventHandler('QBCore:Server:OnJobUpdate', function(src) changed(src) end)
AddEventHandler('QBCore:Server:SetDuty', function(src) changed(src) end)
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
  local src = type(player) == 'table' and player.PlayerData and player.PlayerData.source
  if src then changed(src) end
end)

AddEventHandler('playerDropped', function() last[source] = nil end)
