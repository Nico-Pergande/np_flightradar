-- Server exports (exports.np_flightradar:<Name>(...))
local R, T, B, A = NpFR.Registry, NpFR.Transponder, NpFR.Broadcast, NpFR.Access

local function describe(e)
  local veh = e.entity
  local c = GetEntityCoords(veh)
  local v = GetEntityVelocity(veh)
  local st = T.get(veh)
  local pilot = GetPedInVehicleSeat(veh, -1)
  local pilotSrc
  if pilot and pilot ~= 0 then
    for _, p in ipairs(Bridge.players()) do
      if GetPlayerPed(p) == pilot then pilotSrc = p break end
    end
  end
  return {
    netId = e.netId, entity = veh, kind = e.kind, model = e.model, plate = e.plate,
    callsign = T.callsign(e, st, pilotSrc), squawk = st.squawk, transponder = st.on,
    emergency = st.on and RadarMath.emergency(st.squawk) or nil,
    coords = c and vector3(c.x, c.y, c.z) or nil, heading = GetEntityHeading(veh),
    speed = v and math.sqrt(v.x * v.x + v.y * v.y) or 0.0, pilot = pilotSrc,
  }
end

-- Every registered aircraft (parked ones included) -> list
exports('GetAircraft', function()
  local out = {}
  for _, e in ipairs(R.each()) do out[#out + 1] = describe(e) end
  return out
end)

exports('GetAircraftByNetId', function(netId)
  local e = R.byNetId(math.tointeger(tonumber(netId) or 0) or 0)
  return e and describe(e) or nil
end)

-- netIdOrEntity: network id or server entity handle; data = { on?, squawk?, callsign? }
-- -> state | nil, errKey
exports('SetTransponder', function(netIdOrEntity, data)
  local id = math.tointeger(tonumber(netIdOrEntity) or 0) or 0
  local e = R.get(id) or R.byNetId(id)
  if not e then return nil, 'not_in_aircraft' end
  return T.apply(e.entity, data, nil)
end)

exports('GetSubscribers', function() return B.list() end)

-- fn(src, mode) -> false to deny
exports('RegisterAccessCheck', function(fn) return A.addCheck(fn) end)
