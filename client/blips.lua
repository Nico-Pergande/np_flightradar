-- Map blips: one per netId, created once and restyled only when its look changes. Aircraft streamed in
-- locally get an entity blip (smooth, native); the rest get a coord blip that a single lerp thread
-- dead-reckons between server updates. Anything missing from the latest full set is removed.
local Blips = { list = {}, lerping = false }
NpFR.Blips = Blips

local cfgB = Config.Blips or {}

local function maxDt()
  return 1.5 * (tonumber(Config.UpdateInterval) or 1000) / 1000
end

local function removeEntry(id)
  local b = Blips.list[id]
  if not b then return end
  Blips.list[id] = nil -- cleared first: never touch a stale handle twice
  if b.handle and DoesBlipExist(b.handle) then RemoveBlip(b.handle) end
end

local function localVehicle(id)
  if not NetworkDoesNetworkIdExist(id) then return nil end
  local veh = NetToVeh(id)
  if veh and veh ~= 0 and DoesEntityExist(veh) then return veh end
  return nil
end

local function colourOf(c)
  local col = cfgB.colours or {}
  local f = c.flags or {}
  if f.emergency then return col.emergency or 1 end
  if f.xpdrOff then return col.unidentified or 39 end
  if f.unlicensed then return col.unlicensed or 5 end
  if f.org and col[f.org] then return col[f.org] end
  return col.default or 0
end

local function styleKey(c)
  local f = c.flags or {}
  return table.concat({ c.kind or '', c.callsign or '', colourOf(c), f.emergency and '1' or '0', f.xpdrOff and '1' or '0' }, '|')
end

local function applyStyle(b, c)
  local h = b.handle
  local kindCfg = cfgB[c.kind] or {}
  SetBlipSprite(h, kindCfg.sprite or (c.kind == 'heli' and 43 or 307))
  SetBlipScale(h, (kindCfg.scale or cfgB.scale or 0.8) + 0.0)
  SetBlipColour(h, colourOf(c))
  SetBlipAsShortRange(h, cfgB.shortRange == true)
  SetBlipFlashes(h, c.flags and c.flags.emergency ~= nil or false)
  SetBlipAlpha(h, (c.flags and c.flags.xpdrOff) and 170 or 255)
  ShowHeadingIndicatorOnBlip(h, true)
  BeginTextCommandSetBlipName('STRING')
  AddTextComponentSubstringPlayerName(c.callsign or L('unidentified'))
  EndTextCommandSetBlipName(h)
end

local function lerpLoop()
  if Blips.lerping then return end
  Blips.lerping = true
  CreateThread(function()
    local step = math.max(16, tonumber(cfgB.lerpMs) or 100)
    while true do
      local any = false
      local now = GetGameTimer()
      local cap = maxDt()
      for _, b in pairs(Blips.list) do
        if not b.entity and b.base then
          any = true
          local p = b.base
          local x, y, z = RadarMath.deadReckon(p.x, p.y, p.z, p.vx, p.vy, p.vz, (now - p.t) / 1000, cap)
          SetBlipCoords(b.handle, x, y, z)
        end
      end
      if not any then break end
      Wait(step)
    end
    Blips.lerping = false
  end)
end

-- contacts: merged list from client/radar.lua; now: GetGameTimer() at receipt
function Blips.sync(contacts, now)
  local seen = {}
  local needLerp = false
  for i = 1, #contacts do
    local c = contacts[i]
    local id = c.id
    seen[id] = true
    local veh = localVehicle(id)
    local b = Blips.list[id]
    if b and ((veh ~= nil) ~= (b.entity ~= nil) or (veh and b.entity ~= veh) or not DoesBlipExist(b.handle)) then
      removeEntry(id) -- streamed in/out: switch blip kind
      b = nil
    end
    if not b then
      local handle = veh and AddBlipForEntity(veh) or AddBlipForCoord(c.x, c.y, c.z)
      b = { handle = handle, entity = veh }
      Blips.list[id] = b
    end
    local key = styleKey(c)
    if b.style ~= key then
      b.style = key
      applyStyle(b, c)
    end
    SetBlipRotation(b.handle, math.floor(c.h or 0))
    if not b.entity then
      b.base = { x = c.x, y = c.y, z = c.z, vx = c.vx, vy = c.vy, vz = c.vz, t = now }
      SetBlipCoords(b.handle, c.x, c.y, c.z)
      needLerp = true
    end
  end
  local gone = {}
  for id in pairs(Blips.list) do
    if not seen[id] then gone[#gone + 1] = id end
  end
  for _, id in ipairs(gone) do removeEntry(id) end
  if needLerp then lerpLoop() end
end

function Blips.clear()
  local ids = {}
  for id in pairs(Blips.list) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do removeEntry(id) end
end

AddEventHandler('onResourceStop', function(res)
  if res == GetCurrentResourceName() then Blips.clear() end
end)
