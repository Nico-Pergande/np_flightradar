-- np_admin integration lib (canonical copy: np_admin/lib/np_admin.lua, LIB_VERSION below).
--
-- Vendor this file into your resource (e.g. bridge/np_admin.lua) and load it as a shared_script AFTER
-- your config. It never hard-depends on np_admin: when np_admin is not running every call falls back
-- to safe defaults (no ACE is used anywhere).
--
--   npAdmin.can(src, 'np_inventory.give')             server: may this player do it?   client: npAdmin.can('node')
--   npAdmin.limit(src, 'ban.max_duration')            server: numeric/string limit of the player's groups
--   npAdmin.isStaff(src)                              server/client
--   npAdmin.permissions({ { node=, label=, category=, description= }, ... })   register your nodes (server)
--   npAdmin.settings({ label=, icon=, tint=, target=Config, categories={}, fields={...} })   (server + client)
--   npAdmin.onChange(key | '*', function(value, old, key) end)                  (server + client)
--   npAdmin.log(category, { action=, message=, actor=src, target=src, data={} })  (server)
--   npAdmin.action({ name=, label=, icon=, perm=, target='player'|'none', args={...}, handler=fn(src, target, args) })  (server)
--   npAdmin.notifyStaff({ title=, message=, icon=, tint= })                       (server)
--   npAdmin.fallback = function(src, node) return bool end   -- override the no-np_admin behaviour
--
-- Fallback without np_admin (server): console (src 0) is allowed; identifiers listed in the convar
-- `np_admin_fallback` ("license:abc,discord:123") are allowed; on es_extended the groups in
-- `np_admin_fallback_groups` (default "admin,superadmin") are allowed. Everyone else is refused.
npAdmin = npAdmin or {}
local NA = npAdmin
NA.LIB_VERSION = 1

local RES = GetCurrentResourceName()
local IS_SERVER = IsDuplicityVersion()
local ADMIN = 'np_admin'

local function running()
  return GetResourceState(ADMIN) == 'started'
end
NA.running = running

local function call(name, ...)
  if not running() then return nil end
  local ok, res, res2 = pcall(function(...) return exports[ADMIN][name](exports[ADMIN], ...) end, ...)
  if not ok then return nil end
  return res, res2
end

-- ---------------------------------------------------------------------------------------------
-- dotted key helpers (shared with the settings writer)
-- ---------------------------------------------------------------------------------------------
-- A path segment of plain digits addresses an array slot ('Items.1.price' -> Items[1].price) unless the
-- table has that string key; '0x10' / '1e2' stay string keys.
local function slot(tbl, part)
  if part:match('^%d+$') then
    local n = tonumber(part)   -- digits only, so an integer on 5.3+ (and lint-safe on lua51 std)
    if n and (tbl[n] ~= nil or tbl[part] == nil) then return n end
  end
  return part
end

local function getPath(tbl, key)
  local cur = tbl
  for part in tostring(key):gmatch('[^%.]+') do
    if type(cur) ~= 'table' then return nil end
    cur = cur[slot(cur, part)]
  end
  return cur
end

