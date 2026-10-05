-- Client entry: aircraft seat detection (event driven, no idle polling), exports, scanner item use,
-- start-up and cleanup.
local M = { aircraft = nil, watching = false }
NpFR.Main = M

-- true when `veh` is a helicopter (class 15) or plane (class 16)
function M.aircraftClass(veh)
  if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
  local cls = GetVehicleClass(veh)
  return cls == 15 or cls == 16
end

local function currentAircraft()
  local veh = GetVehiclePedIsIn(PlayerPedId(), false)
  if M.aircraftClass(veh) then return veh end
  return nil
end

-- Watches the seat only while you are in an aircraft (1 Hz), then exits.
local function watch()
  if M.watching then return end
  M.watching = true
  CreateThread(function()
    local lastKey
    while true do
      local veh = currentAircraft()
      -- aircraft or seat (pilot <-> passenger) changed: the panel's transponder card follows
      local key = veh and (tostring(veh) .. (GetPedInVehicleSeat(veh, -1) == PlayerPedId() and 'P' or 'S')) or nil
      if veh ~= M.aircraft or key ~= lastKey then
        M.aircraft, lastKey = veh, key
        NpFR.NUI.transponder()
      end
      if not veh then break end
      Wait(1000)
    end
    M.watching = false
    M.aircraft = nil
    M.airRetries = 0
    NpFR.Radar.want('air', nil)
    NpFR.Proximity.update({})
  end)
end

function M.checkAircraft()
  local veh = currentAircraft()
  if veh and Config.Access and Config.Access.inAircraft ~= false then
    M.aircraft = veh
    NpFR.Radar.want('air', 'air')
    watch()
  end
end

-- The server sees the seat a moment after the client does, so the first 'air' request right after
-- boarding can be denied. Ask again a few times while still seated.
M.airRetries = 0
local AIR_RETRIES, AIR_RETRY_MS = 3, 1500
NpFR.Radar.on(function(kind, data)
  if kind ~= 'denied' or not data or data.source ~= 'air' then return end
  if M.airRetries >= AIR_RETRIES then return end
  M.airRetries = M.airRetries + 1
  SetTimeout(AIR_RETRY_MS, function()
    if currentAircraft() and NpFR.Radar.wanting('air') == nil then M.checkAircraft() end
  end)
end)
NpFR.Radar.on(function(kind, data)
  if kind == 'subscribed' and data and data.source == 'air' then M.airRetries = 0 end
end)

-- CEventNetworkPlayerEnteredVehicle fires when the local player gets into a vehicle
AddEventHandler('gameEventTriggered', function(name, args)
  if name ~= 'CEventNetworkPlayerEnteredVehicle' then return end
  if args and args[1] ~= nil and args[1] ~= PlayerId() then return end
  M.airRetries = 0
  CreateThread(function()
    -- the seat is not always set in the very frame of the event
    for _ = 1, 10 do
      if currentAircraft() then M.checkAircraft() return end
      Wait(300)
    end
  end)
end)

-- ===== scanner item =================================================================================

local function useScanner()
  if NpFR.NUI.open then NpFR.NUI.close() return end
  NpFR.NUI.openWith('item')
end
RegisterNetEvent('np_flightradar:useScanner', useScanner) -- framework usable-item fallback

-- ===== exports ======================================================================================

exports('OpenRadar', function(mode)
  if mode ~= nil and not Access.VALID[mode] then mode = nil end
  if mode == 'phone' then mode = nil end
  NpFR.NUI.openWith(mode)
end)
exports('CloseRadar', function() NpFR.NUI.close() end)
-- np_admin staff tool "Open admin flight radar" (server/np_admin.lua); the server still decides the grant
RegisterNetEvent('np_flightradar:openRadar', function(mode)
  if mode ~= nil and not Access.VALID[mode] then return end
  if mode == 'phone' then return end
  NpFR.NUI.openWith(mode)
end)
exports('IsRadarOpen', function() return NpFR.NUI.open end)
exports('GetContacts', function() return NpFR.Radar.public(NpFR.Radar.contacts, 0) end)
exports('GetTransponder', function() return NpFR.Xpdr.current() end)
exports('SetSquawk', function(code) return NpFR.Xpdr.request({ squawk = code }) end)
-- np_inventory: client = { export = 'np_flightradar.useScanner' } -> fn(data, slot)
exports('useScanner', function() useScanner() end)

-- ===== lifecycle ====================================================================================

local function hello()
  TriggerServerEvent('np_flightradar:hello')
  M.checkAircraft()
end

AddEventHandler('onClientResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    hello()
  end)
end)
AddEventHandler('playerSpawned', function() hello() end)
Bridge.onJobChange(function() TriggerServerEvent('np_flightradar:hello') end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  NpFR.Client.removeRadials()
  NpFR.Client.dismiss('np_fr_tcas')
end)
