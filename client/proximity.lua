-- TCAS-lite: only while you are the pilot of an aircraft and contacts are coming in. Every 500 ms the
-- closest point of approach to each (dead-reckoned) contact is computed; the worst one raises a traffic
-- advisory (TA) or resolution advisory (RA) through np_hud, the NUI and the local event
-- np_flightradar:proximity(level, netId).
local P = { contacts = {}, threats = {}, level = nil, worst = nil, running = false }
NpFR.Proximity = P

local cfgP = Config.Proximity or {}
local NOTIFY_ID = 'np_fr_tcas'

function P.threatOf(id) return P.threats[id] end

local function isPilot()
  local ped = PlayerPedId()
  local veh = GetVehiclePedIsIn(ped, false)
  if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
  if not NpFR.Main.aircraftClass(veh) then return nil end
  return veh
end

local function sound(level)
  if not cfgP.sound then return end
  if level == 'RA' then
    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
  else
    PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
  end
end

local function raise(level, c, missV)
  local prev = P.level
  P.level, P.worst = level, c and c.id or nil
  TriggerEvent('np_flightradar:proximity', level or 'clear', c and c.id or nil)
  if not level then
    NpFR.Client.dismiss(NOTIFY_ID)
    NpFR.NUI.alert('clear', L('clear_text'), nil)
    return
  end
  local text
  if level == 'RA' then
    if missV > 0 then text = L('ra_descend') elseif missV < 0 then text = L('ra_climb') else text = L('ra_turn') end
  else
    text = L('ta_text')
  end
  local who = c.callsign or L('unidentified')
  NpFR.Client.notify({
    id = NOTIFY_ID, type = level == 'RA' and 'error' or 'warning',
    title = level == 'RA' and L('ra_title') or L('ta_title'),
    message = ('%s · %s'):format(text, who), icon = 'triangle-exclamation',
    tint = level == 'RA' and 'red' or 'orange', duration = 4000, sound = false,
  })
  NpFR.NUI.alert(level, text .. ' · ' .. who, c.id)
  if level ~= prev then sound(level) end
end

local function evaluate(veh)
  local now = GetGameTimer()
  local oc = GetEntityCoords(veh)
  local ov = GetEntityVelocity(veh)
  local own, ownV = { x = oc.x, y = oc.y, z = oc.z }, { x = ov.x, y = ov.y, z = ov.z }
  local cap = 1.5 * (tonumber(Config.UpdateInterval) or 1000) / 1000
  local threats, worstLevel, worstC, worstV, worstT = {}, nil, nil, 0, math.huge
  for i = 1, #P.contacts do
    local c = P.contacts[i]
    if not c.flags.xpdrOff then -- TCAS only sees transponders
      local x, y, z = RadarMath.deadReckon(c.x, c.y, c.z, c.vx, c.vy, c.vz, (now - c.t) / 1000, cap)
      local t, missH, missV = RadarMath.cpa(own, ownV, { x = x, y = y, z = z }, { x = c.vx, y = c.vy, z = c.vz })
      local level = RadarMath.threat(t, missH, missV, cfgP)
      if level then
        threats[c.id] = level
        local better = (level == 'RA' and worstLevel ~= 'RA') or (level == worstLevel and t < worstT) or not worstLevel
        if better then worstLevel, worstC, worstV, worstT = level, c, missV, t end
      end
    end
  end
  P.threats = threats
  if worstLevel ~= P.level or (worstC and worstC.id ~= P.worst) then
    raise(worstLevel, worstC, worstV)
  elseif worstLevel == 'RA' then
    raise(worstLevel, worstC, worstV) -- keep the RA text (climb/descend) current
  end
end

local function loop()
  if P.running then return end
  P.running = true
  CreateThread(function()
    while true do
      local veh = isPilot()
      if not veh or not NpFR.Radar.isSubscribed() or #P.contacts == 0 then break end
      evaluate(veh)
      Wait(500)
    end
    P.running = false
    P.threats = {}
    if P.level then raise(nil) end
  end)
end

function P.update(contacts)
  P.contacts = contacts or {}
  if cfgP.enabled == false or #P.contacts == 0 then
    if not P.running and P.level then raise(nil) end
    return
  end
  if isPilot() then loop() end
end
