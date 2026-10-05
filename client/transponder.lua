-- Own transponder: read from the server-written state bag `np_fr_xpdr`, changed only by asking the server
-- (np_flightradar:setTransponder). Commands /squawk, /transponder, /callsign.
local X = {}
NpFR.Xpdr = X

local BAG = 'np_fr_xpdr'
local cfgT = Config.Transponder or {}

-- { on, squawk, callsign, canEdit } for the aircraft you sit in, or nil
function X.current()
  local ped = PlayerPedId()
  local veh = GetVehiclePedIsIn(ped, false)
  if veh == 0 or not NpFR.Main.aircraftClass(veh) then return nil end
  local st = Entity(veh).state[BAG]
  st = type(st) == 'table' and st or {}
  local canEdit = GetPedInVehicleSeat(veh, -1) == ped
    or (cfgT.copilotCanEdit ~= false and GetPedInVehicleSeat(veh, 0) == ped)
  return {
    on = st.on == nil and cfgT.defaultOn ~= false or st.on == true,
    squawk = RadarMath.squawk(st.squawk) or RadarMath.squawk(cfgT.defaultSquawk) or '7000',
    callsign = RadarMath.callsign(st.callsign),
    canEdit = canEdit and true or false,
  }
end

-- Local pre-check for quick feedback; the server validates again
function X.request(patch)
  if type(patch) ~= 'table' then return false end
  local cur = X.current()
  if not cur then NpFR.Client.notify({ type = 'error', message = L('not_in_aircraft') }) return false end
  if not cur.canEdit then NpFR.Client.notify({ type = 'error', message = L('not_pilot') }) return false end
  local out = {}
  if patch.on ~= nil then out.on = patch.on == true end
  if patch.squawk ~= nil then
    out.squawk = RadarMath.squawk(type(patch.squawk) == 'number' and math.tointeger(patch.squawk) or patch.squawk)
    if not out.squawk then NpFR.Client.notify({ type = 'error', message = L('squawk_invalid') }) return false end
  end
  if patch.callsign ~= nil then
    if patch.callsign == '' or patch.callsign == false then
      out.callsign = ''
    else
      out.callsign = RadarMath.callsign(patch.callsign)
      if not out.callsign then NpFR.Client.notify({ type = 'error', message = L('callsign_invalid') }) return false end
    end
  end
  if next(out) == nil then return false end
  TriggerServerEvent('np_flightradar:setTransponder', out)
  return true
end

-- Push changes of your own aircraft's transponder to the panel
AddStateBagChangeHandler(BAG, nil, function(bagName)
  local ent = GetEntityFromStateBagName(bagName)
  if not ent or ent == 0 then return end
  if ent ~= GetVehiclePedIsIn(PlayerPedId(), false) then return end
  SetTimeout(0, function() NpFR.NUI.transponder() end) -- bag value is applied after the handler
end)

local cmds = Config.Commands or {}

RegisterCommand(cmds.squawk or 'squawk', function(_, args)
  X.request({ squawk = args[1] or '' })
end, false)

RegisterCommand(cmds.transponder or 'transponder', function(_, args)
  local a = args[1] and args[1]:lower()
  local cur = X.current()
  if a == 'on' then X.request({ on = true })
  elseif a == 'off' then X.request({ on = false })
  elseif cur then X.request({ on = not cur.on })
  else NpFR.Client.notify({ type = 'error', message = L('not_in_aircraft') }) end
end, false)

RegisterCommand(cmds.callsign or 'callsign', function(_, args)
  X.request({ callsign = table.concat(args, ' ') })
end, false)

CreateThread(function()
  TriggerEvent('chat:addSuggestion', '/' .. (cmds.squawk or 'squawk'), L('cmd_squawk'), { { name = L('arg_code'), help = L('squawk_hint') } })
  TriggerEvent('chat:addSuggestion', '/' .. (cmds.transponder or 'transponder'), L('cmd_transponder'), { { name = L('arg_state'), help = '' } })
  TriggerEvent('chat:addSuggestion', '/' .. (cmds.callsign or 'callsign'), L('cmd_callsign'), { { name = L('arg_text'), help = L('callsign_hint') } })
end)