local function setPath(tbl, key, value)
  local parts = {}
  for part in tostring(key):gmatch('[^%.]+') do parts[#parts + 1] = part end
  if #parts == 0 or type(tbl) ~= 'table' then return end
  local cur = tbl
  for i = 1, #parts - 1 do
    local p = slot(cur, parts[i])
    if type(cur[p]) ~= 'table' then cur[p] = {} end
    cur = cur[p]
  end
  cur[slot(cur, parts[#parts])] = value
end
NA.getPath, NA.setPath = getPath, setPath

local function deepcopy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepcopy(x) end
  return out
end

-- ---------------------------------------------------------------------------------------------
-- change listeners
-- ---------------------------------------------------------------------------------------------
local listeners = {}   -- key|'*' -> { fn }

function NA.onChange(key, fn)
  if type(fn) ~= 'function' then return end
  key = key or '*'
  listeners[key] = listeners[key] or {}
  local list = listeners[key]
  list[#list + 1] = fn
end

local function emit(key, value, old)
  for _, k in ipairs({ key, '*' }) do
    local list = listeners[k]
    if list then
      for i = 1, #list do
        local ok, err = pcall(list[i], value, old, key)
        if not ok then print(('^3[%s] np_admin onChange(%s) error: %s^7'):format(RES, key, tostring(err))) end
      end
    end
  end
end

-- the settings definition registered by this resource (kept to re-register after an np_admin restart)
local settingsDef
local permissionList
local actionDefs = {}

-- Applies { key = value } onto def.target and fires listeners for changed keys.
local function applyValues(values, fire)
  if not settingsDef or type(values) ~= 'table' then return end
  local target = settingsDef.target
  local known = settingsDef.__keys
  for key, value in pairs(values) do
    if known[key] then
      local old = getPath(target, key)
      -- np_admin sends { __null = true } for "back to a nil default" (nil can't travel inside a table)
      if value == NA.NULL or value == nil or (type(value) == 'table' and value.__null == true) then
        value = deepcopy(settingsDef.__defaults[key])
      end
      setPath(target, key, value)
      if fire then emit(key, value, old) end
    end
  end
end

NA.NULL = setmetatable({}, { __tostring = function() return 'npAdmin.NULL' end })

-- Normalises a settings definition and remembers the defaults (read from target at register time).
local function prepare(def)
  assert(type(def) == 'table', 'npAdmin.settings: definition table expected')
  def.target = def.target or Config
  assert(type(def.target) == 'table', 'npAdmin.settings: target table missing (pass target = Config)')
  def.fields = def.fields or def.settings or {}
  def.__keys, def.__defaults = {}, {}
  for i = 1, #def.fields do
    local f = def.fields[i]
    if type(f) == 'table' and type(f.key) == 'string' then
      def.__keys[f.key] = f
      local cur = getPath(def.target, f.key)
      def.__defaults[f.key] = deepcopy(cur)
    end
  end
  return def
end

-- Schema as sent to np_admin: plain data only (defaults included, target/functions stripped).
local function schemaOf(def)
  local fields = {}
  for i = 1, #def.fields do
    local f = def.fields[i]
    if type(f) == 'table' and type(f.key) == 'string' then
      local c = {}
      for k, v in pairs(f) do
        if type(v) ~= 'function' then c[k] = deepcopy(v) end
      end
      c.default = deepcopy(def.__defaults[f.key])
      fields[#fields + 1] = c
    end
  end
  return {
    label = def.label or RES, icon = def.icon, tint = def.tint, version = def.version or GetResourceMetadata(RES, 'version', 0),
    description = def.description, categories = def.categories, fields = fields,
  }
end

if IS_SERVER then
  -- -------------------------------------------------------------------------------------------
  -- server: permissions
  -- -------------------------------------------------------------------------------------------
  local fallbackIds, fallbackGroups

  local function readFallback()
    fallbackIds, fallbackGroups = {}, {}
    for id in (GetConvar('np_admin_fallback', '') or ''):gmatch('[^,%s]+') do fallbackIds[id] = true end
    for g in (GetConvar('np_admin_fallback_groups', 'admin,superadmin') or ''):gmatch('[^,%s]+') do fallbackGroups[g] = true end
  end

  local function esxGroup(src)
    if GetResourceState('es_extended') ~= 'started' then return nil end
    local ok, group = pcall(function()
      local ESX = exports['es_extended']:getSharedObject()
      local xPlayer = ESX and ESX.GetPlayerFromId(src)
      return xPlayer and xPlayer.getGroup and xPlayer.getGroup() or nil
    end)
    return ok and group or nil
  end

  function NA.defaultFallback(src)
    if src == 0 then return true end
    if not fallbackIds then readFallback() end
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
      if fallbackIds[id] then return true end
    end
    local group = esxGroup(src)
    if group and fallbackGroups[group] then return true end
    return false
  end

  function NA.can(src, node)
    src = tonumber(src)
    if src == nil then return false end
    if src == 0 then return true end
    -- np_admin running = np_admin decides; a failed export call denies instead of dropping to the
    -- (ESX group / convar) fallback, which would bypass np_admin's denies
    if running() then return call('can', src, node) == true end
    local fb = NA.fallback or NA.defaultFallback
    local ok, res = pcall(fb, src, node)
    return ok and res == true
  end

  function NA.limit(src, key)
    if running() then return call('limit', tonumber(src), key) end
    return nil
  end

  function NA.isStaff(src)
    if tonumber(src) == 0 then return true end
    if running() then return call('isStaff', tonumber(src)) == true end
    return NA.can(src, RES .. '.admin')
  end

  function NA.getGroups(src)
    return (running() and call('getGroups', tonumber(src))) or {}
  end

  function NA.permissions(list)
    permissionList = list
    if running() then call('registerPermissions', RES, list) end
  end

  -- -------------------------------------------------------------------------------------------
  -- server: settings
  -- -------------------------------------------------------------------------------------------
  function NA.settings(def)
    settingsDef = prepare(def)
    if running() then
      local overrides = call('registerSettings', RES, schemaOf(settingsDef))
      applyValues(overrides, false)
    end
    return settingsDef.target
  end

  function NA.get(key)
    if not settingsDef then return nil end
    return getPath(settingsDef.target, key)
  end

  -- np_admin pushes saved changes here (only to the owning resource).
  AddEventHandler('np_admin:settingsChanged', function(resource, changes)
    if resource ~= RES then return end
    -- only np_admin (a server-side TriggerEvent) may push values; refuse anything that came from a client
    -- (should any resource ever RegisterNetEvent this name) or from another resource
    local from = tonumber(source)
    if from and from > 0 then return end
    local inv = GetInvokingResource()
    if inv and inv ~= ADMIN and inv ~= RES then return end
    applyValues(changes, true)
  end)

  -- -------------------------------------------------------------------------------------------
  -- server: logs, actions, staff notifications
  -- -------------------------------------------------------------------------------------------
  function NA.log(category, entry)
    if type(entry) ~= 'table' then entry = { message = tostring(entry) } end
    entry.resource = entry.resource or RES
    if running() then
      call('log', category, entry)
      return true
    end
    return false   -- caller keeps its own webhook as fallback
  end

  function NA.action(def)
    if type(def) ~= 'table' or type(def.name) ~= 'string' or type(def.handler) ~= 'function' then return false end
    def.resource = RES
    actionDefs[def.name] = def
    if running() then call('registerAction', def) end
    return true
  end

  function NA.notifyStaff(data)
    if running() then call('notifyStaff', data) end
  end

  -- np_admin (re)started: register everything again.
  AddEventHandler('np_admin:ready', function()
    if permissionList then call('registerPermissions', RES, permissionList) end
    if settingsDef then
      local overrides = call('registerSettings', RES, schemaOf(settingsDef))
      applyValues(overrides, true)
    end
    for _, def in pairs(actionDefs) do call('registerAction', def) end
  end)
else
  -- -------------------------------------------------------------------------------------------
  -- client
  -- -------------------------------------------------------------------------------------------

  function NA.can(node)
    if running() then
      local res = call('can', node)
      if res ~= nil then return res == true end
    end
    return false
  end

  function NA.isStaff()
    return running() and call('isStaff') == true or false
  end

  function NA.openPanel(view) return call('openPanel', view) end
  function NA.openMenu() return call('openMenu') end

  -- shared settings arrive through GlobalState['npcfg:<resource>']
  local bagKey = 'npcfg:' .. RES

  function NA.settings(def)
    settingsDef = prepare(def)
    local values = GlobalState[bagKey]
    if type(values) == 'table' then applyValues(values, false) end
    return settingsDef.target
  end

  function NA.get(key)
    if not settingsDef then return nil end
    return getPath(settingsDef.target, key)
  end

  AddStateBagChangeHandler(bagKey, 'global', function(_, _, value)
    if not settingsDef then return end
    -- keys that disappeared were reset: restore defaults
    local values = type(value) == 'table' and value or {}
    local merged = {}
    for key in pairs(settingsDef.__keys) do
      if values[key] ~= nil then merged[key] = values[key] else merged[key] = NA.NULL end
    end
    -- fire only for real changes
    local changed = {}
    for key, v in pairs(merged) do
      local cur = getPath(settingsDef.target, key)
      local want
      if v == NA.NULL then want = settingsDef.__defaults[key] else want = v end
      if json.encode(cur) ~= json.encode(want) then changed[key] = v end
    end
    applyValues(changed, true)
  end)

  -- no-ops on the client so shared files can call them unconditionally
  function NA.permissions() end
  function NA.log() return false end
  function NA.action() return false end
  function NA.notifyStaff() end
end
