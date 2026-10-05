-- Server side of every optional sibling. Each one is detected at runtime, pcall'd, re-wired when the
-- sibling (re)starts and switchable with Config.Integrations.<name> = false.
local I = NpFR.Integration
local RES = GetCurrentResourceName()

local hud = I.define('np_hud', { fallback = 'client notifications (ox_lib / native feed)' })
local phone = I.define('np_phone', { fallback = 'no phone app' })
local inv = I.define('np_inventory', { fallback = 'framework usable item (ESX / qb)' })
local ident = I.define('np_identification', { fallback = 'no pilot licence check' })
local discord = I.define('np_discord', { fallback = 'no Discord roles / logs' })
-- state-bag-only readers: no exports, just the bags they write
local manu = I.define('np_manufacturing', { fallback = 'perModel callsigns / plates' })
local helicam = I.define('np_helicam', { fallback = 'no camera flag' })

NpFR.Server = NpFR.Server or {}
local S = NpFR.Server

-- ===== notifications ================================================================================

-- data = { id?, type, title, message, icon, tint, duration }
function S.notify(src, data)
  data.title = data.title or L('title')
  data.icon = data.icon or 'plane-up'
  if hud.active() then
    local ok = hud.call('Notify', src, data)
    if ok then return end
  end
  TriggerClientEvent('np_flightradar:notify', src, data)
end

function S.phoneNotify(src, title, body)
  if not phone.active() or (Config.Phone and Config.Phone.enabled == false) then return false end
  return phone.call('notify', src, { app = 'flightradar', title = title, body = body, icon = 'fa-solid fa-plane-up' })
end

-- ===== np_phone store app ===========================================================================

phone.onStart(function()
  local p = Config.Phone or {}
  if p.enabled == false then return end
  local ok, res = phone.call('registerStoreApp', {
    id = 'flightradar', name = 'Flightradar', ui = 'html/phone.html', icon = 'fa-solid fa-plane-up',
    tint = 'blue', category = 'app', description = L('phone_desc'), developer = RES,
    default = p.job == nil and p.item == nil, job = p.job, item = p.item,
  })
  if not ok or res == false then NpFR.warn('np_phone: could not register the Flightradar app') end
end)

-- ===== np_inventory item / framework fallback =======================================================

local function useScannerFallback(src)
  TriggerClientEvent('np_flightradar:useScanner', src)
end

local function registerItem()
  local item = Config.Access and Config.Access.item
  if not item then return end
  if inv.active() then
    local ok, res = inv.call('RegisterItem', item, {
      label = L('item_label'), description = L('item_desc'), weight = 400, stack = false, close = true,
      icon = 'tower-broadcast', tint = 'blue', client = { export = RES .. '.useScanner' },
    })
    if ok and res ~= false then return end
    NpFR.warn('np_inventory: RegisterItem(%s) failed, using the framework usable item', item)
  end
  Bridge.registerUsable(item, useScannerFallback)
end
S.registerItem = registerItem
inv.onStart(registerItem)
if not inv.active() then
  CreateThread(function()
    Wait(1000) -- frameworks expose their usable-item API once started
    if not inv.active() then registerItem() end
  end)
end
AddEventHandler('onServerResourceStart', function(res)
  if res == 'es_extended' or res == 'qbx_core' or res == 'qb-core' then
    if not inv.active() then SetTimeout(1000, registerItem) end
  end
end)

function S.hasItem(src)
  local item = Config.Access and Config.Access.item
  if not item then return false end
  if inv.active() then
    local ok, n = inv.call('GetItemCount', src, item)
    if ok then return (tonumber(n) or 0) > 0 end
  end
  return Bridge.itemCount(src, item) > 0
end

-- ===== np_identification: pilot licence (cached, refreshed off-thread) ==============================

local LICENSE_TTL = 60000
local licence = {} -- [src] = { at, value, busy }

-- true / false / nil (unknown: integration off or not answered yet)
function S.licensed(src)
  local cfg = Config.Identification or {}
  if not cfg.checkPilotLicense and not cfg.requireLicenseForAirRadar then return nil end
  if not ident.active() then return nil end
  local c = licence[src]
  local now = GetGameTimer()
  if not c then c = { at = -LICENSE_TTL }; licence[src] = c end
  if not c.busy and now - c.at >= LICENSE_TTL then
    c.busy = true
    CreateThread(function()
      local ok, valid = ident.call('hasValidDocument', src, cfg.document or 'pilot_license')
      local e = licence[src]
      if e then
        e.busy, e.at = false, GetGameTimer()
        if ok then e.value = valid == true end
      end
    end)
  end
  return c.value
end

-- ===== np_discord: role access (HasAnyRole yields -> cached) + logs =================================

local roleOk = {} -- [src] = true

function S.discordOk(src) return roleOk[src] == true end

function S.refreshDiscord(src)
  local roles = Config.Access and Config.Access.discordRoles or {}
  if #roles == 0 or not discord.active() then roleOk[src] = nil return end
  CreateThread(function()
    local ok, held, err = discord.call('HasAnyRole', src, roles)
    -- np_discord exports failures as `false, err`: Discord could not be asked, keep what we knew
    if not ok or err ~= nil or (held ~= true and held ~= false) then return end
    local before = roleOk[src]
    if held == true then roleOk[src] = true elseif held == false then roleOk[src] = nil end
    if before ~= roleOk[src] and NpFR.Access then NpFR.Access.invalidate(src, true) end
  end)
end

function S.discordLog(entry)
  local ch = Config.Emergency and Config.Emergency.discordChannel
  if type(ch) ~= 'string' or ch == '' or not discord.active() then return end
  CreateThread(function() discord.call('Log', ch, entry) end)
end

-- ===== state bags of np_manufacturing / np_helicam ==================================================

function S.vehicleCallsign(veh)
  if not manu.enabled() then return nil end
  local ok, cs = pcall(function() return Entity(veh).state.vehicleCallsign end)
  return ok and cs or nil
end

function S.cameraOn(veh)
  if not helicam.enabled() then return false end
  local ok, cam = pcall(function() return Entity(veh).state.helicam_cam end)
  return ok and type(cam) == 'table' and cam.on == true
end

-- ===== lifecycle ====================================================================================

AddEventHandler('playerJoining', function() S.refreshDiscord(source) end)
Bridge.onPlayerChanged(function(src) S.refreshDiscord(src) end)
discord.onStart(function()
  for _, p in ipairs(Bridge.players()) do S.refreshDiscord(p) end
end)
if #((Config.Access and Config.Access.discordRoles) or {}) > 0 then
  CreateThread(function()
    while true do
      Wait(10 * 60000)
      for _, p in ipairs(Bridge.players()) do S.refreshDiscord(p) end
    end
  end)
end

AddEventHandler('playerDropped', function()
  local src = source
  licence[src], roleOk[src] = nil, nil
end)
