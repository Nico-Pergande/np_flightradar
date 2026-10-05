-- Subscriber tick. One thread, alive only while somebody is subscribed. Each tick builds one snapshot of
-- the active aircraft (O(aircraft)) and filters it per subscriber (O(aircraft) each): range, own vehicle,
-- transponder-off (primary radar only). Contacts are a FULL set every tick, so the client removes
-- anything missing: no ghosts. Static per-aircraft data (`meta`) is only sent when new or changed.
local B = { subs = {}, count = 0, running = false, ticks = 0 }
NpFR.Broadcast = B
local S, T, R, A = NpFR.Server, NpFR.Transponder, NpFR.Registry, NpFR.Access

local function interval()
  local n = tonumber(Config.UpdateInterval) or 1000
  return math.max(250, math.min(5000, math.floor(n)))
end

local UNIDENTIFIED_KEY = 'U'

-- ===== snapshot =====================================================================================

local function orgOf(src)
  if not src then return nil end
  local job = A.static(src).job
  return job and Config.Orgs and Config.Orgs[job] or nil
end

function B.snapshot()
  local pedToSrc = {}
  for _, p in ipairs(Bridge.players()) do
    local ped = GetPlayerPed(p)
    if ped and ped ~= 0 then pedToSrc[ped] = p end
  end
  local checkLicence = Config.Identification and Config.Identification.checkPilotLicense
  local out = {}
  for _, e in ipairs(R.each()) do
    local veh = e.entity
    local pilot = GetPedInVehicleSeat(veh, -1)
    if pilot == 0 then pilot = nil end
    local v = GetEntityVelocity(veh)
    local vx, vy, vz = v and v.x or 0.0, v and v.y or 0.0, v and v.z or 0.0
    local speed = math.sqrt(vx * vx + vy * vy)
    if R.isActive(e, pilot, speed) then
      local c = GetEntityCoords(veh)
      local st = T.get(veh)
      local pilotSrc = pilot and pedToSrc[pilot] or nil
      local flags = {
        emergency = st.on and RadarMath.emergency(st.squawk) or nil,
        xpdrOff = not st.on,
        unlicensed = (checkLicence and pilotSrc and S.licensed(pilotSrc) == false) or false,
        camera = S.cameraOn(veh),
      }
      local meta = {
        kind = e.kind, model = e.model, callsign = T.callsign(e, st, pilotSrc),
        squawk = st.squawk, org = orgOf(pilotSrc), flags = flags,
      }
      local key = table.concat({
        meta.kind, tostring(meta.model), meta.callsign, meta.squawk, meta.org or '',
        flags.emergency or '', flags.unlicensed and '1' or '0', flags.camera and '1' or '0',
      }, '|')
      out[#out + 1] = {
        entity = veh, netId = e.netId, kind = e.kind, on = st.on, x = c.x, y = c.y, z = c.z,
        meta = meta, key = key, state = st, pilotSrc = pilotSrc,
        packed = RadarMath.pack(e.netId, c.x, c.y, c.z, GetEntityHeading(veh), vx, vy, vz),
      }
    end
  end
  return out
end

-- ===== per subscriber ===============================================================================

