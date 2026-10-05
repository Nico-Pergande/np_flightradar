-- Client side of the optional siblings: np_hud (notify + zone claim), np_phone (app messages),
-- np_menu (radials). np_inventory calls our `useScanner` export (client/main.lua) directly.
local I = NpFR.Integration

local hud = I.define('np_hud', { fallback = 'ox_lib / native notifications' })
local phone = I.define('np_phone', { fallback = 'no phone app' })
local menu = I.define('np_menu', { fallback = 'commands and key mapping only' })
I.define('np_inventory', { fallback = 'framework usable item' })

NpFR.Client = NpFR.Client or {}
local C = NpFR.Client

-- ===== notifications ================================================================================

-- data = { id?, type, title?, message, icon?, tint?, duration?, sound? }
function C.notify(data)
  if type(data) ~= 'table' then return end
  data.title = data.title or L('title')
  data.icon = data.icon or 'plane-up'
  if hud.active() then
    local ok = hud.call('Notify', data)
    if ok then return end
  end
  if GetResourceState('ox_lib') == 'started' then
    local map = { info = 'inform', warning = 'warning', error = 'error', success = 'success' }
    local ok = pcall(function()
      exports.ox_lib:notify({ id = data.id, title = data.title, description = data.message, type = map[data.type] or 'inform',
        duration = data.duration })
    end)
    if ok then return end
  end
  BeginTextCommandThefeedPost('STRING')
  AddTextComponentSubstringPlayerName(('~b~%s~s~~n~%s'):format(data.title, data.message or ''))
  EndTextCommandThefeedPostTicker(false, true)
end

function C.dismiss(id)
  if hud.active() then hud.call('DismissNotify', id) end
end

RegisterNetEvent('np_flightradar:notify', function(data) C.notify(data) end)

local claimed = false
function C.claimZones(on)
  if on == claimed then return end
  claimed = on
  if not hud.active() then return end
  hud.call('ClaimZones', on and { 'top-right' } or false)
end

-- ===== np_phone =====================================================================================

function C.phoneSend(event, data)
  if not phone.active() then return false end
  return phone.call('sendAppMessage', 'flightradar', event, data)
end

-- ===== np_menu radials ==============================================================================

local radialIds = {}

local function squawkItem(code)
  return {
    id = 'np_fr_sq_' .. code, label = L('radial_squawk', code) .. (code ~= '7000' and (' · ' .. L('sq_' .. code)) or ''),
    icon = code == '7000' and 'hashtag' or 'triangle-exclamation', tint = code == '7000' and 'blue' or 'red',
    onSelect = function() NpFR.Xpdr.request({ squawk = code }) end,
  }
end

local function addRadials()
  if not menu.active() then return end
  local ok, id = menu.call('addRadial', 'global', {
    id = 'np_flightradar', label = L('radial_radar'), icon = 'tower-broadcast', tint = 'blue',
    canInteract = function() return NpFR.Radar.canOpen() end,
    onSelect = function() NpFR.NUI.toggle() end,
  })
  if ok and id then radialIds[#radialIds + 1] = id end

  ok, id = menu.call('addRadial', 'vehicle', {
    id = 'np_flightradar_xpdr', label = L('radial_transponder'), icon = 'tower-broadcast', tint = 'blue',
    canInteract = function() return NpFR.Xpdr.current() ~= nil and NpFR.Xpdr.current().canEdit end,
    items = {
      {
        id = 'np_fr_xpdr_toggle', label = L('radial_xpdr_toggle'), icon = 'power-off', tint = 'green',
        onSelect = function()
          local cur = NpFR.Xpdr.current()
          if cur then NpFR.Xpdr.request({ on = not cur.on }) end
        end,
      },
      squawkItem('7000'), squawkItem('7500'), squawkItem('7600'), squawkItem('7700'),
      {
        id = 'np_fr_xpdr_callsign', label = L('radial_callsign'), icon = 'signature', tint = 'blue',
        onSelect = function()
          CreateThread(function()
            local okD, res = menu.call('inputDialog', {
              title = L('dialog_callsign'), icon = 'signature',
              fields = { { id = 'callsign', type = 'text', label = L('callsign'), placeholder = 'N123AB',
                hint = L('callsign_hint'), maxLength = 8 } },
            })
            if okD and type(res) == 'table' then NpFR.Xpdr.request({ callsign = res.callsign or '' }) end
          end)
        end,
      },
    },
  })
  if ok and id then radialIds[#radialIds + 1] = id end
end
menu.onStart(function()
  radialIds = {}
  addRadials()
end)

function C.removeRadials()
  for _, id in ipairs(radialIds) do menu.call('removeRadial', id) end
  radialIds = {}
end