function B.sendTo(src, sub, snap, now)
  local ped = GetPlayerPed(src)
  if not ped or ped == 0 then return end
  local pc = GetEntityCoords(ped)
  local own = GetVehiclePedIsIn(ped, false)
  local pr = Config.PrimaryRadar or {}
  local contacts, metaOut, known = {}, nil, {}
  for i = 1, #snap do
    local a = snap[i]
    if a.entity ~= own then
      local d = RadarMath.dist2d(pc.x, pc.y, a.x, a.y)
      if RadarMath.inRange(d, sub.range) then
        local key, meta
        if a.on then
          key, meta = a.key, a.meta
        elseif sub.primary and pr.enabled ~= false and RadarMath.inRange(d, pr.range) then
          key = UNIDENTIFIED_KEY
          meta = { kind = a.kind, flags = { xpdrOff = true, unlicensed = false, camera = false } }
        end
        if key then
          contacts[#contacts + 1] = a.packed
          known[a.netId] = key
          if sub.known[a.netId] ~= key then
            metaOut = metaOut or {}
            metaOut[a.netId] = meta
          end
        end
      end
    end
  end
  sub.known = known
  if metaOut then TriggerClientEvent('np_flightradar:meta', src, metaOut) end
  TriggerClientEvent('np_flightradar:contacts', src, { t = now, c = contacts })
end

-- ===== subscriptions ================================================================================

local function drop(src, reason)
  if not B.subs[src] then return end
  B.subs[src] = nil
  B.count = B.count - 1
  if reason then
    TriggerClientEvent('np_flightradar:revoked', src, reason)
  end
end

function B.unsubscribe(src) drop(src) end

-- Positional grants (seat, standing at a tower) and 'auto' (its best mode depends on them) are
-- re-resolved often, so leaving the aircraft / tower does not keep the bigger range for 30 s.
local POSITIONAL_MS = 5000
local function recheckEvery(sub)
  if sub.requested == 'auto' or sub.mode == 'air' or sub.mode == 'station' then return POSITIONAL_MS end
  return A.TTL
end

-- Re-resolves a subscriber's access now (job change, positional / 30 s); drops it when gone. The
-- requested mode is re-resolved ('auto' may now pick another mode); a change is pushed to the client
-- as an update of its current subscription (same reqId).
function B.recheck(src)
  local sub = B.subs[src]
  if not sub then return end
  local res = A.resolve(src, sub.requested or sub.mode)
  if not res then
    drop(src, 'access_lost')
    return
  end
  local changed = res.mode ~= sub.mode or res.range ~= sub.range or res.primary ~= sub.primary
  sub.mode, sub.range, sub.primary, sub.checkedAt = res.mode, res.range, res.primary, GetGameTimer()
  if changed then
    sub.known = {} -- unidentified/identified meta may differ now: resend
    TriggerClientEvent('np_flightradar:subscribed', src, {
      mode = res.mode, range = res.range, primary = res.primary, reqId = sub.reqId, update = true,
    })
  end
end

function B.tick()
  local now = GetGameTimer()
  B.ticks = B.ticks + 1
  local due = {}
  for src, sub in pairs(B.subs) do
    if now - sub.checkedAt >= recheckEvery(sub) then due[#due + 1] = src end
  end
  for _, src in ipairs(due) do B.recheck(src) end
  if B.count <= 0 then return end
  local snap = B.snapshot()
  for src, sub in pairs(B.subs) do B.sendTo(src, sub, snap, now) end
end

local function ensureLoop()
  if B.running then return end
  B.running = true
  CreateThread(function()
    while B.count > 0 do
      local ok, err = pcall(B.tick)
      if not ok then NpFR.warn('radar tick failed: %s', tostring(err)) end
      Wait(interval())
    end
    B.running = false
  end)
end

-- mode: Access.MODES or 'auto'. reqId echoes back so the client can match the answer.
function B.subscribe(src, mode, reqId)
  local res = A.resolve(src, mode)
  if not res then
    drop(src)
    TriggerClientEvent('np_flightradar:denied', src, { mode = mode, reqId = reqId })
    return nil
  end
  if not B.subs[src] then B.count = B.count + 1 end
  B.subs[src] = {
    mode = res.mode, range = res.range, primary = res.primary, known = {}, checkedAt = GetGameTimer(),
    requested = mode or 'auto', reqId = reqId,
  }
  TriggerClientEvent('np_flightradar:subscribed', src, {
    mode = res.mode, range = res.range, primary = res.primary, reqId = reqId,
  })
  ensureLoop()
  return res
end

function B.list()
  local out = {}
  for src, sub in pairs(B.subs) do
    out[#out + 1] = { source = src, mode = sub.mode, range = sub.range, primary = sub.primary }
  end
  return out
end
